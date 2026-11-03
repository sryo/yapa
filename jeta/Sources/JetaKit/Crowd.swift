import Foundation
import simd

/// What one Claude Code session is doing, as its hooks say.
public enum SessionState: Equatable {
    case working(reading: Bool), needs, finished(at: Double), failed, quiet
}

public struct SessionInfo: Equatable {
    public var id, name: String, state: SessionState
    /// Counts the session's hook events, so a face swiped away comes back on the next one.
    public var events: Int
    public init(id: String, name: String, state: SessionState, events: Int) {
        self.id = id; self.name = name; self.state = state; self.events = events
    }
}

/// Where a session's face sits this frame, in fractions of the screen's short side from its centre.
public struct Slot: Equatable {
    public var id, name: String, centre: SIMD2<Double>, scale: Double, front: Bool
}

/// One small face per session, each showing its session's state. Up to `most` sit in a row; past that the quiet
/// ones fold into "+N". One that needs you steps forward, bigger and in the middle. Places and sizes are springs,
/// so faces glide when sessions come and go, and the whole group drifts slowly so nothing burns into the panel.
public final class Crowd {
    public static let most = 6
    static let step = 1.0 / 240
    /// Half a face's size at scale 1, with room for a lunge or a hop, in fractions of the short side.
    static let reach = 0.25
    /// Half the screen's size, in fractions of its short side (16:9 landscape is 0.89 by 0.5).
    public var screen = SIMD2<Double>(0.89, 0.5)
    public private(set) var overflow = 0

    private var faces: [String: Face] = [:], places: [String: [Spring]] = [:]
    private var members: [SessionInfo] = [], hidden: [String: Int] = [:], focused: String?, standing: String?, leaving: String?
    private var now: Double, rng: SplitMix, phase: SIMD2<Double>

    public init(seed: UInt64, now: Double) {
        self.now = now
        rng = SplitMix(seed)
        phase = SIMD2(rng.next(in: 0...(2 * .pi)), rng.next(in: 0...(2 * .pi)))
    }

    public func face(_ id: String) -> Face? { faces[id] }

    /// With one session or none, the screen keeps the single big face.
    public var single: Bool { visible.count <= 1 }

    /// The session standing forward: the one a tap brought forward, else the one already there while it still needs
    /// you (so two that need you don't keep swapping), else the first to need you.
    public var front: String? { standing }

    private func pickFront() {
        let needing = Set(shown.filter { $0.state == .needs }.map(\.id)), was = standing
        if let f = focused, needing.contains(f) { standing = f }
        else if let s = standing, needing.contains(s) { return }
        else { standing = shown.first { needing.contains($0.id) }?.id }
        if let w = was, w != standing, standing != nil, places[w] != nil { leaving = w }
    }

    public func update(_ sessions: [SessionInfo], at t: Double) {
        advance(to: t)
        members = sessions
        for m in sessions where hidden[m.id] != nil && hidden[m.id] != m.events { hidden[m.id] = nil }
        let ids = Set(sessions.map(\.id))
        faces = faces.filter { ids.contains($0.key) }
        places = places.filter { ids.contains($0.key) }
        hidden = hidden.filter { ids.contains($0.key) }
        for m in sessions where faces[m.id] == nil {
            let f = Face(seed: rng.next(), now: t, lively: false)
            // The crowd decides when a face sleeps, and where it is.
            f.dozeAfter = .infinity
            f.peekAfter = .infinity
            faces[m.id] = f
        }
        moods(at: t)
        pickFront()
    }

    /// Brings a session forward, when it needs you: its prompt is the one a tap then answers.
    public func focus(_ id: String?, at t: Double) {
        advance(to: t)
        focused = id
        pickFront()
    }

    /// Hides a session's face until its next hook event. It stays a session in Claude.
    public func hide(_ id: String, at t: Double) {
        advance(to: t)
        if let m = members.first(where: { $0.id == id }) { hidden[id] = m.events }
        pickFront()
    }

    /// The face under a point, if any.
    public func hit(_ p: SIMD2<Double>, at t: Double) -> String? {
        slots(at: t).filter { simd_length(p - $0.centre) < Crowd.reach * $0.scale * 1.3 }
            .min { simd_length(p - $0.centre) < simd_length(p - $1.centre) }?.id
    }

    /// The faces to draw this frame; one still too small to see (just arriving) isn't one yet.
    public func slots(at t: Double) -> [Slot] {
        advance(to: t)
        moods(at: t)
        let f = front
        return shown.compactMap { m in
            let p = places[m.id]!
            return p[2].x < 0.02 ? nil : Slot(id: m.id, name: m.name, centre: SIMD2(p[0].x, p[1].x), scale: p[2].x, front: m.id == f)
        }
    }

    private var visible: [SessionInfo] { members.filter { hidden[$0.id] == nil } }

    /// The faces on screen, in the order their sessions started: past `most`, quiet ones are the ones left out.
    private var shown: [SessionInfo] {
        let v = visible
        guard v.count > Crowd.most else { return v }
        var keep = Set(v.filter { $0.state != .quiet }.prefix(Crowd.most).map(\.id))
        for m in v where keep.count < Crowd.most { keep.insert(m.id) }
        return v.filter { keep.contains($0.id) }
    }

    private func moods(at t: Double) {
        overflow = max(0, visible.count - Crowd.most)
        for m in members {
            let mood: Mood
            switch m.state {
            case .working: mood = .busy
            case .needs: mood = .attention
            case .finished(let at): mood = t - at < 5 ? .proud : t - at < 95 ? .idle : .sleep
            case .failed: mood = .dizzy
            case .quiet: mood = .sleep
            }
            faces[m.id]?.set(mood, at: t)
        }
    }

    /// Where each face shown should be: the one forward in the middle, the rest in a row; all drifting together.
    private func targets(at t: Double) -> [String: SIMD3<Double>] {
        // A face handing over the front goes back to the row before the next one steps up, so they never cross.
        if let l = leaving, let p = places[l], let g = layout(raising: nil, at: t)[l],
           simd_length(SIMD2(p[0].x, p[1].x) - SIMD2(g.x, g.y)) > 0.03 || p[2].x > g.z * 1.1 {
            return layout(raising: nil, at: t)
        }
        leaving = nil
        return layout(raising: front, at: t)
    }

    private func layout(raising f: String?, at t: Double) -> [String: SIMD3<Double>] {
        let drift = SIMD2(0.04 * sin(2 * .pi * t / 900 + phase.x), 0.03 * sin(2 * .pi * t / 660 + phase.y))
        let row = shown.filter { $0.id != f }
        var out: [String: SIMD3<Double>] = [:]
        if let f { out[f] = SIMD3(drift.x, drift.y - 0.1, 0.7) }
        let spacing = 2 * screen.x * 0.9 / Double(max(1, row.count))
        let scale = min(f == nil ? 0.45 : 0.28, spacing / (2 * Crowd.reach * 1.2))
        for (i, m) in row.enumerated() {
            out[m.id] = SIMD3(drift.x + (Double(i) - Double(row.count - 1) / 2) * spacing, drift.y + (f == nil ? 0 : 0.32), scale)
        }
        return out
    }

    private func advance(to t: Double) {
        let goal = targets(at: max(t, now))
        // A new face starts where it belongs, at nothing, and grows in.
        for (id, g) in goal where places[id] == nil { places[id] = [Spring(x: g.x), Spring(x: g.y), Spring(x: 0)] }
        while now < t {
            let dt = min(Crowd.step, t - now)
            for (id, g) in goal {
                places[id]![0].step(to: g.x, k: 40, damping: 1, dt: dt)
                places[id]![1].step(to: g.y, k: 40, damping: 1, dt: dt)
                // Growing is slower than moving and shrinking, so a face stepping forward clears the row before it's big.
                places[id]![2].step(to: g.z, k: g.z > places[id]![2].x ? 10 : 80, damping: 1, dt: dt)
            }
            now += dt
        }
        // Faces not shown shrink away where they were, so one coming back grows in again.
        for id in places.keys where goal[id] == nil { places[id] = nil }
    }
}

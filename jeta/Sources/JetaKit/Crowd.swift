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
    /// How much its folder name shows, 0 to 1: only for a while after a touch, since the mood already says how it is.
    public var named: Double
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
    /// The session whose text is open: its face waits beside the text, in the top left, and the others step away
    /// until it closes, so it's clear who's talking.
    public var solo: String?

    private var faces: [String: Face] = [:], places: [String: [Spring]] = [:]
    private var members: [SessionInfo] = [], hidden: [String: Int] = [:], focused: String?, standing: String?, leaving: String?
    private var order: [String: Int] = [:], started = 0
    private var touched: [String: Double] = [:], shownNames: [String: Spring] = [:]
    /// How long a touched face's name stays up.
    static let nameFor = 3.0
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

    /// The session a finger at `p` means: the face under it, else the one forward, else the only one.
    public func session(at p: SIMD2<Double>, t: Double) -> String? {
        single ? visible.first?.id : hit(p, at: t) ?? front
    }

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
        // A session that ended keeps its face until it has shrunk away.
        let ids = Set(sessions.map(\.id))
        faces = faces.filter { ids.contains($0.key) || places[$0.key] != nil }
        hidden = hidden.filter { ids.contains($0.key) }
        for m in sessions where order[m.id] == nil { started += 1; order[m.id] = started }
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

    /// Shows a session's folder name for a few seconds.
    public func touch(_ id: String, at t: Double) {
        advance(to: t)
        touched[id] = t + Crowd.nameFor
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
        let f = front, on = shown, names = Dictionary(members.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        // Faces leaving (ended, hidden, folded away) are drawn too, shrinking where they were.
        let ids = on.map(\.id) + places.keys.filter { id in !on.contains { $0.id == id } }.sorted()
        return ids.compactMap { id -> Slot? in
            guard let p = places[id], p[2].x >= 0.02 else { return nil }
            return Slot(id: id, name: names[id] ?? "", centre: SIMD2(p[0].x, p[1].x), scale: p[2].x, front: id == f,
                        named: min(1, max(0, shownNames[id]?.x ?? 0)))
        }
    }


    private var visible: [SessionInfo] { members.filter { hidden[$0.id] == nil } }
    /// The sessions not swiped away, with their hook event counts.
    public var sessions: [SessionInfo] { visible }

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
        // A face leaving keeps its place in the row while it shrinks, so the others close up only once it's gone.
        let on = Set(shown.map(\.id)), leaving = Set(places.keys).subtracting(on)
        let row = on.union(leaving).subtracting([f].compactMap { $0 }).sorted { (order[$0] ?? 0, $0) < (order[$1] ?? 0, $1) }
        var out: [String: SIMD3<Double>] = [:]
        if let s = solo, on.contains(s) {
            for id in on.union(leaving) { out[id] = SIMD3(places[id]?[0].x ?? 0, places[id]?[1].x ?? 0, 0) }
            out[s] = SIMD3(-(screen.x - 0.17), -(screen.y - 0.15), 0.5)
            return out
        }
        if let f { out[f] = SIMD3(drift.x, drift.y - 0.1, 0.7) }
        let spacing = 2 * screen.x * 0.9 / Double(max(1, row.count))
        let scale = min(f == nil ? 0.6 : 0.32, spacing / (2 * Crowd.reach * 1.2))
        for (i, id) in row.enumerated() {
            out[id] = SIMD3(drift.x + (Double(i) - Double(row.count - 1) / 2) * spacing, drift.y + (f == nil ? 0 : 0.32),
                            leaving.contains(id) ? 0 : scale)
        }
        return out
    }

    private func advance(to t: Double) {
        let goal = targets(at: max(t, now))
        // A new face starts where it belongs, at nothing, and grows in.
        for (id, g) in goal where places[id] == nil { places[id] = [Spring(x: g.x), Spring(x: g.y), Spring(x: 0)] }
        while now < t {
            let dt = min(Crowd.step, t - now)
            for id in Array(places.keys) {
                // Faces not shown shrink away where they are, so one coming back grows in again.
                let g = goal[id] ?? SIMD3(places[id]![0].x, places[id]![1].x, 0)
                places[id]![0].step(to: g.x, k: 40, damping: 1, dt: dt)
                places[id]![1].step(to: g.y, k: 40, damping: 1, dt: dt)
                // Growing is slower than moving and shrinking, so a face stepping forward clears the row before it's big.
                places[id]![2].step(to: g.z, k: g.z > places[id]![2].x ? 10 : 80, damping: 1, dt: dt)
            }
            for id in Array(places.keys) {
                shownNames[id, default: Spring(x: 0)].step(to: now < touched[id] ?? -.infinity ? 1 : 0, k: 40, damping: 1, dt: dt)
            }
            now += dt
        }
        let on = Set(shown.map(\.id))
        for id in Array(places.keys) where !on.contains(id) && places[id]![2].x < 0.02 {
            places[id] = nil; shownNames[id] = nil; touched[id] = nil
            if !members.contains(where: { $0.id == id }) { faces[id] = nil; order[id] = nil }
        }
    }
}

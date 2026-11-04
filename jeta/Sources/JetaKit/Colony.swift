import Foundation
import simd

/// What one ant shows this frame, in screen points: filled shapes (body parts) and stroked lines (legs, antennae).
public struct AntShape {
    public var id: String
    public var fills: [[SIMD2<Double>]]
    public var strokes: [(points: [SIMD2<Double>], width: Double)]
    public var centre: SIMD2<Double>
    /// Each foot's spot on the ground, nil while it's in the air.
    public var planted: [SIMD2<Double>?]
}

/// One ant per session, white on black, each acting out its session's mood. The design is `proto/ants`.
///
/// Calm by default: only an ant whose session needs you tries to catch your eye (it comes to the middle, grows and
/// waves). The rest move only as much as their sessions do, stand still otherwise, and while still creep along a very
/// slow drift so nothing burns into the panel.
///
/// Legs follow RujiK's "wonky salamanders": each foot has a step spot, where it would be had it just finished a step
/// (half a stride ahead of its rest spot while walking). A planted foot stays put until that spot is a stride away,
/// then steps there, and the step gives the body a little torque. Legs are in two tripods (L1 R2 L3, R1 L2 R3) and a
/// tripod steps only while the other is planted, so the body always stands on three. The abdomen trails the thorax
/// like a rope, so it swings out on turns.
public final class Colony {
    /// Screen size in points.
    public var screen = SIMD2<Double>(320, 568)
    /// Where the finger is while talking; every ant turns to it.
    public var listenAt: SIMD2<Double>?
    /// The session whose text is open: its ant waits in the top left corner, beside the text, and the others walk off
    /// the nearest edge until it closes, then come back to where they were, so it's clear who's talking.
    public var solo: String?

    static let step = 1.0 / 120
    private var ants: [String: Ant] = [:], order: [String] = []
    private var now: Double, rng: SplitMix

    public init(seed: UInt64, now: Double) {
        self.now = now
        rng = SplitMix(seed)
    }

    /// The sessions to show and their moods; `front` is the one standing forward for a prompt, and `events` counts its
    /// hook events (nil when unknown, over Bluetooth), so a busy ant moves only as much as its session does.
    public func update(_ sessions: [(id: String, mood: Mood, front: Bool, events: Int?)], at t: Double) {
        advance(to: t)
        let ids = Set(sessions.map(\.id))
        for (id, a) in ants where !ids.contains(id) && a.act != .leave { a.set(.leave, at: t, rng: &rng) }
        let homes = Colony.homes(sessions.count, screen)
        for (s, home) in zip(sessions, homes) {
            let a = ants[s.id] ?? {
                let a = Ant(at: home, heading: rng.next(in: 0...(2 * .pi)), rng: &rng)
                a.size.x = 0
                ants[s.id] = a; order.append(s.id)
                return a
            }()
            a.home = home
            if let e = s.events, e != a.events { if a.events != nil { a.worked = t }; a.events = e }
            let act = solo == nil ? Colony.act(for: s.mood, front: s.front, listening: listenAt != nil) : s.id == solo ? .aside : .wait
            if a.act != act || a.front != s.front { a.front = s.front; a.set(act, at: t, rng: &rng) }
        }
    }

    public func position(of id: String) -> SIMD2<Double>? { ants[id].map { SIMD2($0.x, $0.y) } }

    /// The ant nearest a point, within reach of a finger.
    public func hit(_ p: SIMD2<Double>) -> String? {
        ants.filter { $0.value.act != .leave && simd_length(SIMD2($0.value.x, $0.value.y) - p) < 40 * max(1, $0.value.size.x) }
            .min { simd_length(SIMD2($0.value.x, $0.value.y) - p) < simd_length(SIMD2($1.value.x, $1.value.y) - p) }?.key
    }

    /// Whether anything is moving enough to need 60 fps; ants standing about need only 30.
    public var isActive: Bool {
        ants.values.contains { $0.v > 0.5 || $0.feet.contains { $0.s < 1 } || [.needs, .done, .failed, .listen].contains($0.act) }
    }

    public func shapes(at t: Double) -> [AntShape] {
        advance(to: t)
        return order.compactMap { id in ants[id].map { $0.shape(id: id, t: now) } }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Each session's own spot, in the order they started: one in the middle, more in two columns of rows, so ants
    /// are far apart and each stays where you know it.
    static func homes(_ n: Int, _ screen: SIMD2<Double>) -> [SIMD2<Double>] {
        guard n > 1 else { return n == 1 ? [screen / 2] : [] }
        let rows = (n + 1) / 2, top = 110.0, h = (screen.y - 2 * top) / Double(rows)
        return (0..<n).map { k in
            let alone = k == n - 1 && n % 2 == 1
            return SIMD2(alone ? screen.x / 2 : screen.x * (k % 2 == 0 ? 0.25 : 0.75), top + h * (Double(k / 2) + 0.5))
        }
    }

    static func act(for mood: Mood, front: Bool, listening: Bool) -> Ant.Act {
        if listening || mood == .listening { return .listen }
        switch mood {
        case .sleep: return .sleep
        case .busy, .focused: return .work
        case .attention, .impatient: return .needs
        case .celebrate, .proud, .heart: return .done
        case .dizzy: return .failed
        case .idle, .bored, .curious, .listening: return .wander
        }
    }

    private func advance(to t: Double) {
        while now < t {
            let dt = min(Colony.step, t - now)
            now += dt
            let spots = ants.values.filter { $0.act != .leave }.map { SIMD2($0.x, $0.y) }
            for a in ants.values { a.update(dt, t: now, screen: screen, listenAt: listenAt, others: spots, rng: &rng) }
        }
        for (id, a) in ants where a.act == .leave && (a.x < -40 || a.x > screen.x + 40 || a.y < -40 || a.y > screen.y + 40) {
            ants[id] = nil; order.removeAll { $0 == id }
        }
    }
}

/// A value that springs toward its target: v' += k (target - v) - d v'.
struct Bounce {
    var x: Double, target: Double, v = 0.0, k: Double, d: Double
    init(_ x: Double, k: Double = 120, d: Double = 14) { (self.x, target, self.k, self.d) = (x, x, k, d) }
    mutating func step(_ dt: Double) { v += (k * (target - x) - d * v) * dt; x += v * dt }
}

final class Ant {
    enum Act { case wander, work, needs, done, failed, sleep, listen, leave, aside, wait }

    /// The body is ~15 units nose to tail, drawn at `scale` points a unit: ~22 pt; one that needs you grows 2.2 times.
    static let scale = 1.45
    /// Where each foot rests, in body units: hip x, foot forward, foot out. As in a real ant, all six hips are on the
    /// thorax, close together, and the legs are long: the front pair reaches past the head, the hind pair past the
    /// abdomen.
    static let legs: [(hip: Double, x: Double, y: Double)] = [(1.3, 8.6, 6.4), (0.7, 0.6, 8.8), (0.1, -9.6, 7.2)]
    /// A stride, in body units, and how long a foot is in the air.
    static let stride = 4.6, stepTime = 0.1

    struct Foot { var i: Int, side: Double, tripod: Int, at: SIMD2<Double>, from: SIMD2<Double>, to: SIMD2<Double>, s = 1.0 }

    var x: Double, y: Double, h: Double, v = 0.0, spin = 0.0, tail: SIMD2<Double>
    var act = Act.wander, front = false, since = 0.0, until = 0.0, flags = 0
    var goal: SIMD2<Double>?, faceTo: SIMD2<Double>?, mill: (c: SIMD2<Double>, r: Double)?
    var still = false, nervous = true, cruise = 44.0
    var twitchAt = 0.0, turn = 0.0, pauseTo = 0.0, tap = 0.0, wave = 0.0, phase: Double
    /// The session's hook event count, and when it last went up.
    var events: Int?, worked = -1e9, nextStroll = 0.0
    /// Its session's own spot, which it strolls and runs errands around, and whether it's walking back there.
    var home: SIMD2<Double>, homing = false
    /// Phases of the burn-in drift.
    var drift: SIMD3<Double>, bounce = SIMD2<Double>(1, 1)
    /// Half a turn per stride walked: what the head bobs to.
    var gait = 0.0
    var size = Bounce(1), rear = Bounce(0, k: 60, d: 11), antennae = Bounce(0, k: 80, d: 12), curl = Bounce(0, k: 14, d: 7)
    /// The abdomen's swing with the gait: 1 to the right while the right front and hind legs are in the air, -1 left.
    var hips = Bounce(0, k: 900, d: 45), lastTripod = 1
    var feet: [Foot] = []

    init(at p: SIMD2<Double>, heading: Double, rng: inout SplitMix) {
        (x, y, h) = (p.x, p.y, heading)
        home = p
        tail = p - SIMD2(cos(heading), sin(heading)) * 6.6 * Ant.scale
        phase = rng.next(in: 0...6)
        drift = SIMD3(rng.next(in: 0...(2 * .pi)), rng.next(in: 0...(2 * .pi)), rng.next(in: 0...(2 * .pi)))
        for side in [-1.0, 1.0] {
            for i in 0..<3 {
                let r = rest(i, side, ahead: 0)
                feet.append(Foot(i: i, side: side, tripod: (i + (side > 0 ? 1 : 0)) % 2, at: r, from: r, to: r))
            }
        }
    }

    /// Starts acting out `a`, from a calm pose.
    func set(_ a: Act, at t: Double, rng: inout SplitMix) {
        act = a; since = t; flags = 0; until = 0
        goal = nil; faceTo = nil; mill = nil; still = false; nervous = true; cruise = 44; tap = 0; wave = 0
        size.target = 1; rear.target = 0; antennae.target = 0; curl.target = 0
        switch a {
        case .work: nervous = false; cruise = 50; antennae.target = 0.3
        case .needs: nervous = false; cruise = 90
        case .done: nervous = false; still = true; antennae.target = 0.7
        case .failed: nervous = false; still = true; antennae.target = -1; size.target = 0.92
        case .sleep, .listen: nervous = false
        case .leave: nervous = false; cruise = 50
        case .aside: nervous = false; cruise = 80
        case .wait: nervous = false; cruise = 50
        case .wander: nervous = false; still = true; nextStroll = t + rng.next(in: 20...60)
        }
    }

    /// The burn-in drift: like the face's, very slow sine waves (about 15 and 11 minutes for where, 12 for which way),
    /// plus a 3 pt circle every 30 s that is always faster than they are, so an ant standing still creeps at 0.35 to
    /// 0.95 pt a second and never stays on the same pixels.
    func drifted(_ t: Double) -> SIMD3<Double> {
        SIMD3(sin(2 * .pi * t / 900 + drift.x), sin(2 * .pi * t / 660 + drift.y), sin(2 * .pi * t / 720 + drift.z))
    }

    /// A foot's rest spot on the ground, `ahead` body units forward along the heading.
    func rest(_ i: Int, _ side: Double, ahead: Double) -> SIMD2<Double> {
        let l = Ant.legs[i], k = Ant.scale * size.x * (1 - curl.x * 0.55), c = cos(h), s = sin(h)
        let lx = l.x * k + ahead * Ant.scale * size.x, ly = l.y * side * k
        return SIMD2(x + c * lx - s * ly, y + s * lx + c * ly)
    }

    func update(_ dt: Double, t: Double, screen: SIMD2<Double>, listenAt: SIMD2<Double>?, others: [SIMD2<Double>] = [],
                rng: inout SplitMix) {
        think(t: t, dt: dt, screen: screen, listenAt: listenAt, rng: &rng)
        // Standing still, it creeps along the drift (and turns, unless it's facing something); its feet stretch and,
        // now and then, take a small step to settle.
        if still && goal == nil && mill == nil {
            // At an edge the drift turns back rather than stopping there.
            let d = drifted(t) - drifted(t - dt), reach = act == .needs ? 15.0 : 25.0, m = 30.0
            if (x < m && d.x * bounce.x < 0) || (x > screen.x - m && d.x * bounce.x > 0) { bounce.x = -bounce.x }
            if (y < m && d.y * bounce.y < 0) || (y > screen.y - m && d.y * bounce.y > 0) { bounce.y = -bounce.y }
            x += d.x * bounce.x * reach; y += d.y * bounce.y * reach
            // A small circle, faster than the waves ever get, keeps it creeping even when they turn or cancel.
            let w = 2 * Double.pi / 30
            x += 3.1 * (cos(w * t + drift.z) - cos(w * (t - dt) + drift.z)); y += 3.1 * (sin(w * t + drift.z) - sin(w * (t - dt) + drift.z))
            if faceTo == nil { h += d.z * 0.6 }
        }
        var want = goal
        if let m = mill {
            let a = atan2(y - m.c.y, x - m.c.x) + 0.6
            want = m.c + SIMD2(cos(a), sin(a)) * m.r
        }
        // The walk from the reference GIF: sharp heading jumps every few frames, and short dead stops.
        if t > twitchAt {
            turn = (rng.next(in: 0...1) - 0.5) * (want != nil ? 0.8 : 2.2)
            twitchAt = t + 0.1 + rng.next(in: 0...0.28)
            if nervous && mill == nil && rng.next(in: 0...1) < (want != nil ? 0.05 : 0.14) { pauseTo = t + 0.15 + rng.next(in: 0...0.45) }
        }
        var speed = still || t < pauseTo ? 0 : cruise
        if let w = want {
            let d = simd_length(w - SIMD2(x, y))
            // It walks around other ants rather than over them, turning away (and a little to its right, so two
            // meeting head on pass each other) once one is within 45 pt.
            var dir = (w - SIMD2(x, y)) / max(d, 1e-6)
            for o in others {
                let off = SIMD2(x, y) - o, l = simd_length(off)
                if l > 0.5 && l < 45 { let away = off / l; dir += (away + SIMD2(-away.y, away.x) * 0.5) * (45 - l) / 45 * 1.6 }
            }
            h += max(-9, min(9, wrap(atan2(dir.y, dir.x) - h) * 6)) * dt
            if mill == nil { speed *= d < 3 ? 0 : max(0.3, min(1, d / 30)) }
        } else if let f = faceTo {
            h += max(-7, min(7, wrap(atan2(f.y - y, f.x - x) - h) * 7)) * dt
        }
        if speed > 0 { h += turn * dt * 2.5 } else if nervous && faceTo == nil && want == nil { h += turn * dt * 1.2 }
        let m = 36.0
        if act != .leave && act != .wait && !homing && (x < m || x > screen.x - m || y < m || y > screen.y - m) {
            h += max(-1, min(1, wrap(atan2(screen.y / 2 - y, screen.x / 2 - x) - h))) * 5 * dt
        }
        h += spin * dt; spin *= exp(-dt * 9)
        v += (speed - v) * min(1, dt * 12)
        x += cos(h) * v * dt; y += sin(h) * v * dt
        gait += v * dt / (Ant.stride * Ant.scale * max(0.2, size.x)) * .pi
        let len = 6.6 * Ant.scale * size.x, back = SIMD2(x, y) - tail, bl = max(1e-6, simd_length(back))
        tail = SIMD2(x, y) - back / bl * len
        size.step(dt); rear.step(dt); antennae.step(dt); curl.step(dt)
        // Tripod 1 is R1 L2 R3, tripod 0 is L1 R2 L3: the abdomen swings toward the side whose front and hind legs step.
        let up = [0, 1].map { g in feet.contains { $0.tripod == g && $0.s < 1 } }
        hips.target = up[1] == up[0] ? 0 : up[1] ? 1 : -1
        hips.step(dt)
        stepFeet(dt)
    }

    private func stepFeet(_ dt: Double) {
        let unit = Ant.scale * size.x, moving = v > 2, half = moving ? Ant.stride / 2 : 0
        for n in feet.indices where feet[n].s < 1 {
            feet[n].s = min(1, feet[n].s + dt / Ant.stepTime)
            let s = feet[n].s, e = s * s * (3 - 2 * s)
            feet[n].at = feet[n].from + (feet[n].to - feet[n].from) * e
        }
        guard !feet.contains(where: { $0.s < 1 }) else { return }
        let far = feet.map { simd_length($0.at - rest($0.i, $0.side, ahead: half)) }
        // Land where the step spot will be when the foot comes down; pushing off one side turns the body to the other.
        func lift(_ n: Int) {
            feet[n].from = feet[n].at; feet[n].s = 0
            feet[n].to = rest(feet[n].i, feet[n].side, ahead: half + (moving ? v * Ant.stepTime / unit : 0))
            if moving { spin -= feet[n].side * (feet[n].i == 1 ? 0.25 : 0.45) }
        }
        if moving {
            // Walking, a tripod lifts its three feet together once any foot is a stride behind its step spot, and the
            // two tripods take turns.
            guard far.contains(where: { $0 > Ant.stride * unit }) else { return }
            lastTripod = 1 - lastTripod
            for n in feet.indices where feet[n].tripod == lastTripod { lift(n) }
        } else if let n = far.indices.first(where: { far[$0] > 2.2 * unit }) {
            // Standing, a foot left out settles back under, one at a time.
            lift(n)
        }
    }

    private func think(t: Double, dt: Double, screen: SIMD2<Double>, listenAt: SIMD2<Double>?, rng: inout SplitMix) {
        let el = t - since
        // Settled acts happen at its own spot (a second one that needs you waves from there): away from it (back from
        // the middle, from off screen, or drifted off), it walks back first.
        let settled = [.wander, .work, .done, .failed, .sleep].contains(act) || (act == .needs && !front)
        if settled && (homing || simd_length(home - SIMD2(x, y)) > 45) {
            guard simd_length(home - SIMD2(x, y)) < 5 else {
                homing = true; goal = home; mill = nil; still = false; nervous = false; cruise = 50; curl.target = 0
                return
            }
            homing = false
            set(act, at: t, rng: &rng)
        }
        switch act {
        case .wander:
            // Nothing going on, so it mostly stands; now and then it takes a short stroll.
            if let g = goal, simd_length(g - SIMD2(x, y)) < 4 {
                goal = nil; still = true; nervous = false; nextStroll = t + rng.next(in: 30...90)
            } else if goal == nil && t > nextStroll {
                goal = near(15...40, screen, &rng); still = false; nervous = true; cruise = 26
            }
        case .work:
            // It moves as much as its session does: each hook event sends it on a short errand, and each errand
            // ends in reading, antennae drumming the ground. With no new events it just stands, antennae still.
            // Without event counts (Bluetooth), an errand every 6 to 10 s.
            let errand = events == nil ? t > nextStroll : worked > since && worked > nextStroll
            if until > 0 {
                if t > until { until = 0; tap = events == nil || t - worked < 20 ? 0.25 : 0 }
            } else if let g = goal {
                if simd_length(g - SIMD2(x, y)) < 6 { goal = nil; still = true; tap = 1; until = t + 0.9 + rng.next(in: 0...1.2) }
            } else if errand || flags == 0 {
                flags = 1; nextStroll = events == nil ? t + rng.next(in: 6...10) : t
                goal = near(20...50, screen, &rng); still = false; tap = 0
            } else {
                still = true
                if events != nil && t - worked > 20 { tap = 0 }
            }
        case .needs:
            // The one forward runs to the middle, grows, rears and waves; another that needs you waves where it is.
            if !front {
                still = true; faceTo = SIMD2(x, y + 100); size.target = 1.3; rear.target = 0.5; wave = 1; antennae.target = 1
            } else if flags == 0 {
                goal = SIMD2(screen.x / 2, screen.y / 2 - 30)
                if simd_length(goal! - SIMD2(x, y)) < 4 {
                    flags = 1; goal = nil; still = true; faceTo = SIMD2(x, y + 100)
                    size.target = 2.2; rear.target = 1; wave = 1; antennae.target = 1
                }
            }
        case .done:
            // Only an ant that needs you tries to catch your eye; a finished one just lifts its antennae for a moment.
            if el > 2.5 && flags == 0 { flags = 1; antennae.target = 0 }
        case .failed:
            // Failed, it stands with antennae drooped, a little lower; no fuss, it doesn't need you yet.
            break
        case .sleep:
            // Curls into a C where it is, legs gathered in, breathing; now and then it twitches.
            if el > 1 && !still { still = true; antennae.target = -1; curl.target = 1 }
            if still {
                size.target = 1 + 0.04 * sin(t * 1.3)
                if rng.next(in: 0...1) < dt * 0.15 { size.v += 1.5 }
            }
        case .listen:
            still = true; faceTo = listenAt ?? SIMD2(screen.x / 2, screen.y - 120); antennae.target = 1; tap = 0.35
        case .aside:
            // Reading: the one talking goes to the corner by the text and faces in.
            if flags == 0 {
                flags = 1; goal = SIMD2(44, 70)
            } else if let g = goal, simd_length(g - SIMD2(x, y)) < 4 {
                goal = nil; still = true; faceTo = SIMD2(screen.x / 2, screen.y / 2)
            }
        case .wait:
            // The others walk off the nearest edge and wait just past it.
            if flags == 0 {
                flags = 1; goal = offEdge(screen)
            } else if let g = goal, simd_length(g - SIMD2(x, y)) < 4 {
                goal = nil; still = true
            }
        case .leave:
            if goal == nil { goal = offEdge(screen) }
        }
    }

    /// The nearest spot just off the screen.
    private func offEdge(_ screen: SIMD2<Double>) -> SIMD2<Double> {
        let edges: [(Double, SIMD2<Double>)] = [(x, SIMD2(-60, y)), (screen.x - x, SIMD2(screen.x + 60, y)),
                                                (y, SIMD2(x, -60)), (screen.y - y, SIMD2(x, screen.y + 60))]
        return edges.min { $0.0 < $1.0 }!.1
    }

    /// A spot a short way off, within 30 pt of its own spot and on screen.
    private func near(_ r: ClosedRange<Double>, _ screen: SIMD2<Double>, _ rng: inout SplitMix) -> SIMD2<Double> {
        let a = rng.next(in: 0...(2 * .pi)), d = rng.next(in: r)
        var p = SIMD2(x + cos(a) * d, y + sin(a) * d)
        let off = p - home, l = simd_length(off)
        if l > 30 { p = home + off / l * 30 }
        return SIMD2(max(50, min(screen.x - 50, p.x)), max(70, min(screen.y - 70, p.y)))
    }

    /// The drawing, and its size so bigger ants draw on top.
    func shape(id: String, t: Double) -> (Double, AntShape) {
        let s = size.x * Ant.scale, r = rear.x, cu = curl.x, c = cos(h), sn = sin(h)
        let world = { (p: SIMD2<Double>) in SIMD2(self.x + (p.x * c - p.y * sn) * s, self.y + (p.x * sn + p.y * c) * s) }
        func rotated(_ p: SIMD2<Double>, about o: SIMD2<Double>, by a: Double) -> SIMD2<Double> {
            let d = p - o
            return o + SIMD2(d.x * cos(a) - d.y * sin(a), d.x * sin(a) + d.y * cos(a))
        }
        func oval(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ map: (SIMD2<Double>) -> SIMD2<Double>) -> [SIMD2<Double>] {
            (0..<20).map { k in let a = Double(k) / 20 * 2 * .pi; return world(map(SIMD2(cx + cos(a) * rx, cy + sin(a) * ry))) }
        }
        var strokes: [(points: [SIMD2<Double>], width: Double)] = []
        guard s > 0.01 else { return (size.x, AntShape(id: id, fills: [], strokes: [], centre: SIMD2(x, y), planted: feet.map { $0.s < 1 ? nil : $0.at })) }

        // Legs: each foot is where it was planted; two-bone IK finds the knee, bent outward. Rearing lifts the front
        // pair off the ground to wave. Thighs are drawn thicker than shins, so a leg tapers.
        var thighs: [(points: [SIMD2<Double>], width: Double)] = [], shins = thighs
        for f in feet {
            let l = Ant.legs[f.i], hy = 0.9 * f.side
            let d0 = (f.at - SIMD2(x, y)) / s
            var p = SIMD2(d0.x * c + d0.y * sn, -d0.x * sn + d0.y * c)
            if f.i == 0 && r > 0.05 {
                let w = SIMD2(l.x + 2.5, (l.y - 2.2 + sin(t * 9 + f.side) * 1.5) * f.side)
                p += (w - p) * r
            }
            if f.s < 1 { p.y += sin(f.s * .pi) * 0.28 * f.side }
            // Seen from above, a leg's knee is raised, so it shows as a nearly straight line with a slight outward
            // bend; the bend grows a little when the foot comes in close.
            let hip = SIMD2(l.hip, hy), dv = p - hip, d = max(1e-6, simd_length(dv)), reach = hypot(l.x - l.hip, l.y - 0.9)
            var out = SIMD2(-dv.y, dv.x) / d
            if out.y * f.side < 0 { out = -out }
            let knee = hip + dv * 0.42 + out * (0.35 + max(0, reach - d) * 0.3)
            thighs.append(([world(SIMD2(l.hip, hy)), world(knee)], 0.85 * s))
            shins.append(([world(knee), world(p)], 0.5 * s))
        }
        strokes = thighs + shins
        // Body: abdomen and waist bend at the waist (the rope, plus curling up), then thorax, then the head, which
        // turns at the neck when curling.
        let bend = max(-0.7, min(0.7, wrap(atan2(y - tail.y, x - tail.x) - h))) + cu * 0.95 - hips.x * 0.16
        // Proportions after a real ant's: a narrow thorax, a small waist, an abdomen about twice as long as wide, and
        // a gap at each joint.
        let waist = { (p: SIMD2<Double>) in rotated(p + SIMD2(-1.9, 0), about: SIMD2(-1.9, 0), by: bend) }
        // Walking, the head bobs with each step: a nod forward and a slight swing to the side of the tripod pushing.
        let walking = min(1, v / 20), sway = sin(gait) * 0.14 * walking
        let neckAt = SIMD2(3.0 + r, 0.0), neck = { (p: SIMD2<Double>) in rotated(p, about: neckAt, by: -cu * 0.7 + sway) }
        let lift = 1 + 0.18 * r, hx = 5.1 + 1.6 * r + tap * 0.4 * sin(t * 30) + abs(cos(gait)) * 0.35 * walking
        let fills = [oval(-4.7, 0, 4.2, 2.6 * (1 + 0.03 * sin(t * 2 + phase)), waist), oval(0, 0, 0.8, 0.7, waist),
                     oval(0.8 + r, 0, 2.2 * lift, 1.4 * lift, { $0 }), oval(hx, 0, 2.3 * lift, 2.2 * lift, neck)]
        // Antennae, elbowed: up or drooped, drumming, the big wave; curled up, folded back and shorter.
        for side in [-1.0, 1.0] {
            let base = 0.7 + cu * 0.6 - antennae.x * 0.35 + tap * 0.25 * sin(t * 28 + side * 1.7) + wave * 0.6 * sin(t * 7 + side)
            let sc = 4.2 * (1 - 0.35 * cu), fu = 5.2 * (1 - 0.45 * cu)
            let root = SIMD2(hx + 1.6, side * 1.0), elbow = SIMD2(hx + 1.6 + cos(base) * sc, side * (1.0 + sin(base) * sc))
            let tip = base - 0.9 - antennae.x * 0.2 + cu * 1.6
            let end = elbow + SIMD2(cos(tip) * fu, side * sin(tip) * fu)
            strokes.append(([root, elbow, end].map { world(neck($0)) }, 0.7 * s))
        }
        return (size.x, AntShape(id: id, fills: fills, strokes: strokes, centre: SIMD2(x, y), planted: feet.map { $0.s < 1 ? nil : $0.at }))
    }
}

private func wrap(_ a: Double) -> Double { atan2(sin(a), cos(a)) }

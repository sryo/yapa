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
    /// Where the finger is while talking, and the session whose ant it holds: only that ant reacts, stepping out from
    /// under the fingertip to face it.
    public var listenAt: SIMD2<Double>?, listener: String?
    /// The session whose text is open: its ant waits in the top left corner, beside the text, and the others walk off
    /// the nearest edge until it closes, then come back to where they were, so it's clear who's talking.
    public var solo: String?
    /// Where the ant whose text is open stands: beside the text's first line, wherever the text is.
    public var byText: SIMD2<Double>?
    /// Each session started by another, and the one that started it: its ant's spot is beside that one's.
    public var families: [String: String] = [:]
    /// When each working session's turn began. Its ant drops a crumb by its spot each minute of the turn, so how long
    /// it's been at it shows without words, and picks them up when it stops.
    public var working: [String: Double] = [:]
    /// Sessions whose finished turn you haven't looked at: their ants keep their crumbs until you do, so from across
    /// the room a pile by a still ant says "done, not seen yet".
    public var unseen: Set<String> = []
    struct Crumb { var at: SIMD2<Double>, shape: [SIMD2<Double>], born: Double }
    /// How far a pile sits from its ant's spot.
    static let pileAt = 25.0
    private var piles: [String: (crumbs: [Crumb], gone: Double?)] = [:], crumbRng: SplitMix

    static let step = 1.0 / 120
    private var ants: [String: Ant] = [:], order: [String] = []
    private var now: Double, rng: SplitMix

    public init(seed: UInt64, now: Double) {
        self.now = now
        rng = SplitMix(seed)
        crumbRng = SplitMix(seed ^ 0x6372756d62) // its own, so crumbs never change how the ants move
    }

    /// The sessions to show and their moods; `front` is the one standing forward for a prompt, and `events` counts its
    /// hook events (nil when unknown, over Bluetooth), so a busy ant moves only as much as its session does.
    public func update(_ sessions: [(id: String, mood: Mood, front: Bool, events: Int?)], at t: Double) {
        advance(to: t)
        let ids = Set(sessions.map(\.id))
        for id in order where !ids.contains(id) { if let a = ants[id], a.act != .leave { a.set(.leave, at: t, rng: &rng) } }
        let homes = Colony.homes(sessions.map(\.id), families: families, screen)
        for s in sessions {
            let home = homes[s.id] ?? screen / 2
            let a = ants[s.id] ?? {
                // A new session's ant appears at its spot, unless another is still standing there (the spots moved
                // to make room): then it walks in from the nearest edge.
                let taken = ants.values.contains { $0.act != .leave && simd_length(SIMD2($0.x, $0.y) - home) < 45 }
                let edges = [SIMD2(-30, home.y), SIMD2(screen.x + 30, home.y), SIMD2(home.x, -30), SIMD2(home.x, screen.y + 30)]
                let from = taken ? edges.min { simd_length($0 - home) < simd_length($1 - home) }! : home
                let a = Ant(at: from, heading: rng.next(in: 0...(2 * .pi)), rng: &rng)
                if !taken { a.size.x = 0 }
                ants[s.id] = a; order.append(s.id)
                return a
            }()
            a.home = home
            a.thinking = s.mood == .focused
            let listening = listenAt != nil && s.id == listener
            var act = solo == nil ? Colony.act(for: s.mood, front: s.front, listening: listening) : s.id == solo ? .aside : .wait
            // Crumbs say a turn waits to be seen, so an ant beside its pile stays up.
            if act == .sleep, let p = piles[s.id], p.gone == nil, !p.crumbs.isEmpty { act = .rest }
            if a.act != act || a.front != s.front {
                let was = a.act
                a.front = s.front
                a.set(act, at: t, rng: &rng)
                if act == .needs && s.front { a.stage = stage(for: s.id) }
                // Let go of, it nods; leaving for the text, the ones nearest an edge go first, and coming back the
                // ones nearest their spots do.
                if was == .listen { a.nodAt = t; a.homing = true }
                if act == .wait { a.departAt = t + 0.3 * Double(rank(id: s.id) { $0.edgeDistance(screen) }) }
                if was == .wait { a.returnAt = t + 0.3 * Double(rank(id: s.id) { simd_length($0.spot - SIMD2($0.x, $0.y)) }) }
            }
        }
        // While one needs you, the others hold still.
        let calling = ants.values.contains { $0.act == .needs && $0.front }
        for a in ants.values { a.hushed = calling && !(a.act == .needs && a.front) }
        drop(at: t)
    }

    /// Where the ant that needs you stands: near the middle, at the place clearest of the other ants' spots (they
    /// hold still meanwhile), so a big ant never lands on one.
    private func stage(for id: String) -> SIMD2<Double> {
        let mid = SIMD2(screen.x / 2, screen.y / 2 - 30)
        let others = ants.filter { $0.key != id && $0.value.act != .leave }.map(\.value.spot)
        var best = mid, score = -Double.infinity
        for dx in stride(from: -150.0, through: 150, by: 30) {
            for dy in stride(from: -40.0, through: 40, by: 20) {
                let p = mid + SIMD2(dx, dy)
                guard p.x > 60, p.x < screen.x - 60, p.y > 60, p.y < screen.y - 60 else { continue }
                // Clear by 70 pt is enough; past that, nearer the middle is better.
                let clear = min(70, others.map { simd_length($0 - p) }.min() ?? 70)
                let sc = clear - simd_length(p - mid) * 0.05
                if sc > score { score = sc; best = p }
            }
        }
        return best
    }

    /// Where an ant comes among the others still here, by `key`, smallest first.
    private func rank(id: String, by key: (Ant) -> Double) -> Int {
        guard let me = ants[id] else { return 0 }
        return ants.filter { $0.key != id && $0.value.act != .leave && key($0.value) < key(me) }.count
    }

    /// A tap answered the request of the session whose ant is forward: allowed, it squashes and hurries home; denied,
    /// it droops and walks home slowly.
    public func answered(_ id: String, allowed: Bool) { ants[id]?.answered = allowed }

    /// How many crumbs a turn this long has dropped.
    static func crumbs(after d: Double) -> Int {
        Int(max(0, d) / 60)
    }

    private func drop(at t: Double) {
        piles = piles.filter { ants[$0.key] != nil }
        for id in order {
            guard let a = ants[id] else { continue }
            guard let from = working[id], a.act != .leave else {
                if unseen.contains(id) && a.act != .leave { continue }
                if piles[id] != nil, piles[id]?.gone == nil { piles[id]?.gone = t }
                if let g = piles[id]?.gone, t - g > 1 { piles[id] = nil }
                continue
            }
            var pile = piles[id] ?? ([], nil)
            if pile.gone != nil { pile = ([], nil) }
            while pile.crumbs.count < Colony.crumbs(after: t - from) {
                // One tight pile right beside its spot (it walks round the pile, never over it), on whichever side is
                // clearest of the other ants and the edges, toward the middle when that's as clear; each crumb packed
                // against the last on a sunflower spiral, so none falls on another.
                let first = pile.crumbs.first?.at ?? {
                    let others = ants.filter { $0.key != id && $0.value.act != .leave }.map(\.value.spot)
                    let toMiddle = a.spot.x <= screen.x / 2 ? 0.0 : Double.pi
                    return (0..<8).map { k -> SIMD2<Double> in
                        let ang = toMiddle + Double(k) * .pi / 4
                        return SIMD2(cos(ang), sin(ang)) * Colony.pileAt
                    }.max { p, q in
                        func clear(_ o: SIMD2<Double>) -> Double {
                            let at = a.spot + o, edge = min(at.x, screen.x - at.x, at.y, screen.y - at.y) * 2
                            return min(edge, others.map { simd_length($0 - at) }.min() ?? .infinity)
                        }
                        return clear(p) < clear(q) - 1
                    }!
                }()
                let k = Double(pile.crumbs.count), off = first + SIMD2(cos(k * 2.4), sin(k * 2.4)) * 3.1 * k.squareRoot()
                let r = crumbRng.next(in: 1.7...2.6), n = Int(crumbRng.next(in: 4...6.99)), turn = crumbRng.next(in: 0...6.3)
                let shape = (0..<n).map { i -> SIMD2<Double> in
                    let ang = turn + Double(i) / Double(n) * 2 * .pi
                    return SIMD2(cos(ang), sin(ang)) * r * crumbRng.next(in: 0.7...1.15)
                }
                pile.crumbs.append(Crumb(at: off, shape: shape, born: t))
            }
            piles[id] = pile
        }
    }

    /// Every crumb to draw, as a small filled outline, by its ant's spot (which creeps, so they creep too). Hidden
    /// while text or the dial is up; each grows in as it drops and shrinks away as its ant picks them up.
    public func crumbs(at t: Double) -> [[SIMD2<Double>]] {
        guard solo == nil else { return [] }
        return piles.flatMap { id, pile -> [[SIMD2<Double>]] in
            guard let a = ants[id] else { return [] }
            let out = pile.gone.map { max(0, 1 - (t - $0)) } ?? 1
            return pile.crumbs.map { c in
                let s = min(1, max(0, (t - c.born) / 0.4)) * out
                return c.shape.map { a.spot + c.at + $0 * s }
            }
        }
    }

    public func position(of id: String) -> SIMD2<Double>? { ants[id].map { SIMD2($0.x, $0.y) } }
    /// How hard an ant's antennae drum, 0 to 1.
    public func drumming(_ id: String) -> Double { ants[id]?.tap ?? 0 }
    /// What an ant is acting out, by name (rest, sleep, work, needs, …), for test/jeta-flows.
    public func acting(_ id: String) -> String? { ants[id].map { "\($0.act)" } }
    /// The spot an ant keeps to, creeping with it.
    public func spot(of id: String) -> SIMD2<Double>? { ants[id]?.spot }

    /// The ant nearest a point, within reach of a finger.
    public func hit(_ p: SIMD2<Double>) -> String? {
        ants.filter { $0.value.act != .leave && simd_length(SIMD2($0.value.x, $0.value.y) - p) < 40 * max(1, $0.value.size.x) }
            .min { simd_length(SIMD2($0.value.x, $0.value.y) - p) < simd_length(SIMD2($1.value.x, $1.value.y) - p) }?.key
    }

    /// Whether anything is moving enough to need 60 fps; ants standing about need only 30.
    public var isActive: Bool {
        ants.values.contains { $0.v > 0.5 || $0.feet.contains { $0.s < 1 } || [.needs, .done, .listen].contains($0.act) }
    }

    /// Whether an ant is trying to catch your eye, so the screen stays bright.
    public var needsYou: Bool { ants.values.contains { $0.act == .needs } }

    public func shapes(at t: Double) -> [AntShape] {
        advance(to: t)
        return order.compactMap { id in ants[id].map { $0.shape(id: id, t: now) } }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Each session's own spot, in the order they started: one in the middle, more on a grid shaped like the screen,
    /// so ants are far apart and each stays where you know it.
    static func homes(_ n: Int, _ screen: SIMD2<Double>) -> [SIMD2<Double>] {
        guard n > 1 else { return n == 1 ? [screen / 2] : [] }
        let g = grid(n, screen), area = area(screen)
        return (0..<n).map { k in
            // A last row that isn't full is centred.
            let row = k / g.columns, inRow = row == g.rows - 1 ? n - row * g.columns : g.columns
            let col = Double(k % g.columns) + Double(g.columns - inRow) / 2
            return SIMD2(area.x + g.cell.x * (col + 0.5), area.y + g.cell.y * (Double(row) + 0.5))
        }
    }

    /// The part of the screen spots go in: clear of the top and bottom, with more room there on a tall screen for the
    /// text. Its top left corner and size.
    static func area(_ screen: SIMD2<Double>) -> SIMD4<Double> {
        // Across, the cells reach the edges (a spot sits mid-cell, well clear of them).
        let my = max(50, screen.y * 0.19)
        return SIMD4(0, my, screen.x, screen.y - 2 * my)
    }

    /// Columns and rows for `n` spots, shaped like the screen, so on the landscape pad four sessions sit three and
    /// one rather than in two cramped columns; and each spot's share of the area.
    static func grid(_ n: Int, _ screen: SIMD2<Double>) -> (columns: Int, rows: Int, cell: SIMD2<Double>) {
        let a = area(screen)
        let columns = max(1, min(n, Int((Double(n) * a.z / a.w).squareRoot().rounded(.up))))
        let rows = (n + columns - 1) / columns
        return (columns, rows, SIMD2(a.z / Double(columns), a.w / Double(rows)))
    }

    /// The spots by family: each session that no other here started gets one of `homes(_:_:)`, and the ones it started
    /// (and theirs) stand round it, below first, on a ring as wide as its share of the screen allows.
    static func homes(_ ids: [String], families: [String: String], _ screen: SIMD2<Double>) -> [String: SIMD2<Double>] {
        let here = Set(ids)
        func root(_ id: String) -> String {
            var r = id, seen: Set = [id]
            while let p = families[r], here.contains(p), seen.insert(p).inserted { r = p }
            return r
        }
        let roots = ids.filter { root($0) == $0 }, spots = homes(roots.count, screen)
        let cell = roots.count == 1 ? SIMD2(screen.x, screen.y - 220) : grid(roots.count, screen).cell
        let ring = max(60, min(90, 0.42 * min(cell.x, cell.y)))
        var out: [String: SIMD2<Double>] = [:]
        for (r, spot) in zip(roots, spots) {
            out[r] = spot
            let kin = ids.filter { $0 != r && root($0) == r }
            for (k, id) in kin.enumerated() {
                // Six to a ring, the first from straight below, spreading either side; more go on a wider ring.
                let j = k / 6, on = min(6, kin.count - 6 * j), i = Double(k % 6) - Double(on - 1) / 2
                let a = Double.pi / 2 + i * 2 * .pi / Double(max(on, 5)), d = ring * (1 + 0.7 * Double(j))
                let p = spot + SIMD2(cos(a), sin(a)) * d
                out[id] = SIMD2(min(max(p.x, 40), screen.x - 40), min(max(p.y, 70), screen.y - 70))
            }
        }
        return out
    }

    static func act(for mood: Mood, front: Bool, listening: Bool) -> Ant.Act {
        // Four situations: it needs you (a failed turn too), it's busy, it's your turn (done, then resting, then
        // asleep), or it's gone.
        if listening || mood == .listening { return .listen }
        switch mood {
        // Curious is the Buddy link's word for a session reading or searching: running a tool like any other.
        case .busy, .focused, .curious: return .work
        case .attention, .impatient, .dizzy: return .needs
        case .celebrate, .proud, .heart: return .done
        case .idle, .bored, .listening: return .rest
        case .sleep: return .sleep
        }
    }

    private func advance(to t: Double) {
        // In the order they came, since each draws from the one generator: a dictionary's order changes every run.
        let inOrder = order.compactMap { ants[$0] }
        var spots: [SIMD2<Double>] = [], heaps: [SIMD2<Double>] = []
        spots.reserveCapacity(inOrder.count); heaps.reserveCapacity(piles.count)
        while now < t {
            let dt = min(Colony.step, t - now)
            now += dt
            // Ants walk around each other, and closer round the crumb piles, never over them.
            spots.removeAll(keepingCapacity: true); heaps.removeAll(keepingCapacity: true)
            for a in inOrder where a.act != .leave { spots.append(SIMD2(a.x, a.y)) }
            for (id, p) in piles where p.gone == nil { if let c = p.crumbs.first, let a = ants[id] { heaps.append(a.spot + c.at) } }
            for a in inOrder { a.byText = byText }
            for a in inOrder { a.update(dt, t: now, screen: screen, listenAt: listenAt, others: spots, piles: heaps, rng: &rng) }
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
    enum Act { case rest, sleep, work, needs, done, listen, leave, aside, wait }

    /// The body is ~15 units nose to tail, drawn at `scale` points a unit: ~22 pt; one that needs you grows 2.2 times.
    static let scale = 1.45
    /// Where each foot rests, in body units: hip x, foot forward, foot out. As in a real ant, all six hips are on the
    /// thorax, close together, and the legs are long: the front pair reaches past the head, the hind pair past the
    /// abdomen.
    static let legs: [(hip: Double, x: Double, y: Double)] = [(1.3, 8.6, 6.4), (0.7, 0.6, 8.8), (0.1, -9.6, 7.2)]
    /// A stride, in body units, and how long a foot is in the air.
    static let stride = 4.6, stepTime = 0.1
    /// Twenty points round a unit circle, what every body part's oval is drawn from.
    static let circle = (0..<20).map { k -> SIMD2<Double> in let a = Double(k) / 20 * 2 * .pi; return SIMD2(cos(a), sin(a)) }

    struct Foot { var i: Int, side: Double, tripod: Int, at: SIMD2<Double>, from: SIMD2<Double>, to: SIMD2<Double>, s = 1.0 }

    var x: Double, y: Double, h: Double, v = 0.0, spin = 0.0, tail: SIMD2<Double>
    var act = Act.rest, front = false, since = 0.0, until = 0.0, flags = 0
    var goal: SIMD2<Double>?, faceTo: SIMD2<Double>?
    var still = true, nervous = true, cruise = 44.0
    var twitchAt = 0.0, turn = 0.0, pauseTo = 0.0, tap = 0.0, wave = 0.0, phase: Double
    /// Busy with no tool running: the model is thinking.
    var thinking = false
    /// Where to stand while its text is open.
    var byText: SIMD2<Double>?
    /// Busy: where it's walking toward this frame, the course it wanders along and how fast that turns, and how far
    /// from its spot it may roam.
    var aim: SIMD2<Double>?, wander = 0.0, wanderV = 0.0, leash = 28.0
    /// Its own walking tempo when busy, so no two ants move alike.
    var tempo = 1.0
    /// How fast it walks compared with the others, so ants walking together don't step in time.
    var pace = 1.0
    /// Needing you: when it next pulses. Another needs you, so it holds still. How the request it made was answered.
    var pulseAt = 0.0, hushed = false, answered: Bool?, stage: SIMD2<Double>?
    /// Leaving for the text and coming back after, each in turn; how fast it walks home; when it last nodded.
    var departAt = 0.0, returnAt = 0.0, homeCruise = 50.0, nodAt = -10.0
    /// Its session's own spot, which it keeps to, and whether it's walking back there.
    var home: SIMD2<Double>, homing = false, crept = SIMD2<Double>(0, 0)
    var spot: SIMD2<Double> { home + crept }
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
        tempo = rng.next(in: 0.75...1.35)
        pace = rng.next(in: 0.85...1.15); leash = rng.next(in: 24...32)
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
        let was = act
        act = a; since = t; flags = 0; until = 0
        goal = nil; faceTo = nil; aim = nil; still = false; nervous = false; cruise = 44; tap = 0; wave = 0
        // Held to talk, it keeps the size its situation gave it.
        if a != .listen { size.target = 1 }
        rear.target = 0; antennae.target = 0; curl.target = 0
        switch a {
        case .work: antennae.target = 0.3; wander = h; wanderV = 0
        // A short freeze and a pop, then it runs to the middle.
        case .needs: still = true; until = t + 0.25; size.v += 3.5; cruise = 90; pulseAt = t + 3
        case .done: still = true; antennae.target = 0.7
        case .rest, .sleep: still = true
        case .leave: cruise = 50
        case .aside: cruise = 80
        case .wait: cruise = 85; still = true
        case .listen: break
        }
        // Answered: allowed, a squash and a quick trip home; denied, it droops and walks home slowly.
        if was == .needs, a != .needs, let ok = answered {
            answered = nil
            if ok { size.v -= 5; homeCruise = 110 } else { antennae.target = -1; homeCruise = 22 }
        }
    }

    /// How far it is from the nearest edge of the screen.
    func edgeDistance(_ screen: SIMD2<Double>) -> Double { min(x, screen.x - x, y, screen.y - y) }

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

    func update(_ dt: Double, t: Double, screen: SIMD2<Double>, listenAt: SIMD2<Double>?, others: [SIMD2<Double>] = [], piles: [SIMD2<Double>] = [],
                rng: inout SplitMix) {
        think(t: t, dt: dt, screen: screen, listenAt: listenAt, rng: &rng)
        // Standing still, it creeps along the drift (and turns, unless it's facing something); its feet stretch and,
        // now and then, take a small step to settle.
        // At an edge the drift turns back rather than stopping there.
        let d = drifted(t) - drifted(t - dt), reach = act == .needs ? 15.0 : 25.0, e = 30.0
        if (x < e && d.x * bounce.x < 0) || (x > screen.x - e && d.x * bounce.x > 0) { bounce.x = -bounce.x }
        if (y < e && d.y * bounce.y < 0) || (y > screen.y - e && d.y * bounce.y > 0) { bounce.y = -bounce.y }
        // A small circle, faster than the waves ever get, keeps it creeping even when they turn or cancel.
        let w = 2 * Double.pi / 30
        let step = SIMD2(d.x * bounce.x, d.y * bounce.y) * reach
            + 3.1 * SIMD2(cos(w * t + drift.z) - cos(w * (t - dt) + drift.z), sin(w * t + drift.z) - sin(w * (t - dt) + drift.z))
        // Its spot drifts too, so creeping never takes it far enough from there to walk back.
        crept += step
        if still && goal == nil {
            x += step.x; y += step.y
            if faceTo == nil { h += d.z * 0.6 }
        }
        let want = goal ?? aim
        // The walk from the reference GIF: sharp heading jumps every few frames, and short dead stops.
        if t > twitchAt {
            turn = (rng.next(in: 0...1) - 0.5) * (want != nil ? 0.8 : 2.2)
            twitchAt = t + 0.1 + rng.next(in: 0...0.28)
            if nervous && rng.next(in: 0...1) < (want != nil ? 0.05 : 0.14) { pauseTo = t + 0.15 + rng.next(in: 0...0.45) }
        }
        var speed = still || t < pauseTo ? 0 : cruise * pace
        if let w = want {
            let d = simd_length(w - SIMD2(x, y))
            // It walks around other ants rather than over them, turning away (and a little to its right, so two
            // meeting head on pass each other) once one is within 45 pt.
            var dir = (w - SIMD2(x, y)) / max(d, 1e-6)
            func avoid(_ o: SIMD2<Double>, within near: Double) {
                let off = SIMD2(x, y) - o, l = simd_length(off)
                if l > 0.5 && l < near { let away = off / l; dir += (away + SIMD2(-away.y, away.x) * 0.5) * (near - l) / near * 1.6 }
            }
            for o in others { avoid(o, within: 45) }
            for o in piles { avoid(o, within: 22) }
            h += max(-9, min(9, wrap(atan2(dir.y, dir.x) - h) * 6)) * dt
            if aim == nil { speed *= d < 3 ? 0 : max(0.3, min(1, d / 30)) }
        } else if let f = faceTo {
            h += max(-7, min(7, wrap(atan2(f.y - y, f.x - x) - h) * 7)) * dt
        }
        if speed > 0 && aim == nil { h += turn * dt * 2.5 } else if nervous && faceTo == nil && want == nil { h += turn * dt * 1.2 }
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
        let up0 = feet.contains { $0.tripod == 0 && $0.s < 1 }, up1 = feet.contains { $0.tripod == 1 && $0.s < 1 }
        hips.target = up1 == up0 ? 0 : up1 ? 1 : -1
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
        func far(_ f: Foot) -> Double { simd_length(f.at - rest(f.i, f.side, ahead: half)) }
        // Land where the step spot will be when the foot comes down; pushing off one side turns the body to the other.
        func lift(_ n: Int) {
            feet[n].from = feet[n].at; feet[n].s = 0
            feet[n].to = rest(feet[n].i, feet[n].side, ahead: half + (moving ? v * Ant.stepTime / unit : 0))
            if moving { spin -= feet[n].side * (feet[n].i == 1 ? 0.25 : 0.45) }
        }
        if moving {
            // Walking, a tripod lifts its three feet together once any foot is a stride behind its step spot, and the
            // two tripods take turns.
            guard feet.contains(where: { far($0) > Ant.stride * unit }) else { return }
            lastTripod = 1 - lastTripod
            for n in feet.indices where feet[n].tripod == lastTripod { lift(n) }
        } else if let n = feet.indices.first(where: { far(feet[$0]) > 2.2 * unit }) {
            // Standing, a foot left out settles back under, one at a time.
            lift(n)
        }
    }

    private func think(t: Double, dt: Double, screen: SIMD2<Double>, listenAt: SIMD2<Double>?, rng: inout SplitMix) {
        let el = t - since
        // Settled acts happen at its own spot (a second one that needs you waves from there): away from it (back from
        // the middle, from off screen, or drifted off), it walks back first.
        let settled: Bool
        switch act {
        case .rest, .sleep, .work, .done: settled = true
        case .needs: settled = !front
        default: settled = false
        }
        if settled && (homing || simd_length(spot - SIMD2(x, y)) > 45) {
            // Back from off screen, each waits its turn.
            guard t >= returnAt else { goal = nil; still = true; return }
            guard simd_length(spot - SIMD2(x, y)) < 5 else {
                homing = true; goal = spot; still = false; nervous = false; cruise = homeCruise; curl.target = 0
                return
            }
            homing = false; homeCruise = 50
            set(act, at: t, rng: &rng)
        }
        switch act {
        case .rest:
            // Your turn: it stands where it is (creeping against burn-in), done with its crumbs.
            break
        case .sleep:
            // Long left alone, it curls up where it stands, antennae folded; it still creeps against burn-in.
            if el > 1 { antennae.target = -1; curl.target = 1 }
        case .work:
            // Busy, thinking or running tools alike, it walks slowly about its spot and never stops: Reynolds' wander
            // on a leash. Where it heads drifts smoothly (a slowly wandering angle, no twitches), and the farther it gets
            // from its spot the harder it's pulled back, so it keeps to a patch about `leash` across without a set
            // path, and no pixel stays under it for long. Slower after five minutes. While another needs you it holds
            // still.
            // Thinking (no tool running), its antennae drum and its head shakes as it goes.
            tap += ((thinking ? 0.6 : 0) - tap) * min(1, 4 * dt)
            if hushed { aim = nil; still = true; break }
            still = false
            // The course it means to walk wanders on the screen, not relative to where it faces (which turned with it
            // and spun it in place): it turns at a rate that drifts at random, damped, and never tighter than a 15 pt
            // circle, so it changes its mind slowly.
            cruise = (el > 300 ? 9 : 14) * tempo
            let tightest = cruise * pace / 15
            wanderV += (-1.2 * wanderV + rng.next(in: -1...1) * 2.4) * dt
            wanderV = max(-tightest, min(tightest, wanderV))
            wander += wanderV * dt
            let ahead = SIMD2(cos(wander), sin(wander))
            let off = spot - SIMD2(x, y), d = simd_length(off)
            let pull = max(0, min(1, (d - 0.5 * leash) / (0.5 * leash)))
            let dir = simd_normalize(ahead + (d > 0.1 ? off / d : .zero) * pull * pull * 2.5)
            // The leash bends the course too, so the two never pull apart.
            wander += remainder(atan2(dir.y, dir.x) - wander, 2 * .pi) * min(1, dt * 2)
            aim = SIMD2(x, y) + dir * 12
        case .needs:
            // A short freeze first. Then the one forward runs to the middle, grows, rears and waves; another that needs
            // you waves where it is. Each pulses, its whole body, every 3 s for a minute and then every 15 s until
            // answered; a second one at half that rate.
            if t < until { break }
            if t > pulseAt { size.v += 3; pulseAt = t + (el < 60 ? 3 : 15) * (front ? 1 : 2) }
            if !front {
                still = true; faceTo = SIMD2(x, y + 100); size.target = 1.3; rear.target = 0.5; wave = 1; antennae.target = 1
            } else if flags == 0 {
                still = false; goal = stage ?? SIMD2(screen.x / 2, screen.y / 2 - 30)
                if simd_length(goal! - SIMD2(x, y)) < 4 {
                    flags = 1; goal = nil; still = true; faceTo = SIMD2(x, y + 100)
                    size.target = 2.2; rear.target = 1; wave = 1; antennae.target = 1
                }
            }
        case .done:
            // Only an ant that needs you tries to catch your eye; a finished one turns once on the spot and lifts its
            // antennae for a moment.
            if el < 1 { spin = 2 * .pi }
            if el > 2.5 && flags == 0 { flags = 1; antennae.target = 0 }
        case .listen:
            // Held to talk, it steps about 40 pt out from under the fingertip, to the side with the most room, and
            // faces the finger while you talk.
            let f = listenAt ?? SIMD2(screen.x / 2, screen.y - 120)
            if flags == 0 {
                flags = 1
                let room = { (p: SIMD2<Double>) in min(p.x, screen.x - p.x, p.y, screen.y - p.y) }
                let away = simd_length(SIMD2(x, y) - f) > 1 ? simd_normalize(SIMD2(x, y) - f) : SIMD2(1, 0)
                // Straight away from the finger unless another way has clearly more room.
                let ways = [away, SIMD2(1, 0), SIMD2(-1, 0), SIMD2(0, 1), SIMD2(0, -1)].map { f + $0 * 40 }
                let score = ways.enumerated().map { room($1) + ($0 == 0 ? 8 : 0) }
                let to = ways[score.indices.max { score[$0] < score[$1] }!]
                if simd_length(SIMD2(x, y) - f) < 36 { goal = to; still = false; cruise = 70 }
            }
            if let g = goal, simd_length(g - SIMD2(x, y)) < 4 { goal = nil }
            if goal == nil { still = true; faceTo = f; antennae.target = 1; tap = 0.35 }
        case .aside:
            // Reading: the one talking stands beside its text and faces in, following the text if it moves.
            let by = byText ?? SIMD2(44, 70)
            if flags == 0 || (goal == nil && simd_length(by - SIMD2(x, y)) > 8) {
                flags = 1; goal = by; still = false
            } else if goal != nil, simd_length(by - SIMD2(x, y)) < 4 {
                goal = nil; still = true; faceTo = SIMD2(screen.x / 2, screen.y / 2)
            } else if goal != nil { goal = by }
        case .wait:
            // The others walk off the nearest edge, one after another, and wait just past it.
            if flags == 0 && t >= departAt {
                still = false
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

    /// The drawing, and its size so bigger ants draw on top.
    func shape(id: String, t: Double) -> (Double, AntShape) {
        let s = size.x * Ant.scale, r = rear.x, cu = curl.x, c = cos(h), sn = sin(h)
        let world = { (p: SIMD2<Double>) in SIMD2(self.x + (p.x * c - p.y * sn) * s, self.y + (p.x * sn + p.y * c) * s) }
        // A turn by an angle whose cosine and sine are worked out once per frame, not once per point.
        func rotated(_ p: SIMD2<Double>, about o: SIMD2<Double>, cos ca: Double, sin sa: Double) -> SIMD2<Double> {
            let d = p - o
            return o + SIMD2(d.x * ca - d.y * sa, d.x * sa + d.y * ca)
        }
        func oval(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ map: (SIMD2<Double>) -> SIMD2<Double>) -> [SIMD2<Double>] {
            Ant.circle.map { u in world(map(SIMD2(cx + u.x * rx, cy + u.y * ry))) }
        }
        guard s > 0.01 else { return (size.x, AntShape(id: id, fills: [], strokes: [], centre: SIMD2(x, y), planted: feet.map { $0.s < 1 ? nil : $0.at })) }

        // Legs: each foot is where it was planted; two-bone IK finds the knee, bent outward. Rearing lifts the front
        // pair off the ground to wave. Thighs are drawn thicker than shins, so a leg tapers.
        var strokes = [(points: [SIMD2<Double>], width: Double)](repeating: ([], 0), count: 2 * feet.count)
        strokes.reserveCapacity(2 * feet.count + 4)
        for (n, f) in feet.enumerated() {
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
            strokes[n] = ([world(SIMD2(l.hip, hy)), world(knee)], 0.85 * s)
            strokes[feet.count + n] = ([world(knee), world(p)], 0.5 * s)
        }
        // Body: abdomen and waist bend at the waist (the rope, plus curling up), then thorax, then the head, which
        // turns at the neck when curling.
        let bend = max(-0.7, min(0.7, wrap(atan2(y - tail.y, x - tail.x) - h))) + cu * 0.95 - hips.x * 0.16
        // Proportions after a real ant's: a narrow thorax, a small waist, an abdomen about twice as long as wide, and
        // a gap at each joint.
        let (bc, bs) = (cos(bend), sin(bend))
        let waist = { (p: SIMD2<Double>) in rotated(p + SIMD2(-1.9, 0), about: SIMD2(-1.9, 0), cos: bc, sin: bs) }
        // Walking, the head bobs with each step: a nod forward and a slight swing to the side of the tripod pushing.
        let walking = min(1, v / 20), sway = sin(gait) * 0.14 * walking
        let headTurn = -cu * 0.7 + sway, (nc, ns) = (cos(headTurn), sin(headTurn))
        let neckAt = SIMD2(3.0 + r, 0.0), neck = { (p: SIMD2<Double>) in rotated(p, about: neckAt, cos: nc, sin: ns) }
        // Let go of after talking, it nods: the head dips back once.
        let nod = t - nodAt < 0.5 ? sin((t - nodAt) / 0.5 * .pi) * 1.4 : 0
        let lift = 1 + 0.18 * r, hx = 5.1 + 1.6 * r + tap * 0.4 * sin(t * 30) + abs(cos(gait)) * 0.35 * walking - nod
        let fills = [oval(-4.7, 0, 4.2, 2.6 * (1 + 0.03 * sin(t * 2 + phase)), waist), oval(0, 0, 0.8, 0.7, waist),
                     oval(0.8 + r, 0, 2.2 * lift, 1.4 * lift, { $0 }), oval(hx, 0, 2.3 * lift, 2.2 * lift, neck)]
        // Antennae, elbowed: up or drooped, drumming, the big wave; curled up, folded back and shorter.
        for side in [-1.0, 1.0] {
            let base = 0.7 + cu * 0.6 - antennae.x * 0.35 + tap * 0.25 * sin(t * 28 + side * 1.7) + wave * 0.6 * sin(t * 7 + side)
            let sc = 4.2 * (1 - 0.35 * cu), fu = 5.2 * (1 - 0.45 * cu)
            let root = SIMD2(hx + 1.6, side * 1.0), elbow = SIMD2(hx + 1.6 + cos(base) * sc, side * (1.0 + sin(base) * sc))
            let tip = base - 0.9 - antennae.x * 0.2 + cu * 1.6
            let end = elbow + SIMD2(cos(tip) * fu, side * sin(tip) * fu)
            strokes.append(([world(neck(root)), world(neck(elbow)), world(neck(end))], 0.7 * s))
        }
        // Mandibles: a short pair of hooks at the front of the head, curving in, with a gap between their tips.
        for side in [-1.0, 1.0] {
            strokes.append(([world(neck(SIMD2(hx + 1.8 * lift, side * 1.0))), world(neck(SIMD2(hx + 2.8 * lift, side * 1.15))),
                             world(neck(SIMD2(hx + 3.4 * lift, side * 0.6)))], 0.5 * s))
        }
        return (size.x, AntShape(id: id, fills: fills, strokes: strokes, centre: SIMD2(x, y), planted: feet.map { $0.s < 1 ? nil : $0.at }))
    }
}

private func wrap(_ a: Double) -> Double { atan2(sin(a), cos(a)) }

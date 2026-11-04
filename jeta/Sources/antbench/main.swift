import JetaKit
import Foundation
import simd

// Replays 200 seeded runs of the colony on jeta at 60 fps, 2 minutes each: up to six sessions start and end, change
// mood every few seconds and send hook events now and then. Prints, as JSON arrays: frames where a planted foot
// slides, per 1,000 runs; frames where an ant jumps (moves over 8 pt in one frame), per 1,000 runs; pt an ant walks
// in a minute while its session is idle, and while it's busy with no new events (it moves in place), with how far a
// busy one gets from its spot (which creeps) in its last two minutes; the longest an ant stays within
// 1 pt of one spot, in s (burn-in); µs of CPU per frame for the whole colony, for each 50 runs; and, from 20 runs of
// four mostly idle sessions for 10 minutes (an event every 5 to 20 s, now and then one that needs you), the % of frames
// where two ants touch (centres under 26 pt apart) and the farthest an ant gets from where it first stood, in pt (p90),
// not counting while it needs you or for 10 s after (it comes forward, then walks back).
struct Seeded: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
var rng = Seeded(11)
let moods: [Mood] = [.idle, .busy, .attention, .proud, .dizzy, .sleep, .bored, .focused]

var slides = 0, jumps = 0, ns: UInt64 = 0, frames = 0, batches: [Double] = []
let runs = 200
for run in 0..<runs {
    if run % 50 == 0 && frames > 0 { batches.append(Double(ns) / Double(frames) / 1000); ns = 0; frames = 0 }
    let colony = Colony(seed: UInt64(run), now: 0)
    var sessions: [(id: String, mood: Mood, front: Bool, events: Int?)] = [], n = 0, next = 0.0
    var last: [String: AntShape] = [:]
    for frame in 0..<(60 * 120) {
        let t = Double(frame) / 60
        if t >= next {
            next = t + Double.random(in: 2...6, using: &rng)
            let roll = Double.random(in: 0...1, using: &rng)
            if sessions.count < 2 || (roll < 0.2 && sessions.count < 6) {
                n += 1; sessions.append(("s\(n)", .busy, false, 0))
            } else if roll < 0.3 {
                sessions.remove(at: Int.random(in: 0..<sessions.count, using: &rng))
            } else {
                let i = Int.random(in: 0..<sessions.count, using: &rng)
                sessions[i].mood = moods.randomElement(using: &rng)!
                if Bool.random(using: &rng) { sessions[i].events! += 1 }
            }
            let needing = sessions.firstIndex { $0.mood == .attention }
            for i in sessions.indices { sessions[i].front = i == needing }
            colony.update(sessions, at: t)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let shapes = colony.shapes(at: t)
        ns += DispatchTime.now().uptimeNanoseconds - start; frames += 1
        for s in shapes {
            if let b = last[s.id] {
                if simd_length(s.centre - b.centre) > 8 { jumps += 1 }
                for (p, q) in zip(b.planted, s.planted) {
                    if let p, let q, simd_length(p - q) > 1e-6 { slides += 1; break }
                }
            }
        }
        last = Dictionary(uniqueKeysWithValues: shapes.map { ($0.id, $0) })
    }
}
batches.append(Double(ns) / Double(frames) / 1000)

// Calm and burn-in: one session left alone for 3 minutes, as idle or busy with no new events. An idle ant should
// barely move; a busy one moves in place, never stopping and never leaving its spot.
var walked: [Double] = [], busyWalked: [Double] = [], busyStray: [Double] = [], stuck: [Double] = []
for run in 0..<40 {
    let colony = Colony(seed: UInt64(1000 + run), now: 0)
    colony.update([("a", run % 2 == 0 ? .idle : .busy, false, 3)], at: 0)
    var prev: SIMD2<Double>?, dist = 0.0, spot = SIMD2<Double>(0, 0), since = 0.0, longest = 0.0, stray = 0.0
    for frame in 0..<(60 * 180) {
        let t = Double(frame) / 60
        guard let c = colony.shapes(at: t).first?.centre else { continue }
        if t >= 120, let p = prev { dist += simd_length(c - p) }
        if t >= 60 {
            if let o = colony.spot(of: "a") { stray = max(stray, simd_length(c - o)) }
            if simd_length(c - spot) > 1 { spot = c; since = t }
            longest = max(longest, t - since)
        }
        prev = c
    }
    if run % 2 == 0 { walked.append(dist) } else { busyWalked.append(dist); busyStray.append(stray) }
    stuck.append(longest)
}

// Apart and in place: four sessions, mostly idle.
var frames4 = 0, touching = 0, strays: [Double] = []
for seed in 0..<20 {
    var r = Seeded(UInt64(500 + seed))
    let colony = Colony(seed: UInt64(500 + seed), now: 0)
    colony.screen = SIMD2(568, 320) // the pad runs landscape
    var s: [(id: String, mood: Mood, front: Bool, events: Int?)] = (0..<4).map { ("s\($0)", .idle, false, 0) }
    colony.update(s, at: 0)
    var start: [String: SIMD2<Double>] = [:], far: [String: Double] = [:], next = 5.0, needed: [String: Double] = [:]
    for frame in 0..<(60 * 600) {
        let t = Double(frame) / 60
        if t >= next {
            next = t + Double.random(in: 5...20, using: &r)
            let i = Int.random(in: 0..<4, using: &r), roll = Double.random(in: 0...1, using: &r)
            if roll < 0.15 { s[i].mood = s[i].mood == .attention ? .idle : .attention } else { s[i].mood = roll < 0.6 ? .busy : .idle; s[i].events! += 1 }
            for k in s.indices where s[k].mood == .attention { needed[s[k].id] = t + 1e9 }
            for k in s.indices where s[k].mood != .attention && (needed[s[k].id] ?? 0) > t { needed[s[k].id] = t + 10 }
            let needing = s.firstIndex { $0.mood == .attention }
            for k in s.indices { s[k].front = k == needing }
            colony.update(s, at: t)
        }
        let shapes = colony.shapes(at: t)
        guard t >= 2 else { continue }
        frames4 += 1
        for a in shapes where (needed[a.id] ?? 0) < t {
            let o = start[a.id] ?? a.centre; start[a.id] = o; far[a.id] = max(far[a.id] ?? 0, simd_length(a.centre - o))
        }
        if shapes.indices.contains(where: { i in shapes.indices.contains { j in j > i && simd_length(shapes[i].centre - shapes[j].centre) < 26 } }) { touching += 1 }
    }
    strays += far.values
}
strays.sort()

// Burn-in, on the SE's 568×320 screen: one session left an hour, busy and resting, sampled twice a second; the share
// of the time the most-covered 1 pt cell spends under the ant's body.
func inside(_ p: SIMD2<Double>, _ poly: [SIMD2<Double>]) -> Bool {
    var c = false, j = poly.count - 1
    for i in poly.indices {
        let a = poly[i], b = poly[j]
        if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
        j = i
    }
    return c
}
var hottest: [Mood: [Double]] = [:]
for mood in [Mood.busy, .idle] {
    for seed in 0..<4 {
        let colony = Colony(seed: UInt64(2000 + seed), now: 0)
        colony.screen = SIMD2(568, 320)
        colony.update([("a", mood, false, 0)], at: 0)
        var heat = [Int](repeating: 0, count: 568 * 320), n = 0
        for k in 0..<(3600 * 2) {
            guard let s = colony.shapes(at: 10 + Double(k) / 2).first, !s.fills.isEmpty else { continue }
            n += 1
            let xs = s.fills.flatMap { $0.map(\.x) }, ys = s.fills.flatMap { $0.map(\.y) }
            for y in max(0, Int(ys.min()!))...min(319, Int(ys.max()!)) {
                for x in max(0, Int(xs.min()!))...min(567, Int(xs.max()!)) where s.fills.contains(where: { inside(SIMD2(Double(x) + 0.5, Double(y) + 0.5), $0) }) {
                    heat[y * 568 + x] += 1
                }
            }
        }
        hottest[mood, default: []].append(100 * Double(heat.max()!) / Double(max(1, n)))
    }
}

func json(_ v: [Double]) -> String { "[" + v.map { String(format: "%.3f", $0) }.joined(separator: ",") + "]" }
print(json([Double(slides) * 1000 / Double(runs)]))
print(json([Double(jumps) * 1000 / Double(runs)]))
print(json(walked))
print(json(stuck))
print(json(batches))
print(json([100 * Double(touching) / Double(frames4)]))
print(json([strays[strays.count * 9 / 10]]))
print(json(busyWalked))
print(json(busyStray))
print(json(hottest[.busy]!))
print(json(hottest[.idle]!))

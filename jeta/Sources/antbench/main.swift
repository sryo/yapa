import JetaKit
import Foundation
import simd

// Replays 200 seeded runs of the colony on jeta at 60 fps, 2 minutes each: up to six sessions start and end, change
// mood every few seconds and send hook events now and then. Prints, as JSON arrays: frames where a planted foot
// slides, per 1,000 runs; frames where an ant jumps (moves over 8 pt in one frame), per 1,000 runs; pt an ant walks
// in a minute while its session does nothing (idle, or busy with no new events); the longest an ant stays within
// 1 pt of one spot, in s (burn-in); and µs of CPU per frame for the whole colony, for each 50 runs.
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

// Calm and burn-in: one session left alone for 3 minutes, as idle or busy with no new events.
var walked: [Double] = [], stuck: [Double] = []
for run in 0..<40 {
    let colony = Colony(seed: UInt64(1000 + run), now: 0)
    colony.update([("a", run % 2 == 0 ? .idle : .busy, false, 3)], at: 0)
    var prev: SIMD2<Double>?, dist = 0.0, spot = SIMD2<Double>(0, 0), since = 0.0, longest = 0.0
    for frame in 0..<(60 * 180) {
        let t = Double(frame) / 60
        guard let c = colony.shapes(at: t).first?.centre else { continue }
        if t >= 120, let p = prev { dist += simd_length(c - p) }
        if t >= 60 {
            if simd_length(c - spot) > 1 { spot = c; since = t }
            longest = max(longest, t - since)
        }
        prev = c
    }
    walked.append(dist); stuck.append(longest)
}

func json(_ v: [Double]) -> String { "[" + v.map { String(format: "%.3f", $0) }.joined(separator: ",") + "]" }
print(json([Double(slides) * 1000 / Double(runs)]))
print(json([Double(jumps) * 1000 / Double(runs)]))
print(json(walked))
print(json(stuck))
print(json(batches))

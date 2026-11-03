import JetaKit
import Foundation
import simd

// Replays 200 seeded minutes of sessions on jeta at 60 fps: sessions start and end, start working and reading, need
// you, finish and fail, every 1.5 s or so, and you tap one forward or swipe one away now and then. Prints, as JSON
// arrays: frames where two faces overlap, per 1,000 runs; frames where a face jumps (its place moves over 0.05 of the
// short side, about 16 pt on the SE, or it appears or vanishes while big enough to see), per 1,000 runs; ms from a
// session's event to its face starting to react (p50); and µs of CPU per frame for the whole crowd, for each 50 runs.
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
var rng = Seeded(9)
let states: [SessionState] = [.needs, .working(reading: true), .working(reading: false), .failed, .quiet]

func box(_ c: Crowd, _ s: Slot, at t: Double) -> (SIMD2<Double>, SIMD2<Double>) {
    let pts = c.face(s.id)!.frame(at: t).eyes.flatMap { $0.outline() }.map { s.centre + $0 * s.scale }
    return (pts.reduce(pts[0]) { simd_min($0, $1) }, pts.reduce(pts[0]) { simd_max($0, $1) })
}
func eyes(_ c: Crowd, _ s: Slot, at t: Double) -> [SIMD2<Double>] {
    c.face(s.id)!.frame(at: t).eyes.flatMap { [$0.p0, $0.c, $0.p1] }.map { s.centre + $0 * s.scale }
}

var overlaps = 0, jumps = 0, reacts: [Double] = [], ns: UInt64 = 0, frames = 0, batches: [Double] = []
let runs = 200
for run in 0..<runs {
    if run % 50 == 0 && frames > 0 { batches.append(Double(ns) / Double(frames) / 1000); ns = 0; frames = 0 }
    let crowd = Crowd(seed: UInt64(run), now: 0)
    var ids: [String] = [], state: [String: SessionState] = [:], events: [String: Int] = [:], n = 0
    var last: [String: Slot] = [:], next = 0.5
    var waiting: [(id: String, at: Double, from: [SIMD2<Double>])] = []
    for frame in 0..<(60 * 60) {
        let t = Double(frame) / 60
        if t >= next {
            next = t + Double.random(in: 0.8...2.2, using: &rng)
            let roll = Double.random(in: 0...1, using: &rng)
            var changed: String?
            if roll < 0.25 || ids.count < 2 {
                n += 1; let id = "s\(n)"; ids.append(id); state[id] = .working(reading: false); changed = id
            } else if roll < 0.35, ids.count > 2 {
                let id = ids.remove(at: Int.random(in: 0..<ids.count, using: &rng)); state[id] = nil
            } else if roll < 0.42, let id = ids.randomElement(using: &rng) {
                crowd.focus(id, at: t)
            } else if roll < 0.47, let id = ids.randomElement(using: &rng) {
                crowd.hide(id, at: t)
            } else if let id = ids.randomElement(using: &rng) {
                var s = states.randomElement(using: &rng)!
                if s == .quiet, Bool.random(using: &rng) { s = .finished(at: t) }
                state[id] = s; changed = id
            }
            if let id = changed { events[id, default: 0] += 1 }
            let before = Dictionary(uniqueKeysWithValues: crowd.slots(at: t).map { ($0.id, $0) })
            crowd.update(ids.map { SessionInfo(id: $0, name: $0, state: state[$0]!, events: events[$0, default: 0]) }, at: t)
            if let id = changed, let s = before[id] { waiting.append((id, t, eyes(crowd, s, at: t))) }
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let slots = crowd.slots(at: t), boxes = slots.map { box(crowd, $0, at: t) }
        ns += DispatchTime.now().uptimeNanoseconds - start; frames += 1
        if boxes.indices.contains(where: { i in boxes.indices.contains { j in
            j > i && boxes[i].0.x < boxes[j].1.x && boxes[j].0.x < boxes[i].1.x && boxes[i].0.y < boxes[j].1.y && boxes[j].0.y < boxes[i].1.y } }) {
            overlaps += 1
        }
        let now = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0) })
        let jumped = slots.contains { s in last[s.id].map { simd_length(s.centre - $0.centre) > 0.05 } ?? (s.scale > 0.05) }
            || last.values.contains { now[$0.id] == nil && $0.scale > 0.05 }
        if jumped { jumps += 1 }
        last = now
        waiting = waiting.filter { w in
            guard let s = now[w.id] else { return false }
            let moved = zip(eyes(crowd, s, at: t), w.from).map { simd_length($0 - $1) }.max() ?? 0
            if moved > 0.01 { reacts.append((t - w.at) * 1000); return false }
            return t - w.at < 3
        }
    }
}
batches.append(Double(ns) / Double(frames) / 1000)
reacts.sort()
print([Double(overlaps) * 1000 / Double(runs)])
print([Double(jumps) * 1000 / Double(runs)])
print([reacts.isEmpty ? 0 : reacts[reacts.count / 2]])
print(batches.map { (($0 * 1000).rounded()) / 1000 })

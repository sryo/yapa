import JetaKit
import Foundation

// Replays 1,000 seeded touch gestures, each with what the hand meant, through Chord at 60 fps. Prints, as JSON
// arrays: misreads per 1,000 (wrong finger count or control, a decision sent or lost, scrubbing to the wrong line);
// decisions sent that weren't meant, per 1,000; ms from the last finger down to the chord locking; µs per update.
var rng = SystemRandomNumberGenerator.Seeded(1)
typealias P = SIMD2<Double>

struct Gesture {
    var prompt: Bool, fingers: Int, gap: Double, stagger: [Double], path: (Double) -> Double, seconds: Double
    var want: (control: Chord.Control?, fingers: Int, decision: Chord.Decision?, scrub: Int)?
}

func gesture(_ k: Int) -> Gesture {
    let j = { (a: Double, b: Double) in Double.random(in: a...b, using: &rng) }
    // Fingers land up to 120 ms apart; a guess at a hand that isn't trying, until there are recorded touches.
    let stagger = (0..<4).map { _ in j(0, 0.12) }
    let close = j(22, 55), wide = j(140, 200)
    // Drag by `dy` over 0.25 s after a 0.15 s rest, then hold 0.1 s.
    let drag = { (dy: Double) in { (t: Double) in dy * min(1, max(0, (t - 0.15) / 0.25)) } }
    switch k % 8 {
    case 0: let dy = -j(125, 200); return Gesture(prompt: true, fingers: 2, gap: close, stagger: stagger, path: drag(dy), seconds: 0.5, want: (.decide, 2, .once, 0))
    case 1: let dy = j(125, 200); return Gesture(prompt: true, fingers: 2, gap: close, stagger: stagger, path: drag(dy), seconds: 0.5, want: (.decide, 2, .deny, 0))
    case 2: let dy = j(-90, 90); return Gesture(prompt: true, fingers: 2, gap: close, stagger: stagger, path: drag(dy), seconds: 0.5, want: (.decide, 2, nil, 0))
    case 3:
        let up = -j(130, 180), back = j(-60, 0)
        let path = { (t: Double) in t < 0.4 ? up * min(1, max(0, (t - 0.15) / 0.25)) : up + (back - up) * min(1, (t - 0.4) / 0.2) }
        return Gesture(prompt: true, fingers: 2, gap: close, stagger: stagger, path: path, seconds: 0.7, want: (.decide, 2, nil, 0))
    case 4:
        let n = Int.random(in: -3...3, using: &rng), dy = -(Double(n) * 40 + (n < 0 ? -1 : 1) * j(8, 30))
        return Gesture(prompt: false, fingers: 2, gap: close, stagger: stagger, path: drag(dy), seconds: 0.5, want: (.scrub, 2, nil, n))
    case 5: let dy = -j(130, 200); return Gesture(prompt: true, fingers: 3, gap: close, stagger: stagger, path: drag(dy), seconds: 0.5, want: (nil, 3, nil, 0))
    case 6: let dy = -j(130, 300); return Gesture(prompt: true, fingers: 1, gap: 0, stagger: stagger, path: drag(dy), seconds: 0.5, want: nil)
    default: let dy = -j(130, 200); return Gesture(prompt: true, fingers: 2, gap: wide, stagger: stagger, path: drag(dy), seconds: 0.5, want: (.spread, 2, nil, 0))
    }
}

var misreads = 0, misfires = 0, updates = 0, ns: UInt64 = 0, lockMs: [Double] = []
for k in 0..<1000 {
    let g = gesture(k)
    var chord = Chord(); chord.prompt = g.prompt
    var events: [Chord.Event] = []
    var landAt = 0.0
    let lands = (0..<g.fingers).map { i in i == 0 ? 0 : { landAt += g.stagger[i]; return landAt }() }
    let noise = (0..<g.fingers).map { _ in P(Double.random(in: -3...3, using: &rng), Double.random(in: -3...3, using: &rng)) }
    for t in stride(from: 0, through: g.seconds + lands.last!, by: 1.0 / 60) + [g.seconds + lands.last! + 1.0 / 60] {
        var f: [Int: P] = [:]
        if t <= g.seconds + lands.last! {
            for i in 0..<g.fingers where t >= lands[i] {
                let x = 160 + (Double(i) - Double(g.fingers - 1) / 2) * g.gap
                f[i] = P(x, 300 + g.path(t - lands.last!)) + noise[i]
            }
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let got = chord.update(f, at: t)
        if got.contains(where: { if case .began = $0 { true } else { false } }) { lockMs.append((t - lands.last!) * 1000) }
        events += got
        ns += DispatchTime.now().uptimeNanoseconds - start
        updates += 1
    }
    var began: (Chord.Control?, Int)?, decision: Chord.Decision?, scrub = 0
    for e in events {
        switch e {
        case .began(let c, let n): began = (c, n)
        case .decided(let d): decision = d
        case .step(.scrub, let n): scrub += n
        default: break
        }
    }
    let right: Bool
    if let w = g.want {
        right = began.map { $0.0 == w.control && $0.1 == w.fingers } == true && decision == w.decision && scrub == w.scrub
    } else {
        right = began == nil && decision == nil
    }
    if !right { misreads += 1 }
    if decision != nil && decision != g.want?.decision { misfires += 1 }
}
print("[\(misreads)]")
print("[\(misfires)]")
print("[\(String(format: "%.1f", lockMs.reduce(0, +) / Double(lockMs.count)))]")
print("[\(String(format: "%.3f", Double(ns) / Double(updates) / 1000))]")

extension SystemRandomNumberGenerator {
    /// A seeded generator (splitmix64), so every run replays the same gestures.
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
}

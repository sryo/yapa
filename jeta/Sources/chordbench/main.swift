import JetaKit
import Foundation

// Replays 1,000 seeded two-finger twists, each with what the hand meant, through Chord's dial at 60 fps. Prints, as JSON
// arrays: misreads per 1,000 (wrong finger count, steps turned or release); releases that weren't meant (the dial
// acting for a touch that shouldn't), per 1,000; ms from the last finger down to the chord locking; µs per update.
var rng = SystemRandomNumberGenerator.Seeded(1)
typealias P = SIMD2<Double>

struct Gesture {
    var fingers: Int, gap: Double, stagger: [Double], twist: (Double) -> Double, seconds: Double
    /// Fingers it should lock as and steps it should turn; nil for a touch that should do nothing at all.
    var want: (fingers: Int, steps: Int)?
}

func gesture(_ k: Int) -> Gesture {
    let j = { (a: Double, b: Double) in Double.random(in: a...b, using: &rng) }
    // Fingers land up to 120 ms apart; a guess at a hand that isn't trying, until there are recorded touches.
    let stagger = (0..<4).map { _ in j(0, 0.12) }
    let gap = j(30, 70), deg = Double.pi / 180
    // Twist by `a` radians over 0.25 s after a 0.15 s rest, then hold 0.1 s.
    let turn = { (a: Double) in { (t: Double) in a * min(1, max(0, (t - 0.15) / 0.25)) } }
    // A whole number of 22.5° steps and a part of one more, either way.
    let steps = { () -> (Int, Double) in
        let n = Int.random(in: -4...4, using: &rng)
        return (n, (Double(n) * 22.5 + (n < 0 ? -1 : 1) * j(4, 16)) * deg)
    }
    switch k % 5 {
    case 0, 1: let (n, a) = steps(); return Gesture(fingers: 2, gap: gap, stagger: stagger, twist: turn(a), seconds: 0.5, want: (2, n))
    case 2:
        let (n, a) = steps(), over = (n >= 0 ? 1.0 : -1.0) * j(25, 40) * deg
        let path = { (t: Double) in t < 0.4 ? (a + over) * min(1, max(0, (t - 0.15) / 0.25)) : a + over * (1 - min(1, (t - 0.4) / 0.2)) }
        return Gesture(fingers: 2, gap: gap, stagger: stagger, twist: path, seconds: 0.7, want: (2, n))
    case 3: return Gesture(fingers: 3, gap: gap, stagger: stagger, twist: turn(j(50, 90) * deg), seconds: 0.5, want: (3, 0))
    default: return Gesture(fingers: 1, gap: 0, stagger: stagger, twist: turn(j(50, 300) * deg), seconds: 0.5, want: nil)
    }
}

var misreads = 0, misfires = 0, updates = 0, ns: UInt64 = 0, lockMs: [Double] = [], batches: [Double] = []
for k in 0..<1000 {
    if k % 100 == 0 && updates > 0 { batches.append(Double(ns) / Double(updates) / 1000); ns = 0; updates = 0 }
    let g = gesture(k)
    var chord = Chord()
    var events: [Chord.Event] = []
    var landAt = 0.0
    let lands = (0..<g.fingers).map { i in i == 0 ? 0 : { landAt += g.stagger[i]; return landAt }() }
    let noise = (0..<g.fingers).map { _ in P(Double.random(in: -3...3, using: &rng), Double.random(in: -3...3, using: &rng)) }
    for t in stride(from: 0, through: g.seconds + lands.last!, by: 1.0 / 60) + [g.seconds + lands.last! + 1.0 / 60] {
        var f: [Int: P] = [:]
        if t <= g.seconds + lands.last! {
            // The fingers sit along a line through (160, 300), turned by the twist; one finger alone goes round it.
            let a = g.twist(t - lands.last!)
            for i in 0..<g.fingers where t >= lands[i] {
                let r = g.fingers == 1 ? 60 : (Double(i) - Double(g.fingers - 1) / 2) * g.gap
                // Where each finger sits off the line turns with the hand, as a twisting hand holds its shape.
                let off = P(noise[i].x * cos(a) - noise[i].y * sin(a), noise[i].x * sin(a) + noise[i].y * cos(a))
                f[i] = P(160, 300) + P(cos(a), sin(a)) * r + off
            }
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let got = chord.update(f, at: t)
        if got.contains(where: { if case .began = $0 { true } else { false } }) { lockMs.append((t - lands.last!) * 1000) }
        events += got
        ns += DispatchTime.now().uptimeNanoseconds - start
        updates += 1
    }
    var began: Int?, released = false, turned = 0
    for e in events {
        switch e {
        case .began(let n): began = n
        case .released: released = true
        case .step(let n): turned += n
        default: break
        }
    }
    let right = g.want.map { w in began == w.fingers && turned == w.steps && released == (w.fingers == 2) } ?? (began == nil && !released)
    if !right { misreads += 1 }
    if released && g.want?.fingers != 2 { misfires += 1 }
}
print("[\(misreads)]")
print("[\(misfires)]")
print("[\(String(format: "%.1f", lockMs.reduce(0, +) / Double(lockMs.count)))]")
batches.append(Double(ns) / Double(updates) / 1000)
print("[" + batches.map { String(format: "%.3f", $0) }.joined(separator: ", ") + "]")

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

import Foundation

/// One eye: a white stroke with round caps, in fractions of the screen's short side. It runs from (-ax, -ay) to
/// (ax, ay) around its centre and bows up by `bend` (down when negative). With ax and ay at 0 it is a dot `width`
/// across; with only ay it is a tall pill; with only ax and a bend it is an arc. Round caps mean nothing is ever cut off.
public struct EyePose: Equatable {
    public var ax = 0.0, ay = 0.065, bend = 0.0, width = 0.06, y = 0.0

    var fields: [Double] { [ax, ay, bend, width, y] }
    init(fields f: [Double]) { (ax, ay, bend, width, y) = (f[0], f[1], f[2], f[3], f[4]) }
    init(ax: Double = 0, ay: Double = 0.065, bend: Double = 0, width: Double = 0.06, y: Double = 0) {
        (self.ax, self.ay, self.bend, self.width, self.y) = (ax, ay, bend, width, y)
    }
}

/// Both eyes, and how much the gaze circles (dizzy).
public struct Pose: Equatable {
    public var left: EyePose, right: EyePose, spin = 0.0

    init(_ eye: EyePose, spin: Double = 0) { (left, right, self.spin) = (eye, eye, spin) }
    init(left: EyePose, right: EyePose) { (self.left, self.right) = (left, right) }

    var fields: [Double] { left.fields + right.fields + [spin] }
    init(fields f: [Double]) { left = EyePose(fields: Array(f[0..<5])); right = EyePose(fields: Array(f[5..<10])); spin = f[10] }
    public func distance(to o: Pose) -> Double { zip(fields, o.fields).reduce(0) { $0 + abs($1.0 - $1.1) } }
}

/// The seven Hardware Buddy states, then yapa's own.
public enum Mood: String, CaseIterable {
    case sleep, idle, busy, attention, celebrate, dizzy, heart
    case curious, focused, impatient, proud, bored

    public var pose: Pose {
        switch self {
        case .sleep: Pose(EyePose(ax: 0.05, ay: 0, bend: -0.013, width: 0.02, y: 0.02))
        case .idle: Pose(EyePose())
        case .busy: Pose(EyePose(ay: 0.04, y: 0.012))
        case .attention: Pose(EyePose(ay: 0.066, width: 0.085, y: -0.006))
        case .celebrate: Pose(EyePose(ax: 0.045, ay: 0, bend: 0.03, width: 0.045, y: -0.01))
        case .dizzy: Pose(EyePose(ay: 0.045), spin: 0.6)
        case .heart: Pose(EyePose(ax: 0.05, ay: 0, bend: 0.036, width: 0.05, y: -0.015))
        case .curious: Pose(left: EyePose(ay: 0.066, width: 0.08, y: -0.006), right: EyePose(ay: 0.032, width: 0.07, y: 0.01))
        case .focused: Pose(EyePose(ax: 0.022, ay: 0, width: 0.06))
        case .impatient: Pose(EyePose(ay: 0.06, width: 0.08, y: -0.022))
        case .proud: Pose(EyePose(ax: 0.035, ay: 0, bend: 0.018, width: 0.05, y: -0.006))
        case .bored: Pose(EyePose(ax: 0.03, ay: 0, bend: -0.004, width: 0.055, y: 0.02))
        }
    }
}

/// A quadratic stroke from p0 through control c to p1, `width` thick with round caps, around the screen centre.
public struct Stroke { public var p0, c, p1: SIMD2<Double>; public var width: Double }

public struct Frame {
    public var eyes: [Stroke]
    /// 0 open, 1 shut.
    public var blink: Double
    public var gazeTarget: SIMD2<Double>
}

/// A damped spring: what keeps every change fluid.
struct Spring {
    var x: Double, v = 0.0
    mutating func step(to target: Double, k: Double, damping d: Double, dt: Double) {
        v += ((target - x) * k - 2 * d * k.squareRoot() * v) * dt
        x += v * dt
    }
}

/// The face's motion. Every value is a spring chasing a target, integrated in small steps, so nothing jumps.
public final class Face {
    static let step = 1.0 / 240

    private var rng: SplitMix
    private let lively: Bool
    private(set) public var mood = Mood.idle
    private var pose: [Spring] = Mood.idle.pose.fields.map { Spring(x: $0) }
    private var gaze = [Spring(x: 0), Spring(x: 0)], blink = Spring(x: 0), sleepy = Spring(x: 0)
    private var now: Double, blinkAt = -1.0, nextBlink: Double, nextDart: Double
    private var gazeTo = SIMD2<Double>(0, 0)

    public init(seed: UInt64, now: Double, lively: Bool = true) {
        rng = SplitMix(seed); self.lively = lively; self.now = now
        nextBlink = now + rng.next(in: 3...10); nextDart = now + rng.next(in: 1...2.25)
    }

    public func set(_ m: Mood, at t: Double) { advance(to: t); mood = m }

    public func isActive(at t: Double) -> Bool { mood != .sleep }

    func pose(at t: Double) -> Pose { advance(to: t); return Pose(fields: pose.map(\.x)) }

    public func frame(at t: Double) -> Frame {
        let p = pose(at: t), b = max(0, min(1, blink.x)), s = sleepy.x
        let breath = sin(t * 1.1) * (0.002 + 0.004 * s)
        let spin = p.spin * SIMD2(cos(2 * .pi * 1.5 * t), sin(2 * .pi * 1.5 * t))
        let look = SIMD2(gaze[0].x * 0.05, gaze[1].x * 0.035) + spin * 0.04
        let eyes = [(p.left, -1.0), (p.right, 1.0)].map { e, side -> Stroke in
            // A blink flattens the eye into a short thin line; max() and min() keep it continuous. The eye only
            // widens once its height has nearly gone, so going between pill and arc it never leans diagonally.
            let ay = e.ay * (1 - b), ax = max(e.ax, 0.03 * b) * (1 - smoothstep(0, 0.012, ay))
            let w = (e.width - (e.width - min(e.width, 0.03)) * b) * (1 + 0.04 * s * sin(t * 1.1))
            let c = SIMD2(side * 0.08, e.y + breath) + look
            return Stroke(p0: c - SIMD2(ax, ay), c: c - SIMD2(0, 2 * e.bend), p1: c + SIMD2(ax, ay), width: w)
        }
        return Frame(eyes: eyes, blink: b, gazeTarget: gazeTo)
    }

    private func advance(to t: Double) {
        let target = mood.pose.fields
        while now < t {
            let dt = min(Face.step, t - now)
            now += dt
            if !lively || mood == .sleep {
                nextBlink = max(nextBlink, now + 3); nextDart = max(nextDart, now + 1)
                if mood == .sleep { gazeTo = .zero }
            } else {
                if now >= nextBlink { blinkAt = nextBlink; nextBlink += rng.next(in: 3...10) }
                if now >= nextDart { gazeTo = SIMD2(rng.next(in: -1...1), rng.next(in: -0.6...0.6)); nextDart += rng.next(in: 1...2.25) }
            }
            for i in pose.indices { pose[i].step(to: target[i], k: 180, damping: 1, dt: dt) }
            gaze[0].step(to: gazeTo.x, k: 160, damping: 0.75, dt: dt)
            gaze[1].step(to: gazeTo.y, k: 160, damping: 0.75, dt: dt)
            blink.step(to: now - blinkAt < 0.09 ? 1 : 0, k: 1400, damping: 0.9, dt: dt)
            sleepy.step(to: mood == .sleep ? 1 : 0, k: 20, damping: 1, dt: dt)
        }
    }
}

func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = max(0, min(1, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

struct SplitMix {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(in r: ClosedRange<Double>) -> Double {
        r.lowerBound + (r.upperBound - r.lowerBound) * Double(next() >> 11) / Double(1 << 53)
    }
}

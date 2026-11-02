import Foundation
import simd

/// One eye: a white stroke with round caps, in fractions of the screen's short side. It runs from (-ax, -ay) to
/// (ax, ay) around its centre and bows up by `bend` (down when negative). With ax and ay at 0 it is a dot `width`
/// across; with only ay it is a tall pill; with only ax and a bend it is an arc. Round caps mean nothing is ever cut off.
public struct EyePose: Equatable {
    public var ax = 0.0, ay = 0.035, bend = 0.0, width = 0.06, y = 0.0

    var fields: [Double] { [ax, ay, bend, width, y] }
    init(fields f: [Double]) { (ax, ay, bend, width, y) = (f[0], f[1], f[2], f[3], f[4]) }
    init(ax: Double = 0, ay: Double = 0.035, bend: Double = 0, width: Double = 0.06, y: Double = 0) {
        (self.ax, self.ay, self.bend, self.width, self.y) = (ax, ay, bend, width, y)
    }
}

/// Both eyes, how much the gaze circles (dizzy), and `depth`: how far the face steps toward you (+, it grows as if
/// nearer the camera) or back (-, when it doesn't want to be reached).
public struct Pose: Equatable {
    public var left: EyePose, right: EyePose, spin = 0.0, depth = 0.0

    init(_ eye: EyePose, spin: Double = 0, depth: Double = 0) { (left, right, self.spin, self.depth) = (eye, eye, spin, depth) }
    init(left: EyePose, right: EyePose, depth: Double = 0) { (self.left, self.right, self.depth) = (left, right, depth) }

    var fields: [Double] { left.fields + right.fields + [spin, depth] }
    init(fields f: [Double]) {
        left = EyePose(fields: Array(f[0..<5])); right = EyePose(fields: Array(f[5..<10])); spin = f[10]; depth = f[11]
    }
    public func distance(to o: Pose) -> Double { zip(fields, o.fields).reduce(0) { $0 + abs($1.0 - $1.1) } }
}

/// The seven Hardware Buddy states, then yapa's own.
public enum Mood: String, CaseIterable {
    case sleep, idle, busy, attention, celebrate, dizzy, heart
    case curious, focused, impatient, proud, bored

    public var pose: Pose {
        switch self {
        case .sleep: Pose(EyePose(ax: 0.05, ay: 0, bend: -0.013, width: 0.02, y: 0.02), depth: -0.1)
        case .idle: Pose(EyePose())
        case .busy: Pose(EyePose(ay: 0.022, y: 0.012), depth: -0.25)
        case .attention: Pose(EyePose(ay: 0.05, width: 0.07, y: -0.006), depth: 0.2)
        case .celebrate: Pose(EyePose(ax: 0.045, ay: 0, bend: 0.03, width: 0.045, y: -0.01))
        case .dizzy: Pose(EyePose(ay: 0.026), spin: 0.6)
        case .heart: Pose(EyePose(ax: 0.05, ay: 0, bend: 0.036, width: 0.05, y: -0.015))
        case .curious: Pose(left: EyePose(ay: 0.045, width: 0.08, y: -0.006), right: EyePose(ay: 0.018, width: 0.07, y: 0.01), depth: 0.4)
        case .focused: Pose(EyePose(ax: 0.022, ay: 0, width: 0.06), depth: -0.3)
        case .impatient: Pose(EyePose(ay: 0.04, width: 0.08, y: -0.022))
        case .proud: Pose(EyePose(ax: 0.035, ay: 0, bend: 0.018, width: 0.05, y: -0.006))
        case .bored: Pose(EyePose(ax: 0.03, ay: 0, bend: -0.004, width: 0.055, y: 0.02), depth: -0.1)
        }
    }
}

/// A quadratic stroke from p0 through control c to p1, `width` thick, around the screen centre.
public struct Stroke {
    public var p0, c, p1: SIMD2<Double>; public var width: Double

    /// The eye's filled outline: the curve extended by half the width at each end, with a half-width that falls
    /// off like an ellipse (`a·√(1-u²)` along the spine). A straight stroke comes out as an exact oval, a curved
    /// one as a bent oval tapering to soft points, and a stroke of zero length as a circle. Left side first, then
    /// the right side back, so point i and point count-1-i face each other across the spine.
    public func outline(samples n: Int = 41) -> [SIMD2<Double>] {
        let a = width / 2
        let d0 = 2 * (c - p0), d1 = 2 * (p1 - c)
        let still = simd_length(p1 - p0) < 1e-9 && simd_length(c - p0) < 1e-9
        func spine(_ u: Double) -> (SIMD2<Double>, SIMD2<Double>) {
            if still { return (p0 + SIMD2(0, u * a), SIMD2(0, 1)) }
            let e0 = a / max(simd_length(d0), 1e-9), e1 = a / max(simd_length(d1), 1e-9)
            let t = -e0 + (1 + e0 + e1) * (u + 1) / 2
            if t < 0 { return (p0 + d0 * t, d0) }
            if t > 1 { return (p1 + d1 * (t - 1), d1) }
            let m = 1 - t
            return (m * m * p0 + 2 * m * t * c + t * t * p1, 2 * m * (c - p0) + 2 * t * (p1 - c))
        }
        var left: [SIMD2<Double>] = [], right: [SIMD2<Double>] = []
        for i in 0..<n {
            // Bunch samples toward the ends, where the oval turns fastest, so the tips stay round.
            let u = -cos(.pi * Double(i) / Double(n - 1))
            let (p, d) = spine(u), len = max(simd_length(d), 1e-12)
            let normal = SIMD2(-d.y, d.x) / len, h = a * max(0, 1 - u * u).squareRoot()
            left.append(p + normal * h); right.append(p - normal * h)
        }
        return left + right.reversed()
    }
}

public struct Frame {
    public var eyes: [Stroke]
    /// 0 open, 1 shut.
    public var blink: Double
    public var gazeTarget: SIMD2<Double>
    /// The head's tilt in radians, and how much nearer (>1) or farther (<1) it stands.
    public var tilt: Double, scale: Double
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
/// Changes are exaggerated on purpose: shapes overshoot, a change squashes the eyes and makes them hop, and the
/// whole face wanders around the screen.
public final class Face {
    static let step = 1.0 / 240

    /// How far the middle of the face may wander from the screen's centre, in fractions of the short side.
    public var bounds = SIMD2<Double>(0.7, 0.35)

    private var rng: SplitMix
    private let lively: Bool
    private(set) public var mood = Mood.idle
    private var pose: [Spring] = Mood.idle.pose.fields.map { Spring(x: $0) }
    private var gaze = [Spring(x: 0), Spring(x: 0)], pos = [Spring(x: 0), Spring(x: 0)]
    private var blink = Spring(x: 0), sleepy = Spring(x: 0), squash = Spring(x: 0), hop = Spring(x: 0), tilt = Spring(x: 0)
    private var now: Double, blinkAt = -1.0, nextBlink: Double, nextDart: Double, nextMove: Double, nextTilt = 0.0, tiltSide = 1.0
    private var gazeTo = SIMD2<Double>(0, 0), posTo = SIMD2<Double>(0, 0)

    public init(seed: UInt64, now: Double, lively: Bool = true) {
        rng = SplitMix(seed); self.lively = lively; self.now = now
        nextBlink = now + rng.next(in: 3...10); nextDart = now + rng.next(in: 1...2.25); nextMove = now + rng.next(in: 2...5)
    }

    public func set(_ m: Mood, at t: Double) {
        advance(to: t)
        guard m != mood else { return }
        kick(by: mood.pose.distance(to: m.pose))
        if m == .curious { nextTilt = t + rng.next(in: 2.5...4) }
        mood = m
    }

    public func isActive(at t: Double) -> Bool { mood != .sleep }

    func pose(at t: Double) -> Pose { advance(to: t); return Pose(fields: pose.map(\.x)) }

    public func frame(at t: Double) -> Frame {
        let p = pose(at: t), b = max(0, min(1, blink.x)), s = sleepy.x, sq = max(-0.6, min(0.6, squash.x))
        let breath = sin(t * 1.1) * (0.002 + 0.004 * s)
        let spin = p.spin * SIMD2(cos(2 * .pi * 1.5 * t), sin(2 * .pi * 1.5 * t))
        // The eyes lead where the face is travelling.
        let look = SIMD2(gaze[0].x * 0.05, gaze[1].x * 0.035) + spin * 0.04 + SIMD2(pos[0].v, pos[1].v) * 0.03
        let centre = SIMD2(pos[0].x, pos[1].x + hop.x), scale = 1 + p.depth
        let (cs, sn) = (cos(tilt.x), sin(tilt.x))
        let place = { (v: SIMD2<Double>) in centre + SIMD2(v.x * cs - v.y * sn, v.x * sn + v.y * cs) * scale }
        let eyes = [(p.left, -1.0), (p.right, 1.0)].map { e, side -> Stroke in
            // A blink flattens the eye into a short thin line; max() and min() keep it continuous. The eye only
            // widens once its height has nearly gone, so going between pill and arc it never leans diagonally.
            // Squash shortens and widens it, stretch does the opposite.
            // Springs overshoot, so clamp lengths at zero before shaping.
            let ay = max(0, e.ay) * (1 - b) * (1 + sq)
            let ax = max(0, e.ax, 0.03 * b) * (1 - 0.5 * sq) * (1 - smoothstep(0, 0.012, ay))
            let w = max(0.01, e.width - (e.width - min(e.width, 0.03)) * b) * (1 + 0.04 * s * sin(t * 1.1))
            let c = SIMD2(side * 0.06 * (1 - 0.3 * sq), e.y + breath) + look
            let bow = SIMD2(0, 2 * e.bend * (1 + sq))
            return Stroke(p0: place(c - SIMD2(ax, ay)), c: place(c - bow), p1: place(c + SIMD2(ax, ay)), width: w * scale)
        }
        return Frame(eyes: eyes, blink: b, gazeTarget: gazeTo, tilt: tilt.x, scale: scale)
    }

    /// A change squashes the eyes and throws them up a little; the springs then stretch and settle.
    private func kick(by distance: Double) {
        squash.v -= min(8, 2.5 + 20 * distance)
        hop.v -= min(0.8, 0.3 + 2 * distance)
    }

    private func advance(to t: Double) {
        let target = mood.pose.fields
        while now < t {
            let dt = min(Face.step, t - now)
            now += dt
            if !lively || mood == .sleep {
                nextBlink = max(nextBlink, now + 3); nextDart = max(nextDart, now + 1); nextMove = max(nextMove, now + 2)
                if mood == .sleep { gazeTo = .zero; posTo = SIMD2(pos[0].x, pos[1].x) }
            } else {
                if now >= nextBlink { blinkAt = nextBlink; nextBlink += rng.next(in: 3...10) }
                if now >= nextDart { gazeTo = SIMD2(rng.next(in: -1...1), rng.next(in: -0.6...0.6)); nextDart += rng.next(in: 1...2.25) }
                if now >= nextMove {
                    posTo = SIMD2(rng.next(in: -bounds.x...bounds.x), rng.next(in: -bounds.y...bounds.y))
                    nextMove += rng.next(in: 2...5)
                    kick(by: 0.05)
                }
            }
            for i in pose.indices { pose[i].step(to: target[i], k: 220, damping: 0.45, dt: dt) }
            gaze[0].step(to: gazeTo.x, k: 200, damping: 0.5, dt: dt)
            gaze[1].step(to: gazeTo.y, k: 200, damping: 0.5, dt: dt)
            pos[0].step(to: posTo.x, k: 30, damping: 0.75, dt: dt)
            pos[1].step(to: posTo.y, k: 30, damping: 0.75, dt: dt)
            if mood == .curious && now >= nextTilt { tiltSide = -tiltSide; nextTilt = now + rng.next(in: 2.5...4) }
            tilt.step(to: mood == .curious ? 0.2 * tiltSide : 0, k: 60, damping: 0.5, dt: dt)
            blink.step(to: now - blinkAt < 0.09 ? 1 : 0, k: 1400, damping: 0.9, dt: dt)
            sleepy.step(to: mood == .sleep ? 1 : 0, k: 20, damping: 1, dt: dt)
            squash.step(to: 0, k: 260, damping: 0.35, dt: dt)
            hop.step(to: 0, k: 200, damping: 0.4, dt: dt)
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

import Foundation

/// One eye, in fractions of the screen's short side. The top lid covers `lidTop` of the height and tilts by
/// `slant` (positive lowers the side toward the nose: cross; negative droops the outer side: tired). The bottom lid
/// rises by `lidBottom` in the middle as an arc, which turns the eye into a happy ^.
public struct EyePose: Equatable {
    public var width = 0.30, height = 0.38, radius = 0.12
    public var lidTop = 0.0, lidBottom = 0.0, slant = 0.0, y = 0.0

    var fields: [Double] { [width, height, radius, lidTop, lidBottom, slant, y] }
    init(fields f: [Double]) { (width, height, radius, lidTop, lidBottom, slant, y) = (f[0], f[1], f[2], f[3], f[4], f[5], f[6]) }
    init(width: Double = 0.30, height: Double = 0.38, lidTop: Double = 0, lidBottom: Double = 0, slant: Double = 0, y: Double = 0) {
        (self.width, self.height, self.lidTop, self.lidBottom, self.slant, self.y) = (width, height, lidTop, lidBottom, slant, y)
    }
}

/// Both eyes, one warm colour (hue, saturation, brightness) and how much the gaze circles (dizzy).
public struct Pose: Equatable {
    public var left: EyePose, right: EyePose
    public var hue = 0.085, sat = 0.9, light = 1.0, spin = 0.0

    init(_ eye: EyePose, hue: Double = 0.085, sat: Double = 0.9, light: Double = 1, spin: Double = 0) {
        (left, right, self.hue, self.sat, self.light, self.spin) = (eye, eye, hue, sat, light, spin)
    }
    init(left: EyePose, right: EyePose) { (self.left, self.right) = (left, right) }

    var fields: [Double] { left.fields + right.fields + [hue, sat, light, spin] }
    init(fields f: [Double]) {
        left = EyePose(fields: Array(f[0..<7])); right = EyePose(fields: Array(f[7..<14]))
        (hue, sat, light, spin) = (f[14], f[15], f[16], f[17])
    }
    public func distance(to o: Pose) -> Double { zip(fields, o.fields).reduce(0) { $0 + abs($1.0 - $1.1) } }
}

/// The seven Hardware Buddy states, then yapa's own.
public enum Mood: String, CaseIterable {
    case sleep, idle, busy, attention, celebrate, dizzy, heart
    case curious, focused, impatient, proud, bored

    public var pose: Pose {
        switch self {
        case .sleep: Pose(EyePose(lidTop: 0.9, y: 0.03), light: 0.45)
        case .idle: Pose(EyePose())
        case .busy: Pose(EyePose(width: 0.32, lidTop: 0.3, lidBottom: 0.12), light: 0.95)
        case .attention: Pose(EyePose(width: 0.32, height: 0.44), hue: 0.06, sat: 1)
        case .celebrate: Pose(EyePose(lidBottom: 0.7, y: -0.03), hue: 0.11)
        case .dizzy: Pose(EyePose(lidTop: 0.12), spin: 0.05)
        case .heart: Pose(EyePose(lidBottom: 0.62, y: -0.03), hue: -0.02, sat: 0.65)
        case .curious: Pose(left: EyePose(height: 0.44), right: EyePose(height: 0.34, lidTop: 0.18))
        case .focused: Pose(EyePose(height: 0.34, lidTop: 0.32, slant: 0.3))
        case .impatient: Pose(EyePose(lidTop: 0.25, slant: 0.42), hue: 0.05, sat: 0.95)
        case .proud: Pose(EyePose(lidTop: 0.3, lidBottom: 0.4))
        case .bored: Pose(EyePose(lidTop: 0.45, slant: -0.45, y: 0.03), light: 0.7)
        }
    }
}

public struct Frame {
    public var pose: Pose
    /// The blink's scale on the eye: it thins to a sliver and widens.
    public var blinkHeight: Double, blinkWidth: Double
    public var gaze: SIMD2<Double>, gazeTarget: SIMD2<Double>
    /// Vertical scale while a glance darts (1 at rest).
    public var squash: Double
}

/// The face's motion: eased, retargetable expressions plus blinks and glances. All of it is a function of time.
public final class Face {
    static let blinkLength = 0.34, dart = 0.08

    private var rng: SplitMix
    private let lively: Bool
    private(set) public var mood = Mood.idle
    private var from = Mood.idle.pose, to = Mood.idle.pose, start = 0.0, duration = 0.0
    private var blinkAt = -1.0, nextBlink = 0.0
    private var gazeFrom = SIMD2<Double>(0, 0), gazeTo = SIMD2<Double>(0, 0), dartAt = -1.0, nextDart = 0.0

    public init(seed: UInt64, now: Double, lively: Bool = true) {
        rng = SplitMix(seed); self.lively = lively
        nextBlink = now + rng.next(in: 3...10); nextDart = now + rng.next(in: 1...2.25)
    }

    /// 120 ms for a small change, up to 300 ms for the largest.
    static func transitionDuration(from a: Pose, to b: Pose) -> Double { 0.12 + 0.18 * min(1, a.distance(to: b) / 2) }

    /// After nimoalr's blink: closed at 140 ms as a sliver 4% tall and 32% wider, open again by 340 ms.
    public static func blinkShape(at t: Double) -> (h: Double, w: Double) {
        if t < 0 || t >= blinkLength { return (1, 1) }
        if t <= 0.14 { let k = t / 0.14 * (t / 0.14); return (1 - 0.96 * k, 1 + 0.32 * k) }
        let u = (t - 0.14) / (blinkLength - 0.14), k = 1 - (1 - u) * (1 - u)
        return (0.04 + 0.96 * k, 1.32 - 0.32 * k)
    }

    public func set(_ m: Mood, at t: Double) {
        guard m != mood else { return }
        from = pose(at: t); to = m.pose; mood = m; start = t
        duration = Face.transitionDuration(from: from, to: to)
    }

    public func isActive(at t: Double) -> Bool { mood != .sleep || t < start + duration }

    public func frame(at t: Double) -> Frame {
        if !lively || mood == .sleep {
            nextBlink = max(nextBlink, t + 3); nextDart = max(nextDart, t + 1)
        } else {
            while t >= nextBlink { blinkAt = nextBlink; nextBlink += rng.next(in: 3...10) }
            while t >= nextDart {
                gazeFrom = gaze(at: nextDart); dartAt = nextDart
                gazeTo = SIMD2(rng.next(in: -0.3...0.3), rng.next(in: -0.15...0.15))
                nextDart += rng.next(in: 1...2.25)
            }
        }
        let p = pose(at: t), b = Face.blinkShape(at: t - blinkAt)
        let d = (t - dartAt) / Face.dart
        let squash = (0..<1).contains(d) ? 1 - 0.15 * sin(.pi * d) : 1
        var g = gaze(at: t)
        if p.spin > 0 { g += p.spin * SIMD2(cos(2 * .pi * 1.5 * t), sin(2 * .pi * 1.5 * t)) }
        return Frame(pose: p, blinkHeight: b.h, blinkWidth: b.w, gaze: g, gazeTarget: gazeTo, squash: squash)
    }

    /// The eye's outline around its centre: the top edge left to right, then the bottom edge right to left,
    /// so point i and point count-1-i share an x. `inner` is +1 when the nose is toward +x.
    public static func outline(_ e: EyePose, inner: Double, gaze: SIMD2<Double>,
                               blink: (h: Double, w: Double) = (1, 1), squash: Double = 1, samples: Int = 33) -> [SIMD2<Double>] {
        // Looking up enlarges the eyes, looking down shrinks them, and the eye on the side you look toward grows.
        var look = 1 + (gaze.y < 0 ? 0.06 : -0.08) * min(1, abs(gaze.y) / 0.15)
        if gaze.x * inner < 0 { look *= 1 + 0.045 * min(1, abs(gaze.x) / 0.3) }
        let w = e.width * blink.w, h = e.height * look * squash * blink.h
        let r = min(e.radius * min(blink.w, look * squash * blink.h), w / 2, h / 2)
        var top: [SIMD2<Double>] = [], bottom: [SIMD2<Double>] = []
        for i in 0..<samples {
            let x = -w / 2 * cos(.pi * Double(i) / Double(samples - 1))
            let dx = max(0, abs(x) - (w / 2 - r)), corner = r - max(0, r * r - dx * dx).squareRoot()
            let u = x / w
            let lid = -h / 2 + h * (min(0.98, e.lidTop) + e.slant * u * inner)
            let arc = h / 2 - h * e.lidBottom * pow(max(0, 1 - 4 * u * u), 0.6)
            let t = max(-h / 2 + corner, lid)
            let b = max(t + 0.004, min(h / 2 - corner, arc))
            top.append(SIMD2(x, t)); bottom.append(SIMD2(x, b))
        }
        return top + bottom.reversed()
    }

    private func pose(at t: Double) -> Pose {
        guard duration > 0, t < start + duration else { return to }
        let k = easeOutBack((t - start) / duration)
        return Pose(fields: zip(from.fields, to.fields).map { $0 + ($1 - $0) * k })
    }

    private func gaze(at t: Double) -> SIMD2<Double> {
        let d = (t - dartAt) / Face.dart
        guard (0..<1).contains(d) else { return gazeTo }
        return gazeFrom + (gazeTo - gazeFrom) * (1 - pow(1 - d, 3))
    }
}

/// Overshoots by about 6% before settling.
func easeOutBack(_ x: Double) -> Double {
    let c1 = 1.3, c3 = c1 + 1, u = max(0, min(1, x)) - 1
    return 1 + c3 * u * u * u + c1 * u * u
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

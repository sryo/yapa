import Foundation

/// One eye, in fractions of the screen width. `open` is how far the top lid is up (1 open, 0 shut);
/// `smile` raises the bottom lid into a happy arc; `tilt` slants the eye in radians.
public struct EyePose: Equatable {
    public var width = 0.26, height = 0.34, radius = 0.08
    public var open = 1.0, smile = 0.0, tilt = 0.0, y = 0.0

    var fields: [Double] { [width, height, radius, open, smile, tilt, y] }
    init(fields f: [Double]) { (width, height, radius, open, smile, tilt, y) = (f[0], f[1], f[2], f[3], f[4], f[5], f[6]) }
    init(width: Double = 0.26, height: Double = 0.34, open: Double = 1, smile: Double = 0, tilt: Double = 0, y: Double = 0) {
        (self.width, self.height, self.open, self.smile, self.tilt, self.y) = (width, height, open, smile, tilt, y)
    }
}

/// Both eyes plus the colour (hue, 0–1) and how much the gaze circles (dizzy).
public struct Pose: Equatable {
    public var left: EyePose, right: EyePose, hue: Double, spin = 0.0

    init(_ eye: EyePose, hue: Double, spin: Double = 0) { (left, right, self.hue, self.spin) = (eye, eye, hue, spin) }
    init(left: EyePose, right: EyePose, hue: Double) { (self.left, self.right, self.hue) = (left, right, hue) }

    var fields: [Double] { left.fields + right.fields + [hue, spin] }
    init(fields f: [Double]) {
        left = EyePose(fields: Array(f[0..<7])); right = EyePose(fields: Array(f[7..<14])); hue = f[14]; spin = f[15]
    }
    public func distance(to o: Pose) -> Double { zip(fields, o.fields).reduce(0) { $0 + abs($1.0 - $1.1) } }
}

/// The seven Hardware Buddy states, then yapa's own.
public enum Mood: String, CaseIterable {
    case sleep, idle, busy, attention, celebrate, dizzy, heart
    case curious, focused, impatient, proud, bored

    public var pose: Pose {
        switch self {
        case .sleep: Pose(EyePose(height: 0.30, open: 0.05, y: 0.03), hue: 0.62)
        case .idle: Pose(EyePose(), hue: 0.53)
        case .busy: Pose(EyePose(width: 0.24, height: 0.30, open: 0.9, y: -0.02), hue: 0.53)
        case .attention: Pose(EyePose(width: 0.28, height: 0.40), hue: 0.10)
        case .celebrate: Pose(EyePose(height: 0.32, smile: 0.5), hue: 0.15)
        case .dizzy: Pose(EyePose(open: 0.9), hue: 0.80, spin: 0.06)
        case .heart: Pose(EyePose(width: 0.27, smile: 0.6), hue: 0.93)
        case .curious: Pose(left: EyePose(height: 0.38), right: EyePose(height: 0.30, open: 0.85), hue: 0.47)
        case .focused: Pose(left: EyePose(height: 0.22, open: 0.7, tilt: -0.12), right: EyePose(height: 0.22, open: 0.7, tilt: 0.12), hue: 0.55)
        case .impatient: Pose(left: EyePose(width: 0.28, open: 0.75, tilt: 0.2), right: EyePose(width: 0.28, open: 0.75, tilt: -0.2), hue: 0.04)
        case .proud: Pose(EyePose(open: 0.6, smile: 0.35), hue: 0.33)
        case .bored: Pose(EyePose(height: 0.30, open: 0.45, y: 0.04), hue: 0.58)
        }
    }
}

public struct Frame {
    public var pose: Pose
    /// How open the eyes are after blinking, 0–1; `blink` is the blink's share of it.
    public var openness: Double, blink: Double
    public var gaze: SIMD2<Double>, gazeTarget: SIMD2<Double>
    /// Vertical scale while a glance darts (1 at rest).
    public var squash: Double
}

/// The face's motion: eased, retargetable expressions plus blinks and glances. All of it is a function of time.
public final class Face {
    static let blink = 0.16, dart = 0.08

    private var rng: SplitMix
    private let lively: Bool
    private(set) public var mood = Mood.idle
    private var from = Mood.idle.pose, to = Mood.idle.pose, start = 0.0, duration = 0.0
    private var blinkAt = 0.0, nextBlink = 0.0
    private var gazeFrom = SIMD2<Double>(0, 0), gazeTo = SIMD2<Double>(0, 0), dartAt = -1.0, nextDart = 0.0

    public init(seed: UInt64, now: Double, lively: Bool = true) {
        rng = SplitMix(seed); self.lively = lively
        blinkAt = -1; nextBlink = now + rng.next(in: 3...10); nextDart = now + rng.next(in: 1...2.25)
    }

    /// 120 ms for a small change, up to 300 ms for the largest.
    static func transitionDuration(from a: Pose, to b: Pose) -> Double { 0.12 + 0.18 * min(1, a.distance(to: b) / 2) }

    public func set(_ m: Mood, at t: Double) {
        guard m != mood else { return }
        from = pose(at: t); to = m.pose; mood = m; start = t
        duration = Face.transitionDuration(from: from, to: to)
    }

    public func isActive(at t: Double) -> Bool { mood != .sleep || t < start + duration }

    public func frame(at t: Double) -> Frame {
        let still = !lively || mood == .sleep
        if still {
            nextBlink = max(nextBlink, t + 3); nextDart = max(nextDart, t + 1)
        } else {
            while t >= nextBlink { blinkAt = nextBlink; nextBlink += rng.next(in: 3...10) }
            while t >= nextDart {
                gazeFrom = gaze(at: nextDart); dartAt = nextDart
                gazeTo = SIMD2(rng.next(in: -0.3...0.3), rng.next(in: -0.15...0.15))
                nextDart += rng.next(in: 1...2.25)
            }
        }
        let p = pose(at: t)
        let b = (t - blinkAt) / Face.blink
        let blink = (0..<1).contains(b) ? 1 - sin(.pi * b) : 1
        let d = (t - dartAt) / Face.dart
        let squash = (0..<1).contains(d) ? 1 - 0.12 * sin(.pi * d) : 1
        var g = gaze(at: t)
        if p.spin > 0 { g += p.spin * SIMD2(cos(2 * .pi * 1.5 * t), sin(2 * .pi * 1.5 * t)) }
        return Frame(pose: p, openness: min(p.left.open, p.right.open) * blink, blink: blink, gaze: g, gazeTarget: gazeTo, squash: squash)
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

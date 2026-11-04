import Foundation
import simd

/// Reads the pad's dial: two fingers land and twisting them turns it.
///
/// After Matthaeus Krenn's car UI, by way of Clak Remote's dials: the control comes to the fingers wherever they land,
/// so there is nothing to aim at. It turns by the angle of the line between the two fingers, clockwise up, one step
/// per `stepAngle`; moving the fingers apart, together or across the screen never changes it. One finger never acts,
/// so brushing the screen changes nothing. The count settles before anything locks (fingers never land at once),
/// three or more fingers lock as nothing, and a finger landing after the chord locked voids it. Letting go of a two-
/// finger chord that wasn't voided is a release, which is when the dial acts.
///
/// Pure geometry and time in points (y grows down, so a growing angle is clockwise), so every path replays in a test.
public struct Chord {
    public enum Event: Equatable {
        /// A chord locked; only two fingers turn anything.
        case began(fingers: Int)
        /// Whole steps since the last event, clockwise positive.
        case step(Int)
        /// Two fingers let go of a chord nothing voided.
        case released
        case ended
    }
    /// Where the turn is: the fingers' centre and half their spread, and angles in radians, screen coordinates.
    public struct Reading: Equatable {
        public var centre: SIMD2<Double>, radius: Double
        /// Where the turn began, and where it is now.
        public var start: Double, angle: Double
        /// Whole steps round from the start, clockwise positive.
        public var steps: Int
    }

    /// How long the count must hold before it's believed: fingers landing, and lifting.
    static let settleLanding = 0.08, settleLifting = 0.05
    /// Fingers closer together than this give an angle that swings wildly for a tiny movement, so it counts for nothing.
    static let deadZone = 24.0
    public static let stepAngle = Double.pi / 8

    private var count = 0, countSince = 0.0, landing = true
    private var locked: (turns: Bool, fingers: Int)?
    private var angle: Double?, turned = 0.0, unit = 0, lockedAt = 0.0
    public private(set) var reading: Reading?

    public init() {}

    public mutating func update(_ touches: [Int: SIMD2<Double>], at t: Double) -> [Event] {
        let n = touches.count
        if n == 0 { return release() }
        if n != count {
            landing = n > count
            count = n
            countSince = t
            // A finger coming or going changes which two are read: pick up from wherever they are now.
            angle = nil
            // A finger landing just after the chord locked, before anything turned, was part of it: count again.
            if locked != nil && landing && unit == 0 && t - lockedAt < 0.15 { locked = nil; reading = nil }
            // A finger landing later means another chord was meant: this one stops acting.
            if locked != nil && landing { locked?.turns = false; reading = nil }
        }
        guard let locked else {
            guard n >= 2, t - countSince >= (landing ? Self.settleLanding : Self.settleLifting) else { return [] }
            self.locked = (n == 2, n)
            lockedAt = t
            return [.began(fingers: n)]
        }
        guard locked.turns, n == 2 else { return [] }
        // The two fingers in the order they're keyed, so the line between them never flips.
        var it = touches.makeIterator()
        guard let f = it.next(), let g = it.next() else { return [] }
        let (p, q) = f.key < g.key ? (f.value, g.value) : (g.value, f.value), d = q - p
        guard simd_length(d) >= Self.deadZone else { angle = nil; return [] }
        let now = atan2(d.y, d.x)
        if let angle {
            var change = now - angle
            if change > .pi { change -= 2 * .pi }
            if change <= -.pi { change += 2 * .pi }
            turned += change
        }
        angle = now
        let whole = Int((turned / Self.stepAngle + (turned < 0 ? -1e-9 : 1e-9)).rounded(.towardZero))
        reading = Reading(centre: (p + q) / 2, radius: simd_length(d) / 2, start: now - turned, angle: now, steps: whole)
        guard whole != unit else { return [] }
        defer { unit = whole }
        return [.step(whole - unit)]
    }

    private mutating func release() -> [Event] {
        defer { self = Chord() }
        guard let locked else { return [] }
        return (locked.turns ? [.released] : []) + [.ended]
    }
}

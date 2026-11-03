import simd

/// Reads chords on the pad: how many fingers come down picks the control, and dragging them up or down turns it.
///
/// After Matthaeus Krenn's car UI: the control comes to the fingers wherever they land, so there is nothing to aim
/// at. One finger never acts, so brushing the screen changes nothing. The count settles before anything locks
/// (fingers never land at once), and how far apart the fingers are is read once at touch-down and then held.
/// A finger landing after the chord locked voids it. Each control has its own step size, larger the more a step
/// matters. A decision commits only when released 20% past its detent; coming back below the detent takes it back,
/// and letting go short of it sends nothing.
///
/// Pure geometry and time in points (y grows down), so every path replays in a test.
public struct Chord {
    public enum Control: Equatable {
        /// Two fingers close, a prompt up: drag up for once, down for deny.
        case decide
        /// Two fingers close, no prompt: step through recent lines.
        case scrub
        /// Two fingers wide apart.
        case spread
    }
    public enum Decision: Equatable { case once, deny }
    public enum Event: Equatable {
        /// A chord locked. Three or more fingers lock with no control yet.
        case began(Control?, fingers: Int)
        /// Whole steps since the last event, up positive.
        case step(Control, Int)
        /// The decision a release would send now, or nil.
        case armed(Decision?)
        case decided(Decision)
        case ended
    }

    /// Whether a permission prompt is waiting; read when a chord locks.
    public var prompt = false

    /// How long the count must hold before it's believed: fingers landing, and lifting.
    static let settleLanding = 0.08, settleLifting = 0.05
    /// Fingers farther than this from their centre make a wide chord. Krenn's iPad used 120 pt; the SE is 320 wide.
    static let wideRadius = 60.0
    static func stepSize(_ c: Control) -> Double {
        switch c {
        case .decide: 100
        case .scrub: 40
        case .spread: 90
        }
    }
    /// How far past the detent a decision arms.
    static let commitPast = 1.2

    private var count = 0, countSince = 0.0, landing = true
    private var locked: (control: Control?, fingers: Int)?
    private var originY = 0.0, lastCentre = SIMD2<Double>.zero, unit = 0
    private var armed: Decision?

    public init() {}

    public mutating func update(_ touches: [Int: SIMD2<Double>], at t: Double) -> [Event] {
        let n = touches.count
        let centre = n == 0 ? lastCentre : touches.values.reduce(.zero, +) / Double(n)
        defer { lastCentre = centre }
        if n == 0 { return release() }
        if n != count {
            landing = n > count
            count = n
            countSince = t
            // A finger coming or going moves the centre; that jump isn't a drag.
            if locked != nil { originY += centre.y - lastCentre.y }
            // A finger landing after the chord locked means another chord was meant: this one stops acting.
            if locked != nil && landing {
                locked?.control = nil
                if armed != nil { armed = nil; return [.armed(nil)] }
            }
        }
        guard let locked else {
            guard n >= 2, t - countSince >= (landing ? Self.settleLanding : Self.settleLifting) else { return [] }
            let wide = touches.values.contains { simd_length($0 - centre) > Self.wideRadius }
            let control: Control? = n > 2 ? nil : wide ? .spread : prompt ? .decide : .scrub
            self.locked = (control, n)
            originY = centre.y
            return [.began(control, fingers: n)]
        }
        guard let control = locked.control else { return [] }
        let size = Self.stepSize(control), up = originY - centre.y
        var events: [Event] = []
        var now = Int((up / size).rounded(.towardZero))
        if control == .decide {
            now = max(-1, min(1, now))
            let arm: Decision? = up >= size * Self.commitPast ? .once : up <= -size * Self.commitPast ? .deny
                : armed == .once && up >= size ? .once : armed == .deny && up <= -size ? .deny : nil
            if arm != armed { armed = arm; events.append(.armed(arm)) }
        }
        if now != unit { events.insert(.step(control, now - unit), at: 0); unit = now }
        return events
    }

    private mutating func release() -> [Event] {
        defer { let p = prompt; self = Chord(); prompt = p }
        guard locked != nil else { return [] }
        return (armed.map { [.decided($0)] } ?? []) + [.ended]
    }
}

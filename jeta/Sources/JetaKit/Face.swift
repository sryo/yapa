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
    case curious, focused, impatient, proud, bored, listening

    public var pose: Pose {
        switch self {
        case .sleep: Pose(EyePose(ax: 0.05, ay: 0, bend: -0.013, width: 0.02, y: 0.02), depth: -0.3)
        case .idle: Pose(EyePose())
        case .busy: Pose(EyePose(ay: 0.022, y: 0.012), depth: -0.45)
        case .attention: Pose(EyePose(ay: 0.05, width: 0.07, y: -0.006), depth: 0.5)
        case .celebrate: Pose(EyePose(ax: 0.045, ay: 0, bend: 0.03, width: 0.045, y: -0.01))
        case .dizzy: Pose(EyePose(ay: 0.026), spin: 0.6)
        case .heart: Pose(EyePose(ax: 0.05, ay: 0, bend: 0.036, width: 0.05, y: -0.015))
        // Curious looks through a telescope: one eye big, the other small.
        case .curious: Pose(left: EyePose(ay: 0.06, width: 0.11, y: -0.01), right: EyePose(ay: 0.012, width: 0.045, y: 0.012), depth: 1.0)
        case .focused: Pose(EyePose(ax: 0.022, ay: 0, width: 0.06), depth: -0.5)
        case .impatient: Pose(EyePose(ay: 0.04, width: 0.08, y: -0.022))
        case .proud: Pose(EyePose(ax: 0.035, ay: 0, bend: 0.018, width: 0.05, y: -0.006))
        case .bored: Pose(EyePose(ax: 0.03, ay: 0, bend: -0.004, width: 0.055, y: 0.02), depth: -0.25)
        case .listening: Pose(EyePose(ay: 0.04, width: 0.075, y: -0.01), depth: 0.2)
        }
    }
}

/// A quadratic stroke from p0 through control c to p1, `width` thick, around the screen centre.
public struct Stroke {
    public var p0, c, p1: SIMD2<Double>; public var width: Double
    /// The eye's velocity (fractions of the short side per second).
    public var smear: SIMD2<Double>
    /// Where the eye's middle was a moment ago, newest first: drawn as a tapering trail, like a smear frame.
    public var trail: [SIMD2<Double>]
    /// Squash along `impactAxis` (negative flattens along it and widens across, positive stretches), keeping area.
    public var impactAxis: SIMD2<Double>, impact: Double
    /// Horizontal squeeze from the head turning (1 faces you; less is turned away).
    public var xScale: Double

    public init(p0: SIMD2<Double>, c: SIMD2<Double>, p1: SIMD2<Double>, width: Double, smear: SIMD2<Double> = .zero,
                trail: [SIMD2<Double>] = [], impactAxis: SIMD2<Double> = SIMD2(1, 0), impact: Double = 0, xScale: Double = 1) {
        (self.p0, self.c, self.p1, self.width, self.smear) = (p0, c, p1, width, smear)
        (self.trail, self.impactAxis, self.impact, self.xScale) = (trail, impactAxis, impact, xScale)
    }

    var middle: SIMD2<Double> { (p0 + 2 * c + p1) / 4 }

    /// The trail: copies of the eye at its recent positions, each smaller than the one before. All solid white,
    /// they merge into one tapering smear behind the eye.
    public func trailOutlines() -> [[SIMD2<Double>]] {
        // Copies 4 ms apart overlap into one smooth smear; each needs fewer points than the eye itself.
        let shape = outline(samples: 17), mid = middle
        return trail.enumerated().map { k, at in
            let f = 1 - 0.55 * Double(k + 1) / Double(trail.count + 1)
            return shape.map { at + ($0 - mid) * f }
        }
    }

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
        var shape = left + right.reversed()
        if xScale != 1 { let m = middle; shape = shape.map { SIMD2(m.x + ($0.x - m.x) * xScale, $0.y) } }
        guard abs(impact) > 1e-9 else { return shape }
        let along = simd_normalize(impactAxis), k = 1 + max(-0.6, min(0.6, impact)), mid = middle
        return shape.map { p in
            let d = p - mid, a = simd_dot(d, along) * along
            return mid + a * k + (d - a) / k
        }
    }
}

public struct Frame {
    public var eyes: [Stroke]
    /// 0 open, 1 shut.
    public var blink: Double
    public var gazeTarget: SIMD2<Double>
    /// The head's tilt in radians, and how much nearer (>1) or farther (<1) it stands.
    public var tilt: Double, scale: Double
    /// Where the face itself is (its drift and moves), apart from where the eyes look.
    public var centre: SIMD2<Double>
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
/// It is calm by default: it drifts very slowly over the whole screen (so nothing burns into the panel, asleep or
/// awake), glances and blinks only now and then, and dozes off when nothing happens. Events are exaggerated:
/// shapes overshoot, a change squashes the eyes and makes them hop, and a quick move leaves a trail.
public final class Face {
    static let step = 1.0 / 240

    /// How far the middle of the face may wander from the screen's centre, in fractions of the short side.
    public var bounds = SIMD2<Double>(0.7, 0.35)
    /// Seconds of nothing happening before an idle face falls asleep.
    public var dozeAfter = 90.0
    /// Seconds of quiet, awake and idle, before it peeks in from a screen edge.
    public var peekAfter = 40.0
    /// Half the screen's size, in fractions of its short side (16:9 landscape is 0.89 by 0.5).
    public var screen = SIMD2<Double>(0.89, 0.5)

    private var rng: SplitMix
    private let lively: Bool
    private(set) public var mood = Mood.idle
    private var pose: [Spring] = Mood.idle.pose.fields.map { Spring(x: $0) }
    private var gaze = [Spring(x: 0), Spring(x: 0)], pos = [Spring(x: 0), Spring(x: 0)]
    private var blink = Spring(x: 0), sleepy = Spring(x: 0), squash = Spring(x: 0), hop = Spring(x: 0), tilt = Spring(x: 0)
    private var yaw = Spring(x: 0), lunge = Spring(x: 0), reading = Spring(x: 0), asideness = Spring(x: 0)
    private var asideOn = false, liftOn = false, lifted = Spring(x: 0)
    private var lungeUntil = -1.0, orbitStart = -10.0, busySince = 0.0, peekUntil = -1.0, peekSide = 1.0, peekedAt = -1e9
    private var now: Double, blinkAt = -1.0, nextBlink: Double, nextDart: Double, nextTilt = 0.0, tiltSide = 1.0, lastEvent: Double
    private var phase = SIMD2<Double>(0, 0), offset = SIMD2<Double>(0, 0)
    private var gazeTo = SIMD2<Double>(0, 0), posTo = SIMD2<Double>(0, 0), lastSpeed = 0.0
    private var impact = Spring(x: 0), impactAxis = SIMD2<Double>(1, 0), travel = SIMD2<Double>(1, 0), peak = 0.0
    /// Recent (time, position) of the face, for the trail.
    private var track: [(Double, SIMD2<Double>)] = []
    static let trailAges = stride(from: 0.004, through: 0.06, by: 0.004).map { $0 }
    /// Reading: seconds per line, and for turning the page after every 4 lines.
    static let readLine = 1.6, pageTurn = 1.2
    private var pageBlinked = -1

    public init(seed: UInt64, now: Double, lively: Bool = true) {
        rng = SplitMix(seed); self.lively = lively; self.now = now; lastEvent = now
        nextBlink = now + rng.next(in: 4...12); nextDart = now + rng.next(in: 4...9)
        phase = SIMD2(rng.next(in: 0...(2 * .pi)), rng.next(in: 0...(2 * .pi)))
        if lively { let d = drift(at: now); pos = [Spring(x: d.x), Spring(x: d.y)]; posTo = d }
    }

    /// The burn-in drift: two very slow sine waves (about 15 and 11 minutes) sweeping the whole allowed area,
    /// barely noticeable moment to moment.
    private func drift(at t: Double) -> SIMD2<Double> {
        SIMD2(bounds.x * sin(2 * .pi * t / 900 + phase.x), bounds.y * sin(2 * .pi * t / 660 + phase.y))
    }

    /// Sends the face quickly to `p` (an event: coming to you, say); from there it eases back into its drift.
    public func go(to p: SIMD2<Double>, at t: Double) {
        advance(to: t)
        offset = p - drift(at: t)
        lastEvent = t
    }

    public func set(_ m: Mood, at t: Double) {
        advance(to: t)
        guard m != mood else { return }
        kick(by: mood.pose.distance(to: m.pose))
        if m == .curious { nextTilt = t + rng.next(in: 2.5...4) }
        let wasAsleep = mood == .sleep
        mood = m
        lastEvent = t
        peekUntil = -1
        switch m {
        // Needing you lunges into the screen, like Clippy leaning in, then settles a little back.
        case .attention: go(to: .zero, at: t); lungeUntil = t + 0.9
        case .celebrate: orbitStart = t
        case .busy: busySince = t
        default: break
        }
        // Waking pops back up from the bottom where it slept.
        if wasAsleep && m != .attention { go(to: SIMD2(pos[0].x, 0), at: t) }
    }

    /// A finger on the screen at `point` (fractions of the short side from the centre): it wakes up if asleep,
    /// looks toward the finger for a few seconds, and gives a little hop.
    public func poke(at point: SIMD2<Double>, t: Double) {
        advance(to: t)
        if mood == .sleep { set(.idle, at: t) }
        let d = point - SIMD2(pos[0].x, pos[1].x)
        gazeTo = SIMD2(max(-1, min(1, d.x / 0.1)), max(-0.6, min(0.6, d.y / 0.1)))
        nextDart = t + 3
        peekUntil = -1
        lastEvent = t
        kick(by: 0.02)
    }

    /// Steps the face aside to the top-left corner, smaller, while text is up; back when it closes.
    public func aside(_ on: Bool, at t: Double) {
        advance(to: t)
        asideOn = on
    }

    /// Raises the face into the top half, a little smaller, while a question shows under it.
    public func lift(_ on: Bool, at t: Double) {
        advance(to: t)
        liftOn = on
    }

    public func isActive(at t: Double) -> Bool { mood != .sleep }

    func pose(at t: Double) -> Pose { advance(to: t); return Pose(fields: pose.map(\.x)) }

    public func frame(at t: Double) -> Frame {
        let p = pose(at: t), b = max(0, min(1, blink.x)), s = sleepy.x, sq = max(-0.6, min(0.6, squash.x))
        let breath = sin(t * 1.1) * (0.002 + 0.004 * s)
        let spin = p.spin * SIMD2(cos(2 * .pi * 1.5 * t), sin(2 * .pi * 1.5 * t))
        // The eyes lead where the face is travelling.
        let look = SIMD2(gaze[0].x * 0.05, gaze[1].x * lookDown) + spin * 0.04 + SIMD2(pos[0].v, pos[1].v) * 0.03
        // Up close the face also draws toward the middle, so its bigger eyes stay on screen.
        let scale = (1 + p.depth + lunge.x) * (1 - 0.45 * asideness.x) * (1 - 0.35 * lifted.x)
        let centre = SIMD2(pos[0].x, pos[1].x) / max(1, scale) + SIMD2(0, hop.x - 0.24 * lifted.x)
        // Celebrating, the eyes orbit each other once.
        let o = smoothstep(0, 1, (t - orbitStart) / 1.2), (oc, os) = (cos(2 * .pi * o), sin(2 * .pi * o))
        let velocity = SIMD2(pos[0].v + gaze[0].v * 0.05, pos[1].v + hop.v + gaze[1].v * 0.035) * scale
        let here = whereNow()
        // Only fast moves smear; glances and small shifts stay clean ovals.
        let fast = smoothstep(0.3, 0.8, simd_length(velocity))
        let shifts = Face.trailAges.compactMap { age in track.last(where: { $0.0 <= t - age }).map { $0.1 - here } }
        let (cs, sn) = (cos(tilt.x), sin(tilt.x))
        let place = { (v: SIMD2<Double>) in centre + SIMD2(v.x * cs - v.y * sn, v.x * sn + v.y * cs) * scale }
        // Moving sideways the head turns that way (a yaw, in 3D): the eyes slide toward the turn, the eye on that
        // side goes round the head (narrower and smaller) and the other comes nearer (a little bigger).
        let yw = yaw.x, (yc, ys) = (cos(yw), sin(yw))
        let eyes = [(p.left, -1.0), (p.right, 1.0)].map { e, side -> Stroke in
            let near = 1 - 0.5 * ys * side
            // A blink flattens the eye into a short thin line; max() and min() keep it continuous. The eye only
            // widens once its height has nearly gone, so going between pill and arc it never leans diagonally.
            // Squash shortens and fattens it, stretch does the opposite.
            // Springs overshoot, so clamp lengths at zero before shaping.
            let ay = max(0, e.ay) * (1 - b) * (1 + sq) * near
            let ax = max(0, e.ax, 0.03 * b) * (1 - 0.5 * sq) * (1 - smoothstep(0, 0.012, ay))
            let w = max(0.01, e.width - (e.width - min(e.width, 0.03)) * b) * (1 + 0.04 * s * sin(t * 1.1)) * (1 - 0.6 * sq) * near
            let apart = side * 0.06 * (1 - 0.3 * sq) * yc
            let c = SIMD2(apart * oc + ys * 0.05, apart * os + e.y + breath) + look
            let bow = SIMD2(0, 2 * e.bend * (1 + sq))
            let stroke = Stroke(p0: place(c - SIMD2(ax, ay)), c: place(c - bow), p1: place(c + SIMD2(ax, ay)), width: w * scale)
            return Stroke(p0: stroke.p0, c: stroke.c, p1: stroke.p1, width: stroke.width, smear: velocity,
                          trail: shifts.map { stroke.middle + $0 * fast }, impactAxis: impactAxis, impact: impact.x, xScale: yc)
        }
        return Frame(eyes: eyes, blink: b, gazeTarget: gazeTo, tilt: tilt.x, scale: scale, centre: centre)
    }

    /// How far the eyes move up and down with the gaze; reading moves them further, so the lines show.
    private var lookDown: Double { 0.035 + 0.2 * reading.x }

    /// Where the eyes are as a group: the face's position plus where they look. The trail follows this.
    private func whereNow() -> SIMD2<Double> {
        SIMD2(pos[0].x + gaze[0].x * 0.05 + pos[0].v * 0.03, pos[1].x + hop.x + gaze[1].x * lookDown + pos[1].v * 0.03)
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
            if lively && mood == .idle && now - lastEvent > dozeAfter { mood = .sleep }
            // After a quiet stretch it peeks in from the nearer edge, looking into the screen, then comes back.
            if lively && mood == .idle && peekUntil < 0 && now - max(lastEvent, peekedAt) > peekAfter {
                peekSide = pos[0].x >= 0 ? 1 : -1
                peekUntil = now + 6
            }
            let peeking = peekUntil > 0 && now < peekUntil
            if peekUntil > 0 && now >= peekUntil + 1.5 { peekUntil = -1; peekedAt = now }
            if !lively || mood == .sleep {
                nextBlink = max(nextBlink, now + 4); nextDart = max(nextDart, now + 4)
                if mood == .sleep { gazeTo = .zero }
            } else if peekUntil > 0 {
                gazeTo = SIMD2(-peekSide, 0); nextDart = max(nextDart, now + 2)
                if now >= nextBlink { blinkAt = nextBlink; nextBlink += rng.next(in: 4...12) }
            } else if mood == .busy {
                // Busy is reading: sweep left to right along a line, jump back, drop a line. After 4 lines it
                // turns the page: a look at the corner, a flick across with a blink, then the top line again.
                let r = Face.readLine, cycle = 4 * r + Face.pageTurn, u = now - busySince, c = u.truncatingRemainder(dividingBy: cycle)
                if c < 4 * r {
                    let ph = c.truncatingRemainder(dividingBy: r), line = Double(Int(c / r))
                    gazeTo = SIMD2(ph < 1.3 ? -0.8 + 1.6 * ph / 1.3 : -0.8, -0.45 + 0.3 * line)
                } else {
                    let q = c - 4 * r, page = Int(u / cycle)
                    gazeTo = q < 0.35 ? SIMD2(0.9, 0.3) : q < 0.7 ? SIMD2(-0.9, 0) : SIMD2(-0.8, -0.45)
                    if q >= 0.45 && pageBlinked != page { pageBlinked = page; blinkAt = now }
                }
                if now >= nextBlink { blinkAt = nextBlink; nextBlink += rng.next(in: 4...12) }
            } else {
                if now >= nextBlink { blinkAt = nextBlink; nextBlink += rng.next(in: 4...12) }
                if now >= nextDart { gazeTo = SIMD2(rng.next(in: -1...1), rng.next(in: -0.6...0.6)); nextDart += rng.next(in: 4...9) }
            }
            if lively {
                // An event's offset fades over about half a minute, so the face eases back into its drift.
                if !peeking { offset *= exp(-dt / 30) }
                let d = drift(at: now)
                if peeking { offset = SIMD2(peekSide * (screen.x + 0.02), pos[1].x) - d }
                if peekUntil > 0 && !peeking && now < peekUntil + dt * 1.5 { offset = .zero }
                // Asleep it rests low on the screen, still drifting sideways.
                posTo = mood == .sleep ? SIMD2(d.x + offset.x, screen.y - 0.12) : d + offset
                if asideOn { posTo = SIMD2(-(screen.x - 0.17), -(screen.y - 0.13)) }
                // Over a question it drifts and sleeps in the top half, clear of the text.
                if liftOn && !asideOn { posTo.y = min(posTo.y, -0.02) }
            }
            for i in pose.indices { pose[i].step(to: target[i], k: 220, damping: 0.45, dt: dt) }
            gaze[0].step(to: gazeTo.x, k: 120, damping: 0.85, dt: dt)
            gaze[1].step(to: gazeTo.y, k: 120, damping: 0.85, dt: dt)
            // Falling asleep sinks slowly; everything else moves briskly.
            let moveK = mood == .sleep ? 8.0 : 65
            pos[0].step(to: posTo.x, k: moveK, damping: 0.75, dt: dt)
            pos[1].step(to: posTo.y, k: moveK, damping: 0.75, dt: dt)
            // Stopping, after a move or a glance, flattens the eyes along the way they were going and widens
            // them across, like a ball hitting a wall; the spring then stretches them back along the same line.
            let v = SIMD2(pos[0].v + gaze[0].v * 0.05, pos[1].v + gaze[1].v * 0.035), speed = simd_length(v)
            if speed > 0.05 { travel = v / speed }
            peak = speed > 0.05 ? max(peak, speed) : 0
            // Only stopping from a fast move lands hard enough to squash; slow ones just settle.
            if speed < lastSpeed {
                if abs(impact.x) < 0.02 { impactAxis = travel }
                impact.v -= (lastSpeed - speed) * 16 * smoothstep(0.3, 0.8, peak)
            }
            lastSpeed = speed
            impact.step(to: 0, k: 260, damping: 0.45, dt: dt)
            track.append((now, whereNow()))
            if let first = track.first, now - first.0 > 0.1 { track.removeFirst() }
            if mood == .curious && now >= nextTilt { tiltSide = -tiltSide; nextTilt = now + rng.next(in: 2.5...4) }
            // Curious tilts the head like a dog; listening sways it gently, like with headphones on. Moving turns it instead.
            let tiltTo = mood == .curious ? 0.2 * tiltSide : mood == .listening ? 0.1 * sin(2 * .pi * 0.8 * now) : 0
            tilt.step(to: tiltTo, k: 60, damping: 0.5, dt: dt)
            lunge.step(to: now < lungeUntil ? 1 : 0, k: 140, damping: 0.6, dt: dt)
            reading.step(to: mood == .busy ? 1 : 0, k: 30, damping: 1, dt: dt)
            asideness.step(to: asideOn ? 1 : 0, k: 60, damping: 0.9, dt: dt)
            lifted.step(to: liftOn ? 1 : 0, k: 60, damping: 0.9, dt: dt)
            yaw.step(to: max(-0.35, min(0.35, pos[0].v * 0.5)), k: 310, damping: 0.85, dt: dt)
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

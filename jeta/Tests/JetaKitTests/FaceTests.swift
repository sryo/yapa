import simd
import XCTest
@testable import JetaKit

final class FaceTests: XCTestCase {
    func frames(_ face: Face, from a: Double, to b: Double, hz: Double = 240) -> [Frame] {
        stride(from: a, through: b, by: 1 / hz).map { face.frame(at: $0) }
    }
    /// A face sent across the screen every 2.5 s, as events would, sampled at `hz`.
    func darting(to end: Double, hz: Double = 60) -> [Frame] {
        let face = Face(seed: 11, now: 0)
        face.dozeAfter = .infinity
        let spots: [SIMD2<Double>] = [SIMD2(0.6, 0.2), SIMD2(-0.6, -0.25), SIMD2(0.1, 0.3), SIMD2(-0.3, -0.3), SIMD2(0.65, -0.1)]
        var next = 1.0, k = 0
        return stride(from: 0, through: end, by: 1 / hz).map { t in
            if t >= next { face.go(to: spots[k % spots.count], at: t); k += 1; next += 2.5 }
            return face.frame(at: t)
        }
    }
    func jump(_ x: Frame, _ y: Frame) -> Double {
        zip(x.eyes, y.eyes).map { a, b in
            max(simd_length(a.p0 - b.p0), simd_length(a.c - b.c), simd_length(a.p1 - b.p1), abs(a.width - b.width))
        }.max()!
    }

    // R1: changing mood flows: at 240 fps no step moves an eye more than a sliver, and it settles within 0.9 s.
    func testR1_MoodChangesFlowAndSettle() {
        for (a, b) in [(Mood.idle, Mood.celebrate), (.celebrate, .sleep), (.sleep, .attention), (.curious, .focused)] {
            let face = Face(seed: 1, now: 0, lively: false)
            face.set(a, at: 0)
            face.set(b, at: 1)
            let fs = frames(face, from: 1, to: 1.9)
            for (x, y) in zip(fs, fs.dropFirst()) { XCTAssertLessThan(jump(x, y), 0.012, "\(a)→\(b) jumps") }
            XCTAssertLessThan(face.pose(at: 1.9).distance(to: b.pose), 0.004, "\(a)→\(b) hasn't settled")
        }
    }

    // R1: changes are exaggerated: the eyes overshoot past the new shape, squash, and hop before settling.
    func testR1_ChangesAreExaggerated() {
        let face = Face(seed: 1, now: 0, lively: false)
        face.set(.attention, at: 0.5)
        let fs = frames(face, from: 0.5, to: 1.5)
        let from = Mood.idle.pose.left.ay, to = Mood.attention.pose.left.ay
        let peak = fs.map { f in (f.eyes[0].p1.y - f.eyes[0].p0.y) / 2 }.max()!
        XCTAssertGreaterThan(peak - to, (to - from) * 0.15, "no overshoot")
        let rest = face.frame(at: 3).eyes[0].c.y
        XCTAssertGreaterThan(rest - fs.map { $0.eyes[0].c.y }.min()!, 0.015, "no hop")
        let heights = fs.map { f in (f.eyes[0].p1.y - f.eyes[0].p0.y) / 2 / f.scale }
        XCTAssertLessThan(heights.prefix(24).min()!, from * 0.9, "no squash before stretching")
    }

    // R1: changing mood mid-change continues from where the eyes are, with no jump.
    func testR1_RetargetHasNoJump() {
        let face = Face(seed: 1, now: 0, lively: false)
        face.set(.attention, at: 0)
        let before = face.frame(at: 0.0999)
        face.set(.celebrate, at: 0.1)
        XCTAssertLessThan(jump(before, face.frame(at: 0.1001)), 0.012)
    }

    // R2: awake and calm, it blinks every 4–12 s and glances every 4–9 s, over ten simulated minutes.
    func testR2_BlinksAndGlancesOnSchedule() {
        let face = Face(seed: 42, now: 0)
        face.dozeAfter = .infinity
        face.peekAfter = .infinity
        var blinks: [Double] = [], glances: [Double] = []
        var wasClosed = false, lastGaze = face.frame(at: 0).gazeTarget
        for i in 1...(600 * 60) {
            let t = Double(i) / 60, f = face.frame(at: t)
            let closed = f.blink > 0.5
            if closed && !wasClosed { blinks.append(t) }
            wasClosed = closed
            if f.gazeTarget != lastGaze { glances.append(t); lastGaze = f.gazeTarget }
        }
        XCTAssertGreaterThan(blinks.count, 45)
        XCTAssertGreaterThan(glances.count, 60)
        for (a, b) in zip(blinks, blinks.dropFirst()) { XCTAssert((3.9...12.1).contains(b - a), "blink gap \(b - a)") }
        for (a, b) in zip(glances, glances.dropFirst()) { XCTAssert((3.98...9.02).contains(b - a), "glance gap \(b - a)") }
    }

    // R2: a blink closes the eye to a thin line and opens it again, without jumping.
    func testR2_BlinkFlows() {
        let face = Face(seed: 42, now: 0)
        let fs = frames(face, from: 0, to: 16)
        XCTAssertGreaterThan(fs.map(\.blink).max()!, 0.9)
        for (x, y) in zip(fs, fs.dropFirst()) { XCTAssertLessThan(jump(x, y), 0.03) }
    }

    // R2: asleep, it doesn't blink or glance; it only breathes and drifts slowly.
    func testR2_SleepOnlyBreathes() {
        let face = Face(seed: 3, now: 0)
        face.set(.sleep, at: 0)
        let g = face.frame(at: 3).gazeTarget
        let fs = frames(face, from: 3, to: 63, hz: 30)
        for f in fs { XCTAssertEqual(f.gazeTarget, g); XCTAssertLessThan(f.blink, 0.01) }
        XCTAssert(fs.allSatisfy { simd_length($0.eyes[0].smear) < 0.06 }, "moves fast in its sleep")
        XCTAssertFalse(face.isActive(at: 63))
    }

    // R3: the seven official moods plus yapa's own six, each with its own shape.
    func testR3_EveryMoodHasItsOwnPose() {
        let official: Set<String> = ["sleep", "idle", "busy", "attention", "celebrate", "dizzy", "heart"]
        let own: Set<String> = ["curious", "focused", "impatient", "proud", "bored", "listening"]
        XCTAssertEqual(Set(Mood.allCases.map(\.rawValue)), official.union(own))
        let moods = Mood.allCases
        for (i, a) in moods.enumerated() {
            for b in moods[(i + 1)...] {
                XCTAssertGreaterThan(a.pose.distance(to: b.pose), 0.04, "\(a) and \(b) look the same")
            }
        }
    }

    // R4: each eye is one round-capped stroke, so nothing is ever cut off; and no eye tilts, so none looks angry.
    func testR4_RoundStrokesNeverTilted() {
        for m in Mood.allCases {
            for eye in [m.pose.left, m.pose.right] {
                XCTAssert(eye.ax == 0 || eye.ay == 0, "\(m) tilts an eye")
                XCTAssertGreaterThanOrEqual(eye.width, 0.02, "\(m) is too thin to read")
            }
        }
        let face = Face(seed: 9, now: 0)
        for (i, m) in Mood.allCases.enumerated() { face.set(m, at: Double(i)) }
        for f in frames(face, from: 0, to: Double(Mood.allCases.count), hz: 30) {
            for e in f.eyes { XCTAssert([e.p0.x, e.p0.y, e.c.x, e.c.y, e.p1.x, e.p1.y, e.width].allSatisfy(\.isFinite)) }
        }
    }

    // R4: while morphing between pill and arc, and while blinking, an eye never leans diagonally.
    func testR4_MorphsNeverLean() {
        let face = Face(seed: 5, now: 0)
        var t = 0.0
        for m in Mood.allCases + Mood.allCases.reversed() {
            face.set(m, at: t)
            for f in frames(face, from: t, to: t + 0.7) {
                for e in f.eyes {
                    let r = e.p1 - e.p0, (cs, sn) = (cos(-f.tilt), sin(-f.tilt))
                    let d = SIMD2(r.x * cs - r.y * sn, r.x * sn + r.y * cs) / f.scale
                    XCTAssertLessThanOrEqual(min(abs(d.x), abs(d.y)), 0.025, "\(m) leans at \(d)")
                }
            }
            t += 0.7
        }
    }

    // R5: to avoid burn-in the face drifts slowly over the whole screen, never past its edges, asleep or awake.
    func testR5_DriftsTheWholeScreenSlowly() {
        for asleep in [false, true] {
            let face = Face(seed: 11, now: 0)
            face.bounds = SIMD2(0.7, 0.35)
            face.peekAfter = .infinity
            face.dozeAfter = .infinity
            if asleep { face.set(.sleep, at: 0) }
            let fs = frames(face, from: 0, to: 1800, hz: 2)
            let centres = fs.map { ($0.eyes[0].c + $0.eyes[1].c) / 2 }
            let xs = centres.map(\.x), ys = centres.map(\.y)
            XCTAssertGreaterThan(xs.max()! - xs.min()!, 0.9, "doesn't cover the screen sideways (asleep: \(asleep))")
            if !asleep { XCTAssertGreaterThan(ys.max()! - ys.min()!, 0.45, "doesn't cover it up and down") }
            XCTAssert(centres.allSatisfy { abs($0.x) < 0.8 && abs($0.y) < 0.45 }, "leaves the screen")
            let steps = zip(fs, fs.dropFirst()).dropFirst(8).map { simd_length($1.centre - $0.centre) * 2 }
            XCTAssertLessThan(steps.max()!, 0.008, "drifts too fast (asleep: \(asleep))")
        }
    }

    // R9: with nothing happening it dozes off on its own; any mood change wakes it.
    func testR9_DozesWhenNothingHappens() {
        let face = Face(seed: 11, now: 0)
        face.dozeAfter = 60
        _ = face.frame(at: 59)
        XCTAssertEqual(face.mood, .idle)
        _ = face.frame(at: 61)
        XCTAssertEqual(face.mood, .sleep)
        face.set(.attention, at: 70)
        XCTAssertEqual(face.mood, .attention)
    }

    // R9: needing you brings it to the middle of the screen in one quick move.
    func testR9_AttentionComesToTheMiddle() {
        let face = Face(seed: 11, now: 0)
        face.go(to: SIMD2(0.6, 0.3), at: 0)
        _ = face.frame(at: 3)
        face.set(.attention, at: 3)
        let c = face.frame(at: 5)
        XCTAssertLessThan(simd_length((c.eyes[0].c + c.eyes[1].c) / 2), 0.08)
    }

    // R6: curious steps closer to you and tilts its head like a dog, then to the other side if it stays curious.
    func testR6_CuriousLeansInAndTilts() {
        let face = Face(seed: 2, now: 0)
        face.set(.curious, at: 0)
        let fs = frames(face, from: 0, to: 8, hz: 30)
        XCTAssertGreaterThan(fs.last!.scale, 1.9, "doesn't step closer")
        let tilts = fs.map(\.tilt)
        XCTAssertGreaterThan(tilts.max()!, 0.15, "doesn't tilt one way")
        XCTAssertLessThan(tilts.min()!, -0.15, "doesn't tilt the other way")
    }

    // R6: when it doesn't want to be reached (focused, busy) it steps back; otherwise it holds its head straight.
    func testR6_StepsBackWhenBusy() {
        for m in [Mood.focused, .busy] {
            let face = Face(seed: 2, now: 0)
            face.set(m, at: 0)
            let f = face.frame(at: 3)
            XCTAssertLessThan(f.scale, 0.6, "\(m) doesn't step back")
            XCTAssertEqual(f.tilt, 0, accuracy: 0.01)
        }
    }

    // R7: a straight eye is drawn as a true oval, not a capsule with flat sides.
    func testR7_StraightEyeIsAnOval() {
        let s = Stroke(p0: SIMD2(0, -0.03), c: .zero, p1: SIMD2(0, 0.03), width: 0.06)
        let a = 0.03 + 0.03, b = 0.03
        for p in s.outline() {
            XCTAssertEqual((p.x / b) * (p.x / b) + (p.y / a) * (p.y / a), 1, accuracy: 0.02, "\(p) is off the oval")
        }
    }

    // R7: a curved eye tapers to soft points, and a dot is a circle.
    func testR7_ArcTapersAndDotIsRound() {
        let arc = Stroke(p0: SIMD2(-0.045, 0), c: SIMD2(0, -0.06), p1: SIMD2(0.045, 0), width: 0.045).outline()
        let n = arc.count / 2
        XCTAssertLessThan(simd_length(arc[0] - arc[arc.count - 1]), 0.002, "tips aren't pointed")
        XCTAssertGreaterThan(simd_length(arc[n / 2] - arc[arc.count - 1 - n / 2]), 0.04, "middle isn't full width")
        let dot = Stroke(p0: .zero, c: .zero, p1: .zero, width: 0.06).outline()
        for p in dot { XCTAssertEqual(simd_length(p), 0.03, accuracy: 0.001) }
    }

    // R7: the eyes sit close together: the gap between them is no wider than one eye.
    func testR7_EyesSitClose() {
        let f = Face(seed: 1, now: 0, lively: false).frame(at: 1)
        let l = f.eyes[0].outline(), r = f.eyes[1].outline()
        let gap = r.map(\.x).min()! - l.map(\.x).max()!, width = l.map(\.x).max()! - l.map(\.x).min()!
        XCTAssertGreaterThan(gap, width * 0.5, "eyes touch")
        XCTAssertLessThanOrEqual(gap, width * 1.05, "eyes too far apart")
    }

    // R8: a fast-moving eye leaves a trail along its path, tapering behind it, like a smear frame; at rest it has none.
    func testR8_FastEyesLeaveATrail() {
        let fs = darting(to: 30)
        func reach(_ s: Stroke) -> Double {
            let mid = (s.p0 + 2 * s.c + s.p1) / 4
            return s.trail.map { simd_length($0 - mid) }.max() ?? 0
        }
        let speed = fs.map { simd_length($0.eyes[0].smear) }
        let moving = fs.filter { simd_length($0.eyes[0].smear) > 0.6 }
        let still = (6..<fs.count).filter { i in speed[(i - 6)...i].allSatisfy { $0 < 0.01 } }.map { fs[$0] }
        XCTAssertFalse(moving.isEmpty || still.isEmpty)
        XCTAssertGreaterThan(moving.map { reach($0.eyes[0]) }.max()!, 0.04, "no trail behind a fast eye")
        XCTAssert(still.allSatisfy { reach($0.eyes[0]) < 0.003 }, "trail while still")
        // The trail points back where the eye came from, and each step back is smaller.
        let f = moving.max(by: { simd_length($0.eyes[0].smear) < simd_length($1.eyes[0].smear) })!, e = f.eyes[0]
        let mid = (e.p0 + 2 * e.c + e.p1) / 4
        XCTAssertLessThan(simd_dot(e.trail.last! - mid, e.smear), 0, "trail is in front of the eye")
        let sizes = e.trailOutlines().map { o in o.map(\.y).max()! - o.map(\.y).min()! }
        XCTAssertEqual(sizes, sizes.sorted(by: >), "trail doesn't taper")
    }

    // R8: moving sideways the head turns toward where it goes, in 3D: both eyes slide that way, the eye on that
    // side narrows and shrinks (it's going round the head) and the other grows a little. The face never rotates for it.
    func testR8_HeadTurnsTowardMotion() {
        let fs = darting(to: 40)
        func span(_ s: Stroke) -> SIMD2<Double> {
            let o = s.outline(); return SIMD2(o.map(\.x).max()! - o.map(\.x).min()!, o.map(\.y).max()! - o.map(\.y).min()!)
        }
        let right = fs.filter { $0.eyes[0].smear.x > 0.4 }, left = fs.filter { $0.eyes[0].smear.x < -0.4 }
        XCTAssertFalse(right.isEmpty || left.isEmpty)
        for (group, lead, trail, sign) in [(right, 1, 0, 1.0), (left, 0, 1, -1.0)] {
            let turned = group.filter { f in
                let mid = (f.eyes[0].middle + f.eyes[1].middle) / 2
                return (mid.x - f.centre.x) * sign > 0.005 && span(f.eyes[lead]).x < span(f.eyes[trail]).x * 0.95
                    && span(f.eyes[lead]).y < span(f.eyes[trail]).y
            }
            XCTAssertGreaterThan(Double(turned.count) / Double(group.count), 0.8, "doesn't turn toward \(sign > 0 ? "right" : "left")")
        }
        XCTAssert(fs.allSatisfy { abs($0.tilt) < 0.01 }, "the face rotates while moving")
    }

    // R8: stopping after a fast move squashes the eye along the direction it was travelling (and widens it across),
    // the way a ball flattens against what it hits.
    func testR8_SquashesAlongImpact() {
        let fs = darting(to: 40)
        let speed = fs.map { simd_length($0.eyes[0].smear) }
        var landings = 0, squashed = 0
        for i in 30..<fs.count where speed[i - 1] >= 0.1 && speed[i] < 0.1 && speed[(i - 30)..<i].max()! > 0.6 {
            landings += 1
            let dir = simd_normalize(fs[(i - 30)..<i].max(by: { simd_length($0.eyes[0].smear) < simd_length($1.eyes[0].smear) })!.eyes[0].smear)
            let across = SIMD2(-dir.y, dir.x)
            func ratio(_ f: Frame) -> Double {
                let o = f.eyes[0].outline(), al = o.map { simd_dot($0, dir) }, ac = o.map { simd_dot($0, across) }
                return (al.max()! - al.min()!) / (ac.max()! - ac.min()!)
            }
            let rest = ratio(Face(seed: 11, now: 0, lively: false).frame(at: 1))
            if fs[(i - 20)..<min(fs.count, i + 20)].contains(where: { ratio($0) < rest * 0.85 && $0.blink < 0.1 }) { squashed += 1 }
        }
        XCTAssertGreaterThan(landings, 2)
        XCTAssertGreaterThan(Double(squashed) / Double(landings), 0.7, "doesn't squash along the impact")
        let s = Stroke(p0: .zero, c: .zero, p1: .zero, width: 0.06, impactAxis: SIMD2(1, 0), impact: -0.3).outline()
        let w = s.map(\.x).max()! - s.map(\.x).min()!, h = s.map(\.y).max()! - s.map(\.y).min()!
        XCTAssertLessThan(w, h * 0.8, "a sideways impact doesn't flatten sideways")
        XCTAssertEqual(w * h, 0.06 * 0.06, accuracy: 0.0002, "squash doesn't keep the volume")
    }

    // R8: moving diagonally never slants an eye on its own: the oval's top stays over its bottom.
    func testR8_SmearNeverTilts() {
        for v in [SIMD2(1.2, 1.2), SIMD2(-1.2, 1.2), SIMD2(1.2, -1.2)] {
            let o = Stroke(p0: SIMD2(0, -0.035), c: .zero, p1: SIMD2(0, 0.035), width: 0.06, smear: v).outline()
            let top = o.min(by: { $0.y < $1.y })!, bottom = o.max(by: { $0.y < $1.y })!
            XCTAssertEqual(top.x, bottom.x, accuracy: 0.002, "smear along \(v) slants the eye")
        }
    }

    // R8: short, slow moves (glances, small shifts) stay clean: no trail and no squash wobble, only fast moves get them.
    func testR8_SlowMovesStayClean() {
        let face = Face(seed: 11, now: 0)
        let fs = frames(face, from: 0, to: 60, hz: 60)
        let speed = fs.map { simd_length($0.eyes[0].smear) }
        let calm = (60..<fs.count).filter { i in speed[(i - 60)...i].allSatisfy { $0 < 0.25 } }.map { fs[$0] }
        XCTAssertGreaterThan(calm.count, 300)
        for f in calm {
            let e = f.eyes[0], mid = (e.p0 + 2 * e.c + e.p1) / 4
            XCTAssertLessThan(e.trail.map { simd_length($0 - mid) }.max() ?? 0, 0.002, "trail on a slow move")
            XCTAssertLessThan(abs(e.impact), 0.02, "squash wobble on a slow move")
        }
    }

    // R6: stepping up close never pushes the eyes off the screen, wherever the drift has taken the face.
    func testR6_CloseUpStaysOnScreen() {
        let face = Face(seed: 5, now: 0)
        face.bounds = SIMD2(0.62, 0.3)
        face.set(.curious, at: 0)
        for f in frames(face, from: 0, to: 1800, hz: 1) {
            for e in f.eyes {
                let o = e.outline()
                XCTAssert(o.allSatisfy { abs($0.x) < 0.89 && abs($0.y) < 0.5 }, "close-up eye leaves the screen at \(f.centre)")
            }
        }
    }

    func centre(_ f: Frame) -> SIMD2<Double> { (f.eyes[0].middle + f.eyes[1].middle) / 2 }
    func area(_ s: Stroke) -> Double {
        let o = s.outline(); return (o.map(\.x).max()! - o.map(\.x).min()!) * (o.map(\.y).max()! - o.map(\.y).min()!)
    }

    // R10: needing you is a lunge, like Clippy leaning into the screen: it shoots up close (2.3x or more), holds
    // there looking at you, then settles back to 1.5x.
    func testR10_AttentionLunges() {
        let face = Face(seed: 1, now: 0)
        face.set(.attention, at: 1)
        let fs = frames(face, from: 1, to: 4)
        let peakAt = fs.indices.max(by: { fs[$0].scale < fs[$1].scale })!
        XCTAssertGreaterThan(fs[peakAt].scale, 2.3, "no lunge")
        XCTAssertLessThan(Double(peakAt) / 240, 0.6, "lunge too slow")
        XCTAssertGreaterThan(fs.filter { $0.scale > 2.2 }.count, Int(0.4 * 240), "doesn't hold close")
        XCTAssertEqual(fs.last!.scale, 1.5, accuracy: 0.05, "doesn't settle back")
    }

    // R10: after a quiet stretch awake, it peeks in from a screen edge with only part of the face showing, then
    // comes back; while it peeks it looks into the screen.
    func testR10_PeeksFromTheEdge() {
        let face = Face(seed: 4, now: 0)
        face.screen = SIMD2(0.89, 0.5)
        face.peekAfter = 20
        face.dozeAfter = .infinity
        let fs = frames(face, from: 0, to: 60, hz: 10)
        let out = fs.filter { abs(centre($0).x) > 0.8 }
        XCTAssertFalse(out.isEmpty, "never peeks")
        XCTAssert(out.allSatisfy { centre($0).x * $0.gazeTarget.x < 0 }, "doesn't look into the screen while peeking")
        XCTAssertLessThan(abs(centre(fs.last!).x), 0.8, "stays off the edge")
        XCTAssertNil(fs[0..<150].first(where: { abs(centre($0).x) > 0.8 }), "peeks before the quiet stretch")
    }

    // R10: falling asleep it sinks toward the bottom of the screen; waking up it pops back up quickly.
    func testR10_SinksToSleepAndRisesOnWaking() {
        let face = Face(seed: 2, now: 0)
        face.screen = SIMD2(0.89, 0.5)
        face.set(.sleep, at: 1)
        let asleep = face.frame(at: 15)
        XCTAssertGreaterThan(centre(asleep).y, 0.3, "doesn't sink")
        face.set(.idle, at: 15)
        let awake = face.frame(at: 16.2)
        XCTAssertLessThan(centre(awake).y, centre(asleep).y - 0.2, "doesn't rise quickly")
    }

    // R10: busy is reading several lines: the eyes sweep left to right, jump back, and visibly drop a line.
    func testR10_BusyReads() {
        let face = Face(seed: 2, now: 0)
        face.set(.busy, at: 0)
        let g = frames(face, from: 1, to: 9, hz: 20).map(\.gazeTarget)
        var sweeps = 0, lines = Set<Double>()
        for (a, b) in zip(g, g.dropFirst()) {
            if b.x < a.x - 0.5 { sweeps += 1 }
            lines.insert((b.y * 100).rounded())
        }
        XCTAssertGreaterThan(sweeps, 3, "doesn't sweep and return")
        XCTAssertGreaterThan(lines.count, 2, "doesn't move down the lines")
        let rising = zip(g, g.dropFirst()).filter { $1.x > $0.x }.count, falling = zip(g, g.dropFirst()).filter { $1.x < $0.x }.count
        XCTAssertGreaterThan(rising, falling * 4, "doesn't read left to right")
        // The lines are far enough apart to see: the eyes drop by a good part of their own height per line.
        let fs = frames(face, from: 10, to: 18, hz: 30), ys = fs.map { centre($0).y - $0.centre.y }
        XCTAssertGreaterThan(ys.max()! - ys.min()!, 0.08, "reading looks like a single line")
    }

    // R10: after a page of 4 lines it turns the page: the eyes flick from right to left across the page, blink,
    // and start again from the top line.
    func testR10_BusyTurnsThePage() {
        let face = Face(seed: 2, now: 0)
        face.set(.busy, at: 0)
        let page = Face.readLine * 4
        let turn = frames(face, from: page, to: page + Face.pageTurn, hz: 60)
        XCTAssert(turn.contains { $0.gazeTarget.x > 0.6 } && turn.contains { $0.gazeTarget.x < -0.6 }, "no flick across the page")
        XCTAssertGreaterThan(turn.map(\.blink).max()!, 0.5, "no blink at the page turn")
        let next = face.frame(at: page + Face.pageTurn + 0.2)
        XCTAssertEqual(next.gazeTarget.y, -0.45, accuracy: 0.01, "doesn't start the new page at the top")
    }

    // R10: curious looks like a telescope: one eye much bigger than the other.
    func testR10_CuriousTelescope() {
        let face = Face(seed: 2, now: 0, lively: false)
        face.set(.curious, at: 0)
        let f = face.frame(at: 3)
        XCTAssertGreaterThan(area(f.eyes[0]) / area(f.eyes[1]), 2.5)
    }

    // R10: listening sways gently, like with headphones on.
    func testR10_ListeningSways() {
        let face = Face(seed: 2, now: 0)
        face.set(.listening, at: 0)
        let tilts = frames(face, from: 2, to: 8, hz: 30).map(\.tilt)
        XCTAssertGreaterThan(tilts.max()!, 0.07)
        XCTAssertLessThan(tilts.min()!, -0.07)
        var crossings = 0
        for (a, b) in zip(tilts, tilts.dropFirst()) where (a < 0) != (b < 0) { crossings += 1 }
        XCTAssert((6...14).contains(crossings), "sways at the wrong pace: \(crossings) crossings in 6 s")
    }

    // R10: celebrating, the eyes orbit around each other once, then sit side by side again.
    func testR10_CelebrateOrbits() {
        let face = Face(seed: 2, now: 0, lively: false)
        face.set(.celebrate, at: 1)
        let during = frames(face, from: 1, to: 2.3, hz: 60).map { $0.eyes[1].middle - $0.eyes[0].middle }, end = face.frame(at: 3)
        let dEnd = end.eyes[1].middle - end.eyes[0].middle
        XCTAssert(during.contains { abs($0.y) > 0.08 && abs($0.y) > abs($0.x) }, "eyes don't swing round each other")
        XCTAssertGreaterThan(dEnd.x, 0.08, "eyes don't come back side by side")
        XCTAssertLessThan(abs(dEnd.y), 0.01)
    }

    // R11: a tap wakes it if it's asleep (it pops up and opens its eyes), and it looks toward the finger.
    func testR11_TapWakesAndLooks() {
        let face = Face(seed: 2, now: 0)
        face.set(.sleep, at: 0)
        _ = face.frame(at: 10)
        face.poke(at: SIMD2(0.6, -0.3), t: 10)
        XCTAssertEqual(face.mood, .idle, "a tap doesn't wake it")
        let f = face.frame(at: 11)
        XCTAssertGreaterThan(f.gazeTarget.x, 0.5, "doesn't look toward the finger")
        XCTAssertLessThan(f.gazeTarget.y, 0, "doesn't look up at the finger")
        // Awake, a tap just draws its eyes, and resets the time before it dozes.
        face.poke(at: SIMD2(-0.6, 0.2), t: 20)
        XCTAssertLessThan(face.frame(at: 21).gazeTarget.x, -0.5)
        _ = face.frame(at: 20 + face.dozeAfter - 1)
        XCTAssertEqual(face.mood, .idle, "dozes too soon after a tap")
    }

    // R4: sleeping eyes are thin, wide arcs that curve down like closed lids, at the face's small scale.
    func testR4_SleepIsThinWideArc() {
        let e = Mood.sleep.pose.left
        XCTAssertEqual(e.ax, 0.05, accuracy: 1e-9)
        XCTAssertEqual(e.bend, -0.013, accuracy: 1e-9)
        XCTAssertEqual(e.width, 0.02, accuracy: 1e-9)
    }

    // T8: with a question up the face stays in the top half, over it: its drift and its sleep never bring it down
    // onto the text.
    func testT8_LiftedFaceStaysAboveTheQuestion() {
        for seed in 0..<20 as Range<UInt64> {
            let face = Face(seed: seed, now: 0)
            face.bounds = SIMD2(0.62, 0.3); face.screen = SIMD2(0.89, 0.5); face.dozeAfter = 60
            face.lift(true, at: 0)
            for t in stride(from: 2.0, through: 400, by: 0.5) {
                let low = face.frame(at: t).eyes.flatMap { $0.outline() }.map(\.y).max()!
                XCTAssertLessThan(low, 0.05, "seed \(seed): the lifted face reaches the question at \(t) s")
            }
        }
    }
}

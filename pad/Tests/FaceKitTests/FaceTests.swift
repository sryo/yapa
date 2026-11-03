import simd
import XCTest
@testable import FaceKit

final class FaceTests: XCTestCase {
    func frames(_ face: Face, from a: Double, to b: Double, hz: Double = 240) -> [Frame] {
        stride(from: a, through: b, by: 1 / hz).map { face.frame(at: $0) }
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
        let heights = fs.map { f in (f.eyes[0].p1.y - f.eyes[0].p0.y) / 2 }
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

    // R2: blinks every 3–10 s and glances every 1–2.25 s, over ten simulated minutes.
    func testR2_BlinksAndGlancesOnSchedule() {
        let face = Face(seed: 42, now: 0)
        var blinks: [Double] = [], glances: [Double] = []
        var wasClosed = false, lastGaze = face.frame(at: 0).gazeTarget
        for i in 1...(600 * 60) {
            let t = Double(i) / 60, f = face.frame(at: t)
            let closed = f.blink > 0.5
            if closed && !wasClosed { blinks.append(t) }
            wasClosed = closed
            if f.gazeTarget != lastGaze { glances.append(t); lastGaze = f.gazeTarget }
        }
        XCTAssertGreaterThan(blinks.count, 55)
        XCTAssertGreaterThan(glances.count, 250)
        for (a, b) in zip(blinks, blinks.dropFirst()) { XCTAssert((2.9...10.1).contains(b - a), "blink gap \(b - a)") }
        for (a, b) in zip(glances, glances.dropFirst()) { XCTAssert((0.98...2.27).contains(b - a), "glance gap \(b - a)") }
    }

    // R2: a blink closes the eye to a thin line and opens it again, without jumping.
    func testR2_BlinkFlows() {
        let face = Face(seed: 42, now: 0)
        let fs = frames(face, from: 0, to: 12)
        XCTAssertGreaterThan(fs.map(\.blink).max()!, 0.9)
        for (x, y) in zip(fs, fs.dropFirst()) { XCTAssertLessThan(jump(x, y), 0.03) }
    }

    // R2: asleep, the eyes stay put and only breathe.
    func testR2_SleepOnlyBreathes() {
        let face = Face(seed: 3, now: 0)
        face.set(.sleep, at: 0)
        let g = face.frame(at: 3).gazeTarget
        let fs = frames(face, from: 3, to: 13, hz: 30)
        for f in fs { XCTAssertEqual(f.gazeTarget, g); XCTAssertLessThan(f.blink, 0.01) }
        let ys = fs.map { $0.eyes[0].p0.y }
        XCTAssertGreaterThan(ys.max()! - ys.min()!, 0.004)
        XCTAssertLessThan(ys.max()! - ys.min()!, 0.04)
        XCTAssertFalse(face.isActive(at: 13))
    }

    // R3: the seven official moods plus yapa's own five, each with its own shape.
    func testR3_EveryMoodHasItsOwnPose() {
        let official: Set<String> = ["sleep", "idle", "busy", "attention", "celebrate", "dizzy", "heart"]
        let own: Set<String> = ["curious", "focused", "impatient", "proud", "bored"]
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

    // R5: the face wanders all over the screen, never past its edges, and stays put while asleep.
    func testR5_WandersTheWholeScreen() {
        let face = Face(seed: 11, now: 0)
        face.bounds = SIMD2(0.7, 0.35)
        let centres = frames(face, from: 0, to: 90, hz: 30).map { ($0.eyes[0].c + $0.eyes[1].c) / 2 }
        let xs = centres.map(\.x), ys = centres.map(\.y)
        XCTAssertGreaterThan(xs.max()! - xs.min()!, 0.7, "doesn't roam sideways")
        XCTAssertGreaterThan(ys.max()! - ys.min()!, 0.35, "doesn't roam up and down")
        XCTAssert(centres.allSatisfy { abs($0.x) < 0.8 && abs($0.y) < 0.45 }, "leaves the screen")
        face.set(.sleep, at: 90)
        let resting = frames(face, from: 93, to: 103, hz: 10).map { ($0.eyes[0].c.x + $0.eyes[1].c.x) / 2 }
        XCTAssertLessThan(resting.max()! - resting.min()!, 0.002, "wanders in its sleep")
    }

    // R6: curious steps closer to you and tilts its head like a dog, then to the other side if it stays curious.
    func testR6_CuriousLeansInAndTilts() {
        let face = Face(seed: 2, now: 0)
        face.set(.curious, at: 0)
        let fs = frames(face, from: 0, to: 8, hz: 30)
        XCTAssertGreaterThan(fs.last!.scale, 1.25, "doesn't step closer")
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
            XCTAssertLessThan(f.scale, 0.85, "\(m) doesn't step back")
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

    // R8: a fast-moving eye smears along its path like motion blur, and is round again at rest.
    func testR8_FastEyesSmear() {
        let s = Stroke(p0: .zero, c: .zero, p1: .zero, width: 0.06, smear: SIMD2(1.5, 0))
        let o = s.outline()
        let w = o.map(\.x).max()! - o.map(\.x).min()!, h = o.map(\.y).max()! - o.map(\.y).min()!
        XCTAssertGreaterThan(w, h * 1.4, "doesn't stretch along the motion")
        let still = Stroke(p0: .zero, c: .zero, p1: .zero, width: 0.06).outline()
        let ws = still.map(\.x).max()! - still.map(\.x).min()!
        XCTAssertEqual(ws, 0.06, accuracy: 0.002)
        let face = Face(seed: 11, now: 0)
        let speeds = frames(face, from: 0, to: 20, hz: 60).map { simd_length($0.eyes[0].smear) }
        XCTAssertGreaterThan(speeds.max()!, 0.3, "the face never moves fast enough to smear")
        XCTAssertLessThan(speeds.min()!, 0.02, "it never comes to rest")
    }

    // R8: moving sideways, the head leans into the direction it travels, and stands straight at rest.
    func testR8_LeansIntoMotion() {
        let face = Face(seed: 11, now: 0)
        let fs = frames(face, from: 0, to: 40, hz: 30)
        let fast = fs.filter { abs($0.eyes[0].smear.x) > 0.3 }
        XCTAssertGreaterThan(fast.count, 20, "never moves fast sideways")
        let leaning = fast.filter { $0.tilt * $0.eyes[0].smear.x > 0.0004 }
        XCTAssertGreaterThan(Double(leaning.count) / Double(fast.count), 0.8, "doesn't lean into the motion")
        let still = fs.filter { simd_length($0.eyes[0].smear) < 0.01 }
        XCTAssert(still.allSatisfy { abs($0.tilt) < 0.02 }, "leans while standing still")
    }

    // R8: stopping after a move squashes the eyes, then they stretch back, so the face lands with weight.
    func testR8_SquashesOnLanding() {
        let face = Face(seed: 11, now: 0)
        let fs = frames(face, from: 0, to: 40, hz: 60)
        func ratio(_ f: Frame) -> Double {
            let o = f.eyes[0].outline()
            return (o.map(\.y).max()! - o.map(\.y).min()!) / (o.map(\.x).max()! - o.map(\.x).min()!)
        }
        let rest = ratio(Face(seed: 11, now: 0, lively: false).frame(at: 1))
        var landings = 0, squashed = 0
        let speed = fs.map { simd_length($0.eyes[0].smear) }
        for i in 30..<fs.count where speed[i - 1] >= 0.1 && speed[i] < 0.1 && speed[(i - 30)..<i].max()! > 0.3 {
            landings += 1
            let window = fs[max(0, i - 20)..<min(fs.count, i + 20)]
            if window.contains(where: { ratio($0) < rest * 0.9 && $0.blink < 0.1 }) { squashed += 1 }
        }
        XCTAssertGreaterThan(landings, 3)
        XCTAssertGreaterThan(Double(squashed) / Double(landings), 0.7, "doesn't squash when it lands")
    }

    // R4: sleeping eyes are thin, wide arcs that curve down like closed lids, at the face's small scale.
    func testR4_SleepIsThinWideArc() {
        let e = Mood.sleep.pose.left
        XCTAssertEqual(e.ax, 0.05, accuracy: 1e-9)
        XCTAssertEqual(e.bend, -0.013, accuracy: 1e-9)
        XCTAssertEqual(e.width, 0.02, accuracy: 1e-9)
    }
}

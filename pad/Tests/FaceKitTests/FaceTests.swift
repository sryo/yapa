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

    // R1: changing mood flows: no frame moves an eye more than a sliver, and it settles within half a second.
    func testR1_MoodChangesFlowAndSettle() {
        for (a, b) in [(Mood.idle, Mood.celebrate), (.celebrate, .sleep), (.sleep, .attention), (.curious, .focused)] {
            let face = Face(seed: 1, now: 0, lively: false)
            face.set(a, at: 0)
            face.set(b, at: 1)
            let fs = frames(face, from: 1, to: 1.6, hz: 60)
            for (x, y) in zip(fs, fs.dropFirst()) { XCTAssertLessThan(jump(x, y), 0.03, "\(a)→\(b) jumps") }
            XCTAssertLessThan(face.pose(at: 1.6).distance(to: b.pose), 0.004, "\(a)→\(b) hasn't settled")
        }
    }

    // R1: changing mood mid-change continues from where the eyes are, with no jump.
    func testR1_RetargetHasNoJump() {
        let face = Face(seed: 1, now: 0, lively: false)
        face.set(.attention, at: 0)
        let before = face.frame(at: 0.0999)
        face.set(.celebrate, at: 0.1)
        XCTAssertLessThan(jump(before, face.frame(at: 0.1001)), 0.01)
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
                    let d = e.p1 - e.p0
                    XCTAssertLessThanOrEqual(min(abs(d.x), abs(d.y)), 0.025, "\(m) leans at \(d)")
                }
            }
            t += 0.7
        }
    }

    // R4: sleeping eyes are thin, wide arcs that curve down like closed lids, at the face's small scale.
    func testR4_SleepIsThinWideArc() {
        let e = Mood.sleep.pose.left
        XCTAssertEqual(e.ax, 0.05, accuracy: 1e-9)
        XCTAssertEqual(e.bend, -0.013, accuracy: 1e-9)
        XCTAssertEqual(e.width, 0.02, accuracy: 1e-9)
    }
}

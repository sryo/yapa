import XCTest
@testable import FaceKit

final class FaceTests: XCTestCase {
    // R1: moving between any two moods takes 120–300 ms, then holds the new pose.
    func testR1_TransitionsTake120To300ms() {
        for a in Mood.allCases {
            for b in Mood.allCases where a != b {
                let d = Face.transitionDuration(from: a.pose, to: b.pose)
                XCTAssert((0.12...0.30).contains(d), "\(a)→\(b): \(d) s")
            }
        }
        let face = Face(seed: 1, now: 0, lively: false)
        face.set(.attention, at: 0)
        let settled = face.frame(at: 1).pose
        XCTAssertLessThan(settled.distance(to: Mood.attention.pose), 0.001)
    }

    // R1: changing mood mid-transition continues from where the eyes are, with no jump.
    func testR1_RetargetHasNoJump() {
        let face = Face(seed: 1, now: 0, lively: false)
        face.set(.attention, at: 0)
        let before = face.frame(at: 0.0999).pose
        face.set(.heart, at: 0.1)
        let after = face.frame(at: 0.1001).pose
        XCTAssertLessThan(before.distance(to: after), 0.02)
    }

    // R1: expressions overshoot slightly before settling.
    func testR1_Overshoots() {
        let face = Face(seed: 1, now: 0, lively: false)
        let from = Mood.idle.pose.left.height, to = Mood.attention.pose.left.height
        face.set(.attention, at: 0)
        let peak = stride(from: 0.0, through: 0.4, by: 0.005).map { face.frame(at: $0).pose.left.height }
            .max(by: { abs($0 - from) < abs($1 - from) })!
        XCTAssertGreaterThan(abs(peak - from), abs(to - from) * 1.02)
        XCTAssertLessThan(abs(peak - from), abs(to - from) * 1.15)
    }

    // R2: blinks every 3–10 s and glances every 1–2.25 s, over ten simulated minutes.
    func testR2_BlinksAndGlancesOnSchedule() {
        let face = Face(seed: 42, now: 0)
        var blinks: [Double] = [], glances: [Double] = []
        var wasClosed = false, lastGaze = face.frame(at: 0).gazeTarget
        for i in 1...(600 * 60) {
            let t = Double(i) / 60, f = face.frame(at: t)
            let closed = f.blinkHeight < 0.5
            if closed && !wasClosed { blinks.append(t) }
            wasClosed = closed
            if f.gazeTarget != lastGaze { glances.append(t); lastGaze = f.gazeTarget }
        }
        XCTAssertGreaterThan(blinks.count, 55)
        XCTAssertGreaterThan(glances.count, 250)
        for (a, b) in zip(blinks, blinks.dropFirst()) { XCTAssert((2.95...10.05).contains(b - a), "blink gap \(b - a)") }
        for (a, b) in zip(glances, glances.dropFirst()) { XCTAssert((0.98...2.27).contains(b - a), "glance gap \(b - a)") }
    }

    // R2: a blink thins the eye to a sliver and widens it, closing faster than it opens.
    func testR2_BlinkThinsAndWidens() {
        let (h0, w0) = Face.blinkShape(at: 0.14)
        XCTAssertLessThan(h0, 0.06)
        XCTAssertGreaterThan(w0, 1.28)
        let closing = (0..<14).map { Face.blinkShape(at: Double($0) / 100).h }
        let opening = (14...34).map { Face.blinkShape(at: Double($0) / 100).h }
        XCTAssertEqual(closing, closing.sorted(by: >))
        XCTAssertEqual(opening, opening.sorted())
        XCTAssertEqual(Face.blinkShape(at: 0.34).h, 1, accuracy: 1e-9)
    }

    // R2: a fast glance squashes the eyes, then they recover.
    func testR2_GlanceSquashes() {
        let face = Face(seed: 7, now: 0)
        var minScale = 1.0
        for i in 1...(5 * 240) { minScale = min(minScale, face.frame(at: Double(i) / 240).squash) }
        XCTAssertLessThan(minScale, 0.95)
        XCTAssertGreaterThan(minScale, 0.70)
    }

    // R2: looking up makes the eyes bigger, looking down smaller.
    func testR2_LookChangesSize() {
        let e = Mood.idle.pose.left
        let up = Face.outline(e, inner: 1, gaze: SIMD2(0, -0.15)), down = Face.outline(e, inner: 1, gaze: SIMD2(0, 0.15))
        let span = { (o: [SIMD2<Double>]) in o.map(\.y).max()! - o.map(\.y).min()! }
        XCTAssertGreaterThan(span(up), span(down) * 1.1)
    }

    // R2: asleep, the eyes stay shut and don't wander.
    func testR2_SleepIsStill() {
        let face = Face(seed: 3, now: 0)
        face.set(.sleep, at: 0)
        let g = face.frame(at: 1).gazeTarget
        for i in 2...60 {
            let f = face.frame(at: Double(i))
            XCTAssertEqual(f.gazeTarget, g)
            XCTAssertGreaterThan(f.pose.left.lidTop, 0.85)
        }
        XCTAssertFalse(face.isActive(at: 60))
    }

    // R3: the seven official moods plus yapa's own five, each with its own pose.
    func testR3_EveryMoodHasItsOwnPose() {
        let official: Set<String> = ["sleep", "idle", "busy", "attention", "celebrate", "dizzy", "heart"]
        let own: Set<String> = ["curious", "focused", "impatient", "proud", "bored"]
        XCTAssertEqual(Set(Mood.allCases.map(\.rawValue)), official.union(own))
        let moods = Mood.allCases
        for (i, a) in moods.enumerated() {
            for b in moods[(i + 1)...] {
                XCTAssertGreaterThan(a.pose.distance(to: b.pose), 0.05, "\(a) and \(b) look the same")
            }
        }
    }

    // R4: happy eyes are ^ arcs: the bottom edge rises in the middle.
    func testR4_HappyEyesArc() {
        for m in [Mood.celebrate, .heart] {
            let o = Face.outline(m.pose.left, inner: 1, gaze: .zero)
            let bottom = o.filter { $0.y > 0 || abs($0.x) < 0.01 }
            let mid = o.filter { abs($0.x) < 0.02 }.map(\.y).max()!, edge = bottom.map(\.y).max()!
            XCTAssertLessThan(mid, edge - 0.05, "\(m) bottom isn't arched")
        }
    }

    // R4: an impatient eye's lid slopes down toward the nose; a bored one droops outward.
    func testR4_LidsSlant() {
        func topAt(_ m: Mood, _ x: Double) -> Double {
            let o = Face.outline(m.pose.left, inner: 1, gaze: .zero)
            return o.filter { abs($0.x - x) < 0.03 }.map(\.y).min()!
        }
        let w = Mood.idle.pose.left.width * 0.3
        XCTAssertGreaterThan(topAt(.impatient, w), topAt(.impatient, -w) + 0.02)
        XCTAssertGreaterThan(topAt(.bored, -w), topAt(.bored, w) + 0.02)
    }

    // R4: no mood, blink or glance turns an eye inside out.
    func testR4_OutlineNeverInverts() {
        for m in Mood.allCases {
            for b in stride(from: 0.0, through: 0.34, by: 0.02) {
                let s = Face.blinkShape(at: b)
                let o = Face.outline(m.pose.left, inner: 1, gaze: SIMD2(0.3, 0.15), blink: s)
                let n = o.count / 2
                for i in 0..<n {
                    XCTAssertLessThanOrEqual(o[i].y, o[o.count - 1 - i].y + 1e-9, "\(m) at blink \(b)")
                }
            }
        }
    }
}

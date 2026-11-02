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
            let closed = f.openness < 0.5
            if closed && !wasClosed { blinks.append(t) }
            wasClosed = closed
            if f.gazeTarget != lastGaze { glances.append(t); lastGaze = f.gazeTarget }
        }
        XCTAssertGreaterThan(blinks.count, 55)
        XCTAssertGreaterThan(glances.count, 250)
        for (a, b) in zip(blinks, blinks.dropFirst()) { XCTAssert((2.95...10.05).contains(b - a), "blink gap \(b - a)") }
        for (a, b) in zip(glances, glances.dropFirst()) { XCTAssert((0.98...2.27).contains(b - a), "glance gap \(b - a)") }
    }

    // R2: a fast glance squashes the eyes, then they recover.
    func testR2_GlanceSquashes() {
        let face = Face(seed: 7, now: 0)
        var minScale = 1.0
        for i in 1...(5 * 240) { minScale = min(minScale, face.frame(at: Double(i) / 240).squash) }
        XCTAssertLessThan(minScale, 0.95)
        XCTAssertGreaterThan(minScale, 0.75)
    }

    // R2: asleep, the eyes stay shut and don't wander.
    func testR2_SleepIsStill() {
        let face = Face(seed: 3, now: 0)
        face.set(.sleep, at: 0)
        let g = face.frame(at: 1).gazeTarget
        for i in 2...60 {
            let f = face.frame(at: Double(i))
            XCTAssertEqual(f.gazeTarget, g)
            XCTAssertLessThan(f.pose.left.open, 0.1)
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
}

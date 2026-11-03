import simd
import XCTest
@testable import JetaKit

final class CrowdTests: XCTestCase {
    func s(_ id: String, _ state: SessionState, events: Int = 1) -> SessionInfo { SessionInfo(id: id, name: "dir-\(id)", state: state, events: events) }


    // R1: each session's face shows its state: working is busy, needs you is attention, finished is proud and then
    // dozes, failed is dizzy, quiet is asleep.
    func testR1_MoodFollowsState() {
        let c = Crowd(seed: 1, now: 0)
        c.update([s("a", .working(reading: false)), s("b", .needs), s("c", .finished(at: 0)), s("d", .failed), s("e", .quiet)], at: 0)
        XCTAssertEqual(c.face("a")?.mood, .busy)
        XCTAssertEqual(c.face("b")?.mood, .attention)
        XCTAssertEqual(c.face("c")?.mood, .proud)
        XCTAssertEqual(c.face("d")?.mood, .dizzy)
        XCTAssertEqual(c.face("e")?.mood, .sleep)
        c.update([s("c", .finished(at: 0))], at: 6)
        XCTAssertEqual(c.face("c")?.mood, .idle, "proud for 5 s, then idle")
        c.update([s("c", .finished(at: 0))], at: 100)
        XCTAssertEqual(c.face("c")?.mood, .sleep, "dozing 90 s after that")
    }

    // R2: one session keeps today's single big face; two or more each get their own, in the order they started.
    func testR2_OneSessionIsTheSingleFace() {
        let c = Crowd(seed: 1, now: 0)
        c.update([s("a", .working(reading: false))], at: 0)
        XCTAssertTrue(c.single)
        c.update([s("a", .working(reading: false)), s("b", .quiet)], at: 1)
        XCTAssertFalse(c.single)
        XCTAssertEqual(c.slots(at: 3).map(\.id), ["a", "b"], "once they've grown in")
    }

    // R2: up to 6 faces sit in a row; past that the quiet ones fold into "+N", and one that needs you never does.
    func testR2_QuietOnesFoldPastSix() {
        let c = Crowd(seed: 1, now: 0)
        let all = (0..<9).map { s("q\($0)", .quiet) } + [s("w", .working(reading: true)), s("n", .needs)]
        c.update(all, at: 0)
        let shown = c.slots(at: 2).map(\.id)
        XCTAssertEqual(shown.count, Crowd.most)
        XCTAssertTrue(shown.contains("w") && shown.contains("n"))
        XCTAssertEqual(c.overflow, 11 - Crowd.most)
    }

    // R2: a session that needs you steps forward, bigger and in the middle; a tap can bring another one forward.
    func testR2_NeedsYouStepsForward() {
        let c = Crowd(seed: 1, now: 0)
        c.update([s("a", .working(reading: false)), s("b", .quiet), s("c", .needs), s("d", .needs)], at: 0)
        XCTAssertEqual(c.front, "c", "the first to need you")
        let settled = c.slots(at: 3)
        let front = settled.first { $0.id == "c" }!, other = settled.first { $0.id == "a" }!
        XCTAssertTrue(front.front)
        XCTAssertGreaterThan(front.scale, other.scale * 1.5)
        XCTAssertLessThan(simd_length(front.centre), simd_length(other.centre))
        c.focus("d", at: 3)
        XCTAssertEqual(c.front, "d")
        c.update([s("a", .working(reading: false)), s("b", .quiet), s("c", .working(reading: false)), s("d", .working(reading: false))], at: 4)
        XCTAssertNil(c.front, "nobody needs you: nobody stands forward")
    }

    // R2: faces never jump, whatever comes and goes, and the group drifts so nothing burns in. Passing over each other
    // now and then is fine (sryo: "it's playful"); bench/jeta-crowd counts how often.
    func testR2_NoJumpsAndDrifts() {
        let c = Crowd(seed: 7, now: 0)
        var ids: [String] = [], states: [String: SessionState] = [:], rng = SplitMix(3)
        var last: [String: SIMD2<Double>] = [:], worst = 0.0
        for frame in 0..<(60 * 120) {
            let t = Double(frame) / 60
            if frame % 90 == 0 {
                // Every 1.5 s something happens: a session starts, ends, or changes state.
                let roll = rng.next(in: 0...1)
                if roll < 0.3 || ids.count < 2 { let id = "s\(frame)"; ids.append(id); states[id] = .working(reading: false) }
                else if roll < 0.45, ids.count > 2 { states[ids.removeFirst()] = nil }
                else if !ids.isEmpty { let id = ids[Int(rng.next(in: 0...0.999) * Double(ids.count))]
                    states[id] = [.needs, .working(reading: true), .finished(at: t), .failed, .quiet][Int(rng.next(in: 0...4.99))]
                }
                c.update(ids.map { s($0, states[$0]!, events: frame) }, at: t)
            }
            for slot in c.slots(at: t) {
                if let p = last[slot.id] { worst = max(worst, simd_length(slot.centre - p)) }
                last[slot.id] = slot.centre
            }
        }
        XCTAssertLessThan(worst, 0.05, "the most a face's place moved in one frame at 60 fps")
        let d = Crowd(seed: 2, now: 0)
        d.update([s("a", .quiet), s("b", .quiet)], at: 0)
        let start = d.slots(at: 2)[0].centre
        XCTAssertGreaterThan(simd_length(d.slots(at: 300)[0].centre - start), 0.01, "the group drifts")
    }

    // R3: a swiped-away face hides until its session's next event; a tap finds the face under the finger.
    func testR3_HideUntilNextEventAndHit() {
        let c = Crowd(seed: 1, now: 0)
        c.update([s("a", .quiet, events: 1), s("b", .quiet, events: 1), s("c", .quiet, events: 1)], at: 0)
        let b = c.slots(at: 2).first { $0.id == "b" }!
        XCTAssertEqual(c.hit(b.centre, at: 2), "b")
        XCTAssertNil(c.hit(SIMD2(5, 5), at: 2))
        c.hide("b", at: 2)
        c.update([s("a", .quiet, events: 1), s("b", .quiet, events: 1), s("c", .quiet, events: 1)], at: 3)
        XCTAssertFalse(c.slots(at: 3).contains { $0.id == "b" })
        c.update([s("a", .quiet, events: 1), s("b", .working(reading: false), events: 2), s("c", .quiet, events: 1)], at: 4)
        XCTAssertTrue(c.slots(at: 6).contains { $0.id == "b" }, "its next event brings it back, growing in")
    }
}

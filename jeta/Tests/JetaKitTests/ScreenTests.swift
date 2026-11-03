import XCTest
@testable import JetaKit

final class ScreenTests: XCTestCase {
    func board(_ lines: String...) -> NoticeBoard {
        var b = NoticeBoard()
        for l in lines { b.take(["evt": "turn", "role": "assistant", "content": [["type": "text", "text": l]]]) }
        return b
    }

    // R4: a session's question takes over from the bare face: who needs you and what, in one line each, plus a hint.
    func testR4_QuestionShowsWhoAndWhat() {
        var s = Screen()
        s.update(board("jeta: server needs you · Which hostname for the tunnel?"))
        XCTAssertEqual(s.mode, .question)
        XCTAssertEqual(s.lines(width: 40).map(\.text), ["server needs you", "Which hostname for the tunnel?", "tap more · hold to answer"])
        s.update(board("jeta: server needs you · x", "jeta: clear server"))
        XCTAssertEqual(s.mode, .face, "the question stays after it's cleared")
    }

    // R5: a tap opens the detail (wrapped, with a page count when several sessions wait); a swipe moves to the next;
    // another tap closes it back to the question.
    func testR5_DetailPagesAndCloses() {
        var s = Screen()
        s.update(board("jeta: che needs you · Merge the branch now that every check passes and the phone runs it?",
                       "jeta: server needs you · Which hostname?"))
        s.tap()
        XCTAssertEqual(s.mode, .detail)
        let first = s.lines(width: 30)
        XCTAssertEqual(first.first?.text, "server · waiting on you")
        XCTAssertTrue(first.contains { $0.text == "1 / 2" })
        s.swipe()
        let second = s.lines(width: 30).map(\.text)
        XCTAssertEqual(second.first, "che · waiting on you")
        XCTAssertGreaterThan(second.filter { !$0.isEmpty }.count, 3, "long questions don't wrap")
        XCTAssert(second.allSatisfy { $0.count <= 30 }, "a line is wider than the screen")
        s.tap()
        XCTAssertEqual(s.mode, .question)
    }

    // R6: a long press on the bare face opens the session list; a tap closes it. Nothing else does: no mood demo.
    func testR6_LongPressShowsTheSessions() {
        var s = Screen()
        s.update(board("jeta: list · server needs you; bluetooth working; che done"))
        XCTAssertEqual(s.mode, .face)
        s.longPress()
        XCTAssertEqual(s.mode, .roster)
        XCTAssertEqual(Array(s.lines(width: 40).map(\.text).prefix(3)), ["server · needs you", "bluetooth · working", "che · done"])
        s.tap()
        XCTAssertEqual(s.mode, .face)
    }

    // R6: with a question, detail or list open, holding is for talking, not for the list.
    func testR6_HoldIsForTalkingWhenSomethingIsOpen() {
        var s = Screen()
        s.update(board("jeta: server needs you · Which hostname?"))
        XCTAssertEqual(s.longPress(), .talk(to: "server"))
        XCTAssertEqual(s.mode, .question)
        s.tap(); XCTAssertEqual(s.longPress(), .talk(to: "server"))
        var r = Screen(); r.update(board("jeta: list · che done")); r.longPress()
        XCTAssertEqual(r.longPress(), .talk(to: nil), "in the list, holding talks to the manager")
    }

    // R9: a question with options shows them as buttons; choosing one gives the line to send the manager.
    func testR9_ChoosingAnOption() {
        var s = Screen()
        s.update(board("jeta: server needs you · Which port? · 8080 | 8443"))
        let lines = s.lines(width: 40)
        XCTAssertEqual(lines.filter { $0.style == .option }.map(\.text), ["8080", "8443"])
        XCTAssertEqual(lines.last?.text, "tap an option · hold to answer")
        XCTAssertEqual(s.choose(1), "server: 8443")
        XCTAssertNil(s.choose(2))
        s.tap()
        XCTAssertEqual(s.lines(width: 40).filter { $0.style == .option }.count, 2, "the detail drops the options")
    }

    // R10: with a question showing under it, the face rises into the top half, clear of the text, even mid-lunge.
    func testR10_FaceRisesAboveAQuestion() {
        let face = Face(seed: 1, now: 0)
        face.screen = SIMD2(0.89, 0.5)
        face.set(.attention, at: 1)
        face.lift(true, at: 1)
        for t in stride(from: 1.5, through: 4.0, by: 0.1) {
            let f = face.frame(at: t)
            let bottom = f.eyes.flatMap { $0.outline() }.map(\.y).max()!
            XCTAssertLessThan(bottom, 0.08, "the eyes reach into the text at t=\(t)")
        }
        face.lift(false, at: 4)
        let g = face.frame(at: 6), c = (g.eyes[0].middle + g.eyes[1].middle) / 2
        XCTAssertGreaterThan(c.y, -0.15, "doesn't come back down")
    }

    // R7: when text is up the face steps aside to the top-left corner, smaller, and comes back when it closes.
    func testR7_FaceStepsAside() {
        let face = Face(seed: 1, now: 0)
        face.screen = SIMD2(0.89, 0.5)
        face.aside(true, at: 1)
        let f = face.frame(at: 3), c = (f.eyes[0].middle + f.eyes[1].middle) / 2
        XCTAssertLessThan(c.x, -0.6); XCTAssertLessThan(c.y, -0.3)
        for e in f.eyes { XCTAssert(e.outline().allSatisfy { abs($0.x) < 0.89 && abs($0.y) < 0.5 }, "the face steps off the screen") }
        XCTAssertLessThan(f.scale, 0.75)
        face.aside(false, at: 3)
        let g = face.frame(at: 5), d = (g.eyes[0].middle + g.eyes[1].middle) / 2
        XCTAssertGreaterThan(d.x, -0.5)
        XCTAssertGreaterThan(g.scale, 0.9)
    }
}

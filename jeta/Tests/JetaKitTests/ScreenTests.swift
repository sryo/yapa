import XCTest
import simd
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
        XCTAssertEqual(s.lines(width: 40).map(\.text), ["server needs you", "Which hostname for the tunnel?", "tap more · hold: answer"])
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

    // R6: a swipe down on the bare face opens the session list; a tap closes it. Nothing else does: no mood demo.
    func testR6_SwipeDownShowsTheSessions() {
        var s = Screen()
        s.update(board("jeta: list · server needs you; bluetooth working; che done"))
        XCTAssertEqual(s.mode, .face)
        s.swipeDown()
        XCTAssertEqual(s.mode, .roster)
        XCTAssertEqual(Array(s.lines(width: 40).map(\.text).prefix(3)), ["server · needs you", "bluetooth · working", "che · done"])
        s.tap()
        XCTAssertEqual(s.mode, .face)
    }

    // R6: with a question or its detail up, a swipe down leaves it where it is.
    func testR6_SwipeDownOnlyOpensTheListFromTheFace() {
        var s = Screen()
        s.update(board("jeta: server needs you · Which hostname?"))
        s.swipeDown(); XCTAssertEqual(s.mode, .question)
        s.tap(); s.swipeDown(); XCTAssertEqual(s.mode, .detail)
    }

    // R9: a question with options shows them as buttons; choosing one gives the line to send the manager.
    func testR9_ChoosingAnOption() {
        var s = Screen()
        s.update(board("jeta: server needs you · Which port? · 8080 | 8443"))
        let lines = s.lines(width: 40)
        // The first option is the suggested one: it stands out; the rest are plain.
        XCTAssertEqual(lines.filter { $0.style == .suggestion }.map(\.text), ["8080"])
        XCTAssertEqual(lines.filter { $0.style == .option }.map(\.text), ["8443"])
        XCTAssertEqual(lines.last?.text, "tap one, or hold to answer")
        XCTAssertEqual(s.choose(1), "server: 8443")
        XCTAssertNil(s.choose(2))
        s.tap()
        XCTAssertEqual(s.lines(width: 40).filter { $0.style == .option || $0.style == .suggestion }.count, 2, "the detail drops the options")
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

    // R3: tapping a session's face opens that session's question, if it has one.
    func testR3_ShowASessionsQuestion() {
        var s = Screen()
        s.update(board("jeta: server needs you · Which hostname?", "jeta: che needs you · Keep the old build?"))
        XCTAssertTrue(s.show(session: "che"))
        XCTAssertEqual(s.mode, .question)
        XCTAssertEqual(s.lines(width: 40).first?.text, "che needs you")
        XCTAssertFalse(s.show(session: "docs"), "no question for it: nothing opens")
    }

    // R10: a permission request shows who asks and what, with Allow and Deny, ahead of any question; once answered
    // the question underneath comes back. Swiping doesn't page past it, and its answer isn't a line for a session.
    func testR10_PermissionShowsItsButtons() {
        var s = Screen()
        s.update(board("jeta: server needs you · Which hostname?"))
        s.ask(session: "yapa", "Bash: git push")
        let lines = s.lines(width: 40)
        XCTAssertEqual(lines.first?.text, "yapa asks")
        XCTAssertEqual(lines.filter { $0.style == .suggestion || $0.style == .option }.map(\.text), ["Allow", "Deny"])
        XCTAssertTrue(lines.contains { $0.text == "Bash: git push" })
        XCTAssertNil(s.asker)
        s.swipe(); XCTAssertEqual(s.lines(width: 40).first?.text, "yapa asks")
        s.answered()
        XCTAssertEqual(s.lines(width: 40).first?.text, "server needs you")
        var f = Screen(); f.ask(session: "yapa", "Read: x"); XCTAssertEqual(f.mode, .question)
        f.answered(); XCTAssertEqual(f.mode, .face)
    }

    func testR10_QuestionsStepWithBoxes() {
        var s = Screen()
        s.ask(Asked(id: "1", session: "yapa", tool: "AskUserQuestion", text: "", questions: [
            .init(question: "Color?", header: "Color", options: ["red", "blue"], multi: false),
            .init(question: "Parts?", header: "Parts", options: ["a", "b", "c"], multi: true)]))
        XCTAssertEqual(s.asking?.options, ["red", "blue", "At the Mac"])
        XCTAssertEqual(s.pick(1), .more)
        XCTAssertEqual(s.asking?.options, ["○ a", "○ b", "○ c", "Done", "At the Mac"])
        XCTAssertEqual(s.pick(0), .more)
        XCTAssertEqual(s.pick(2), .more)
        XCTAssertEqual(s.asking?.options, ["✓ a", "○ b", "✓ c", "Done", "At the Mac"])
        XCTAssertEqual(Screen.options(s.asking!).map(\.style), [.suggestion, .option, .suggestion, .option, .option])
        XCTAssertEqual(s.pick(3), .answer(["Color?": "blue", "Parts?": "a, c"]))
    }

    // A reply says how long ago it came in, under the session's name, in steps coarse enough not to tick while read.
    func testReplySaysHowLongAgo() {
        var s = Screen()
        s.update(replies: [Reply(id: "a", session: "yapa", text: "Done.", at: 100)])
        s.read(session: "a")
        for (now, ago) in [(130.0, "just now"), (300.0, "3 min ago"), (7360.0, "2 h ago"), (259300.0, "3 days ago")] as [(Double, String)] {
            s.now = now
            XCTAssertEqual(s.lines(width: 40).first?.text, "yapa · \(ago)")
        }
    }

    // All text drifts together, slowly enough to read through (under 0.25 pt/s, never more than 15 pt off) and never
    // stopping, so no line sits on the same pixels for long.
    func testTextDriftsSoNoLineSitsStill() {
        var s = Screen()
        s.update(board("jeta: server needs you · Use port 8080 or 8443? · 8443 | 8080"))
        s.now = 0
        let still = s.place(width: 568, height: 320).map { SIMD2($0.x, $0.y) - s.drift }
        for t in stride(from: 0.0, through: 7200, by: 7) {
            s.now = t
            let d = s.drift
            XCTAssertLessThanOrEqual(simd_length(d), 15)
            for (a, b) in zip(s.place(width: 568, height: 320).map { SIMD2($0.x, $0.y) - d }, still) {
                XCTAssertLessThan(simd_distance(a, b), 1e-9, "every line moves with the drift")
            }
            s.now = t + 15
            XCTAssertGreaterThan(simd_distance(s.drift, d), 1, "at \(t) s the text sat still for 15 s")
            s.now = t + 1
            XCTAssertLessThan(simd_distance(s.drift, d), 0.25)
        }
    }

    // Text left up three minutes with nobody touching the pad goes back into its ant: a reply, the session list or a
    // question's detail closes, and a question folds until a new one comes or a tap brings it back. A permission
    // request stays, since only its buttons answer it.
    func testUntouchedTextFoldsAway() {
        var s = Screen()
        s.update(replies: [Reply(id: "a", session: "yapa", text: "Done.", at: 0)])
        s.read(session: "a")
        s.now = 10; s.idle()
        s.now = 150; s.idle()
        XCTAssertEqual(s.mode, .reply)
        s.now = 191; s.idle()
        XCTAssertEqual(s.mode, .face)

        let b = board("jeta: server needs you · Which hostname?")
        s.update(b); s.tap(); s.idle()
        XCTAssertEqual(s.mode, .detail)
        s.now = 300; s.idle()
        XCTAssertEqual(s.mode, .detail)
        s.attend(); s.now = 470; s.idle()
        XCTAssertEqual(s.mode, .detail)
        s.now = 500; s.idle()
        XCTAssertEqual(s.mode, .face)
        s.update(b)
        XCTAssertEqual(s.mode, .face, "the same question stays folded")
        XCTAssertTrue(s.unfold())
        XCTAssertEqual(s.mode, .question)
        XCTAssertFalse(s.unfold())
        s.idle()
        s.now = 700; s.idle()
        XCTAssertEqual(s.mode, .face)
        s.update(board("jeta: server needs you · Which hostname?", "jeta: che needs you · Merge it?"))
        XCTAssertEqual(s.mode, .question, "a new question comes up")

        s.ask(session: "che", "Bash: ls")
        s.now = 2000; s.idle()
        XCTAssertEqual(s.mode, .question, "a permission request stays")
        XCTAssertFalse(s.resting)
    }

    // The pad rests (the backlight dims) once nobody has touched it for three minutes and nothing needs you.
    func testRestsOnlyWhenNothingNeedsYou() {
        var s = Screen()
        s.now = 100; s.idle()
        XCTAssertFalse(s.resting)
        s.now = 290; s.idle()
        XCTAssertTrue(s.resting)
        s.attend()
        XCTAssertFalse(s.resting)
        s.now = 480; s.idle()
        XCTAssertTrue(s.resting)
        s.update(board("jeta: server needs you · Which hostname?"))
        XCTAssertFalse(s.resting, "a question wakes it")
    }
}

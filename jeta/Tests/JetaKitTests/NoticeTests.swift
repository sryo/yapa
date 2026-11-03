import XCTest
@testable import JetaKit

final class NoticeTests: XCTestCase {
    func text(_ s: String, role: String = "assistant") -> [String: Any] {
        ["evt": "turn", "role": role, "content": [["type": "text", "text": s]]]
    }
    func echo(_ cmd: String) -> [String: Any] {
        ["evt": "turn", "role": "assistant", "content": [["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": cmd]]]]
    }

    // R1: it picks the manager's `jeta:` lines out of any session's turn events, from text or from an echo in a
    // tool call (when the app strips text), and ignores everything else, including talk about the format.
    func testR1_PicksOnlyManagerLines() {
        XCTAssertEqual(NoticeBoard.lines(in: text("Done.\njeta: server needs you · Which hostname?\nThanks")),
                       ["jeta: server needs you · Which hostname?"])
        XCTAssertEqual(NoticeBoard.lines(in: echo("echo 'jeta: che needs you · Merge the branch?'")),
                       ["jeta: che needs you · Merge the branch?"])
        XCTAssertEqual(NoticeBoard.lines(in: echo("echo \"jeta: clear che\"")), ["jeta: clear che"])
        XCTAssertEqual(NoticeBoard.lines(in: text("The format is a line like jeta: server needs you · x")), [])
        XCTAssertEqual(NoticeBoard.lines(in: text("jeta: server needs you · x", role: "user")), [])
        XCTAssertEqual(NoticeBoard.lines(in: echo("grep 'jeta:' notes.txt")), [])
        XCTAssertEqual(NoticeBoard.lines(in: ["evt": "turn", "role": "assistant", "content": "oops"]), [])
    }

    // R2: it understands the three forms (needs, list, clear) and ignores anything malformed.
    func testR2_ParsesTheThreeForms() {
        XCTAssertEqual(NoticeBoard.parse("jeta: server needs you · Which hostname?"), .needs("server", "Which hostname?"))
        XCTAssertEqual(NoticeBoard.parse("jeta: list · server needs you; bluetooth working; che done"),
                       .list([Roster(session: "server", state: "needs you"), Roster(session: "bluetooth", state: "working"),
                              Roster(session: "che", state: "done")]))
        XCTAssertEqual(NoticeBoard.parse("jeta: clear server"), .clear("server"))
        for bad in ["jeta:", "jeta: server needs you", "jeta: needs you · x", "jeta: list ·", "jeta: clear", "jeta: hello"] {
            XCTAssertNil(NoticeBoard.parse(bad), bad)
        }
    }

    // R3: it keeps the latest question per session, newest first; clear removes it; a list replaces the roster and
    // a needs line marks that session in it.
    func testR3_KeepsLatestPerSession() {
        var board = NoticeBoard()
        board.take(text("jeta: server needs you · Which hostname?"))
        board.take(text("jeta: che needs you · Merge?"))
        board.take(text("jeta: server needs you · Which hostname, again?"))
        XCTAssertEqual(board.pending, [Notice(session: "server", text: "Which hostname, again?"), Notice(session: "che", text: "Merge?")])
        board.take(echo("echo 'jeta: clear server'"))
        XCTAssertEqual(board.pending, [Notice(session: "che", text: "Merge?")])
        board.take(text("jeta: list · che working; server done"))
        XCTAssertEqual(board.roster, [Roster(session: "che", state: "working"), Roster(session: "server", state: "done")])
        board.take(text("jeta: server needs you · One more thing"))
        XCTAssertEqual(board.roster.first { $0.session == "server" }?.state, "needs you")
    }

    // R8: every example in the manager's instructions parses here, and covers the three forms, so the instructions
    // and the phone never drift apart.
    func testR8_ManagerSkillExamplesParse() throws {
        let skill = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../.claude/skills/jeta-manager/SKILL.md")
        let lines = try String(contentsOf: skill, encoding: .utf8).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("jeta:") }
        XCTAssertGreaterThanOrEqual(lines.count, 3)
        let parsed = lines.map { NoticeBoard.parse($0) }
        XCTAssert(parsed.allSatisfy { $0 != nil }, "an example in the skill doesn't parse: \(zip(lines, parsed).filter { $1 == nil }.map(\.0))")
        XCTAssert(parsed.contains { if case .needs? = $0 { return true }; return false })
        XCTAssert(parsed.contains { if case .list? = $0 { return true }; return false })
        XCTAssert(parsed.contains { if case .clear? = $0 { return true }; return false })
    }

    // R9: a question can offer options after a second dot, split by bars; a single option isn't a choice.
    func testR9_ParsesOptions() {
        XCTAssertEqual(NoticeBoard.parse("jeta: server needs you · Which port? · 8080 | 8443"),
                       .choose("server", "Which port?", ["8080", "8443"]))
        XCTAssertNil(NoticeBoard.parse("jeta: server needs you · Which port? · 8080"))
        var board = NoticeBoard()
        board.take(text("jeta: server needs you · Which port? · 8080 | 8443 | none"))
        XCTAssertEqual(board.pending, [Notice(session: "server", text: "Which port?", options: ["8080", "8443", "none"])])
    }

    // R3: raw bytes from the Bluetooth link work too, and a broken event is skipped.
    func testR3_TakesRawEvents() {
        var board = NoticeBoard()
        board.take(Data(#"{"evt":"turn","role":"assistant","content":[{"type":"text","text":"jeta: che needs you · Ready?"}]}"#.utf8))
        board.take(Data("{not json".utf8))
        XCTAssertEqual(board.pending, [Notice(session: "che", text: "Ready?")])
    }
}

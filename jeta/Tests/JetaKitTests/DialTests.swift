import XCTest
@testable import JetaKit

final class DialTests: XCTestCase {
    let root = [
        Dial.Item("new session", children: [Dial.Item("yapa", "~/Documents/yapa", act: "new:/u/yapa"), Dial.Item("fium", act: "new:/u/fium")]),
        Dial.Item("server", children: [Dial.Item("hello", "up · api.example.com", children: [Dial.Item("turn off", act: "part:hello:off")])]),
        Dial.Item("disk", "3.2 GB free"),
    ]

    // R1: it opens on its first level, turns a word at a time and stops at either end.
    func testR1_OpensAndTurns() {
        var d = Dial(); d.root = root
        XCTAssertTrue(d.place(width: 568, height: 320).isEmpty, "closed, it draws nothing")
        d.begin(at: 0)
        XCTAssertEqual(d.current?.title, "new session")
        d.turn(1, at: 0); XCTAssertEqual(d.current?.title, "server")
        d.turn(5, at: 0); XCTAssertEqual(d.current?.title, "disk")
        d.turn(-9, at: 0); XCTAssertEqual(d.current?.title, "new session")
    }

    // R1: letting go on a word with something under it opens it on its first real word, after "back"; on an act it
    // gives the act; back goes up to the word it came from.
    func testR1_OpensActsAndGoesBack() {
        var d = Dial(); d.root = root
        d.begin(at: 0)
        d.turn(1, at: 0)
        XCTAssertEqual(d.release(at: 0), .opened)
        XCTAssertEqual(d.level.map(\.title), ["back", "hello"])
        XCTAssertEqual(d.current?.title, "hello")
        XCTAssertEqual(d.release(at: 0), .opened)
        XCTAssertEqual(d.release(at: 0), .act("part:hello:off"))
        d.turn(-1, at: 0); XCTAssertEqual(d.release(at: 0), .back)
        XCTAssertEqual(d.current?.title, "hello")
        d.turn(-1, at: 0); XCTAssertEqual(d.release(at: 0), .back)
        XCTAssertEqual(d.current?.title, "server")
        d.turn(1, at: 0); XCTAssertEqual(d.release(at: 0), .nothing, "a word that only says something does nothing")
    }

    // R1: the word it's on sits in the middle, biggest and bold, with what it is under it; its neighbours are
    // smaller and dimmer, and each line is keyed by its words so turning glides them.
    func testR1_Typography() {
        var d = Dial(); d.root = root
        d.begin(at: 0); d.turn(1, at: 0)
        let p = d.place(width: 568, height: 320)
        let server = p.first { $0.text == "server" }!, new = p.first { $0.text == "new session" }!
        XCTAssertTrue(server.bold)
        XCTAssertEqual(server.y + server.height / 2, 160, accuracy: 1)
        XCTAssertLessThan(new.y, server.y)
        XCTAssertLessThan(new.scale, server.scale)
        XCTAssertLessThan(new.opacity, server.opacity)
        d.turn(1, at: 0)
        let q = d.place(width: 568, height: 320)
        XCTAssertEqual(Set(p.filter { !$0.key.hasPrefix("dial-detail") }.map(\.key)), Set(q.filter { !$0.key.hasPrefix("dial-detail") }.map(\.key)),
                       "the same words, moved")
        XCTAssertTrue(q.contains { $0.text == "3.2 GB free" }, "what it's on is said under it")
    }

    // R1: the first level rebuilt under it (a part went down) keeps it where it was; left alone, it closes.
    func testR1_RebuiltAndUnattended() {
        var d = Dial(); d.root = root
        d.begin(at: 0); d.turn(1, at: 0); _ = d.release(at: 0)
        d.root[1].children![0].detail = "down"
        XCTAssertEqual(d.current?.detail, "down")
        d.idle(at: Dial.unattended - 1); XCTAssertTrue(d.isOpen)
        d.idle(at: Dial.unattended + 1); XCTAssertFalse(d.isOpen)
    }

    // R1: twisting between steps rolls the words that far toward the next, so it reads as a dial from the first
    // degree; past the last word they give only a little.
    func testR1_WordsRollWithTheTwist() {
        var d = Dial(); d.root = root
        d.begin(at: 0); d.turn(1, at: 0)
        let y = { (p: [Placed], t: String) in p.first { $0.text == t }!.y }
        let rest = d.place(width: 568, height: 320), half = d.place(width: 568, height: 320, turn: 0.5)
        XCTAssertLessThan(y(half, "server"), y(rest, "server"), "turning toward the next word moves them up")
        XCTAssertLessThan(y(half, "disk"), y(rest, "disk"))
        XCTAssertGreaterThan(y(half, "disk"), y(rest, "server"), "but not past a step")
        d.turn(1, at: 0)
        let last = d.place(width: 568, height: 320), past = d.place(width: 568, height: 320, turn: 0.9)
        XCTAssertLessThan(abs(y(past, "disk") - y(last, "disk")), abs(y(half, "server") - y(rest, "server")))
    }
}


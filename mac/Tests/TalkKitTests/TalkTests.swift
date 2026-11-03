import XCTest
@testable import TalkKit

final class TalkTests: XCTestCase {
    // R1: word error rate counts substitutions, insertions and deletions over the reference's words,
    // ignoring case, accents and punctuation.
    func testR1_WordErrorRate() {
        XCTEqual(wordErrorRate(reference: "Run the tests, please.", hypothesis: "run the tests please"), 0)
        XCTEqual(wordErrorRate(reference: "run the tests please", hypothesis: "run a tests"), 0.5)
        XCTEqual(wordErrorRate(reference: "sí, dale", hypothesis: "Sí dale"), 0)
        XCTEqual(wordErrorRate(reference: "Revisá esta función", hypothesis: "revisa esta funcion"), 0)
        XCTEqual(wordErrorRate(reference: "yes", hypothesis: ""), 1)
    }

    // R1: of the English and Spanish hearings, the more confident one wins; an empty one never does.
    func testR1_PicksTheLanguageHeardBest() {
        let en = Heard(lang: "en_US", text: "ship it", confidence: 0.9)
        let es = Heard(lang: "es_ES", text: "chip it", confidence: 0.4)
        XCTAssertEqual(pick([es, en])?.lang, "en_US")
        XCTAssertEqual(pick([Heard(lang: "en_US", text: " ", confidence: 1), es])?.lang, "es_ES")
        XCTAssertNil(pick([]))
    }

    // R2: the agent reads a whole POST from bytes that may arrive in pieces.
    func testR2_ParsesARequestOnlyOnceItIsWhole() {
        let head = "POST /talk HTTP/1.1\r\nHost: yapa\r\nContent-Length: 4\r\n\r\n"
        XCTAssertNil(Request(Data((head + "ab").utf8)))
        let r = Request(Data((head + "abcd").utf8))
        XCTAssertEqual(r?.method, "POST")
        XCTAssertEqual(r?.path, "/talk")
        XCTAssertEqual(r?.body, Data("abcd".utf8))
        XCTAssertEqual(Request(Data("POST /cancel HTTP/1.1\r\n\r\n".utf8))?.path, "/cancel")
    }

    // R3: text goes to a terminal or Claude in front; else straight to the Claude app behind; else the clipboard.
    func testR3_RoutesToClaudeOrATerminalNeverElsewhere() {
        XCTAssertEqual(route(frontmost: "com.apple.Terminal", claude: 7), .typeFrontmost)
        XCTAssertEqual(route(frontmost: "com.mitchellh.ghostty", claude: nil), .typeFrontmost)
        XCTAssertEqual(route(frontmost: claudeBundle, claude: 7), .typeFrontmost)
        XCTAssertEqual(route(frontmost: "com.apple.Safari", claude: 7), .sendTo(7))
        XCTAssertEqual(route(frontmost: "com.apple.Safari", claude: nil), .clipboard)
    }

    // R2: only this Mac and the hosts named in CHE_FROM may post, since what they send gets typed into Claude.
    func testR2_OnlyListedHostsMayTalk() {
        XCTAssertTrue(allowed("127.0.0.1", from: []))
        XCTAssertTrue(allowed("::1", from: []))
        XCTAssertTrue(allowed("192.168.1.8", from: ["192.168.1.8"]))
        XCTAssertTrue(allowed("::ffff:192.168.1.8", from: ["192.168.1.8"]))
        XCTAssertFalse(allowed("192.168.1.9", from: ["192.168.1.8"]))
        XCTAssertFalse(allowed("192.168.1.80", from: ["192.168.1.8"]))
    }

    // R3: Enter follows the text after the timeout unless cancelled first.
    func testR3_EnterAfterATimeoutUnlessCancelled() {
        var sent = 0
        let enter = PendingEnter(after: 0.1) { sent += 1 }
        enter.arm()
        RunLoop.main.run(until: Date() + 0.2)
        XCTAssertEqual(sent, 1)
        enter.arm()
        XCTAssertTrue(enter.cancel())
        RunLoop.main.run(until: Date() + 0.2)
        XCTAssertEqual(sent, 1)
        XCTAssertFalse(enter.cancel())
    }

    // R5: /say types a picked option as is; a stray newline must not press Return early, and junk types nothing.
    func testR5_SayTakesUTF8Text() {
        XCTAssertEqual(said(Data("server: 8443".utf8)), "server: 8443")
        XCTAssertEqual(said(Data("Sí, dale\n".utf8)), "Sí, dale")
        XCTAssertNil(said(Data(" \n".utf8)))
        XCTAssertNil(said(Data([0xff, 0xfe])))
    }
}

func XCTEqual(_ a: Double, _ b: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a, b, accuracy: 1e-9, file: file, line: line)
}

final class TranscribeTests: XCTestCase {
    // R1: a fixture clip, in each language, comes back as its reference text with the right language picked.
    func testR1_HearsAFixtureClipInEitherLanguage() async throws {
        let clips = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../bench/clips")
        let t = Transcriber(["en_US", "es_ES"])
        try await t.prepare()
        for (clip, lang) in [("01", "en_US"), ("07", "es_ES")] {
            let ref = try String(contentsOf: clips.appendingPathComponent("\(clip).txt"), encoding: .utf8)
            let heard = try await t.hear(clips.appendingPathComponent("\(clip).wav"))
            let h = try XCTUnwrap(pick(heard))
            XCTAssertEqual(h.lang, lang, h.text)
            XCTAssertLessThanOrEqual(wordErrorRate(reference: ref, hypothesis: h.text), 0.25, h.text)
        }
    }
}

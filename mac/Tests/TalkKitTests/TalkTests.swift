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
        let clips = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../bench/che-clips")
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

    // R2: the pad names the session a face stands for; che finds the Claude app's id for it, skipping archived ones,
    // and none for a session the app doesn't have (a terminal's).
    func testR2_TalkReachesTheFacesSession() throws {
        XCTAssertEqual(query("/talk?dry&session=ab%2Dc"), ["dry": "", "session": "ab-c"])
        XCTAssertEqual(query("/say"), [:])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func file(_ id: String, _ cli: String, archived: Bool = false) throws {
            let o: [String: Any] = ["sessionId": id, "cliSessionId": cli, "isArchived": archived]
            try JSONSerialization.data(withJSONObject: o).write(to: dir.appendingPathComponent("\(id).json"))
        }
        try file("local_one", "cli-1")
        try file("local_old", "cli-2", archived: true)
        XCTAssertEqual(desktopSession(cli: "cli-1", in: root), "local_one")
        XCTAssertNil(desktopSession(cli: "cli-2", in: root))
        XCTAssertNil(desktopSession(cli: "cli-3", in: root))
        let log = "x LocalSessions.setFocusedSession: sessionId=local_a\ny LocalSessions.setFocusedSession: sessionId=local_b\nz other"
        XCTAssertEqual(focusedSession(log: log), "local_b")
        XCTAssertNil(focusedSession(log: "nothing"))
    }

    // R6: the pad's new session opens in the Claude app, in a folder that's there; anything else opens nothing.
    func testR6_NewSessionLink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("a b \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try XCTUnwrap(newSession(in: dir.path))
        XCTAssertTrue(url.absoluteString.hasPrefix("claude://code/new?folder=%2F"))
        XCTAssertTrue(url.absoluteString.contains("a%20b%20"))
        XCTAssertNil(newSession(in: "relative/path"))
        XCTAssertNil(newSession(in: dir.path + "/missing"))
        XCTAssertNil(newSession(in: "/etc/hosts"), "a file isn't a folder")
    }
}


final class NamedTests: XCTestCase {
    // R1: the pad names a session as the Claude app does: a side session by the short name it was started with,
    // any other by its title cut to a few words, and knows the session that started or forked it.
    func testR1_SessionsAreNamedWithTheirParent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("named-\(UUID().uuidString)/a/b")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        func write(_ o: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: o).write(to: root.appendingPathComponent("\(o["sessionId"]!).json"))
        }
        try write(["sessionId": "local_m", "cliSessionId": "m0", "lastAssistantCliSessionId": "m1", "title": "Old iPhone SE project ideas",
                   "lastFocusedAt": 1793823472486])
        try write(["sessionId": "local_k", "cliSessionId": "k", "title": "Jailbreak the SE and deploy yapad",
                   "spawnedFrom": ["sessionId": "local_m", "name": "jailbreak"]])
        try write(["sessionId": "local_f", "cliSessionId": "f", "title": "Fork", "forkedFromSessionId": "local_k"])
        try write(["sessionId": "local_x", "cliSessionId": "x", "title": "Not asked for"])
        let n = named(["m1", "k", "f"], in: root.deletingLastPathComponent().deletingLastPathComponent())
        XCTAssertEqual(n["m1"], Named(name: "Old iPhone SE project", title: "Old iPhone SE project ideas", parent: nil, focused: 1793823472.486))
        XCTAssertEqual(n["k"], Named(name: "jailbreak", title: "Jailbreak the SE and deploy yapad", parent: "m1"))
        XCTAssertEqual(n["f"]?.parent, "k")
        XCTAssertNil(n["x"])
    }
}

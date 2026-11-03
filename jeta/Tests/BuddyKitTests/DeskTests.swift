import XCTest
import BuddyKit
import JetaKit

final class DeskTests: XCTestCase {
    func event(_ name: String, _ more: [String: Any] = [:], session: String = "s1", cwd: String = "/Users/me/yapa") -> [String: Any] {
        ["hook_event_name": name, "session_id": session, "cwd": cwd].merging(more) { $1 }
    }

    let push: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "git push"]]

    // R2: the pad keeps every session's state from its hooks, the way the Claude app's heartbeat would tell it,
    // each session named by its folder.
    func testR2_HeartbeatFromHookEvents() {
        let d = Desk()
        _ = d.take(event("SessionStart"), at: 0)
        _ = d.take(event("SessionStart", session: "s2", cwd: "/Users/me/fium"), at: 0)
        _ = d.take(event("UserPromptSubmit"), at: 1)
        _ = d.take(event("PreToolUse", ["tool_name": "Grep", "tool_input": ["pattern": "Buddy"]]), at: 2)
        var h = d.heartbeat(at: 2)
        XCTAssertEqual(h["total"] as? Int, 2)
        XCTAssertEqual(h["running"] as? Int, 1)
        XCTAssertEqual(h["waiting"] as? Int, 0)
        XCTAssertEqual(h["msg"] as? String, "yapa: Grep Buddy")
        XCTAssertNil(h["prompt"])
        _ = d.take(event("Stop"), at: 3)
        _ = d.take(event("SessionEnd", session: "s2"), at: 3)
        h = d.heartbeat(at: 3)
        XCTAssertEqual(h["total"] as? Int, 1)
        XCTAssertEqual(h["running"] as? Int, 0)
        XCTAssertTrue(d.active)
        _ = d.take(event("SessionEnd"), at: 4)
        XCTAssertFalse(d.active, "no sessions left: Bluetooth may drive the face again")
    }

    // R2: a permission request is held and shows as the prompt, with the session's name and the command.
    func testR2_PermissionRequestIsHeldAndShown() {
        let d = Desk()
        let r = d.take(event("PermissionRequest", push), at: 1)
        XCTAssertNotNil(r.hold)
        let p = d.heartbeat(at: 1)["prompt"] as? [String: Any]
        XCTAssertEqual(p?["id"] as? String, r.hold)
        XCTAssertEqual(p?["tool"] as? String, "Bash")
        XCTAssertEqual(p?["hint"] as? String, "yapa: git push")
        XCTAssertEqual(d.heartbeat(at: 1)["waiting"] as? Int, 1)
    }

    // R2: the heartbeat drives the same Hardware Buddy core as the Claude app's: its prompt shows and a tap answers it.
    func testR2_HeartbeatDrivesTheCore() {
        let d = Desk(), b = Buddy(name: "Claude-yapa", now: 0)
        let id = d.take(event("PermissionRequest", push), at: 1).hold!
        _ = b.receive(d.line(at: 1), at: 1)
        XCTAssertEqual(b.prompt(at: 1)?.id, id)
        XCTAssertEqual(b.prompt(at: 1)?.hint, "yapa: git push")
        let sent = b.decide(true, at: 2).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertEqual(decision(d.decide(sent ?? [:])), "allow")
    }

    func decision(_ s: Settle?) -> String? {
        guard let s, !s.body.isEmpty, let o = try? JSONSerialization.jsonObject(with: s.body) as? [String: Any] else { return nil }
        return ((o["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])?["behavior"] as? String
    }

    // R3: a tap answers the waiting hook: once is allow, deny is deny, and each prompt only once.
    func testR3_TapAnswersTheHook() {
        let d = Desk()
        let a = d.take(event("PermissionRequest", push), at: 1).hold!
        let b = d.take(event("PermissionRequest", push, session: "s2"), at: 1).hold!
        XCTAssertEqual(decision(d.decide(["cmd": "permission", "id": a, "decision": "once"])), "allow")
        XCTAssertEqual((d.heartbeat(at: 2)["prompt"] as? [String: Any])?["id"] as? String, b, "the next prompt shows")
        XCTAssertEqual(decision(d.decide(["cmd": "permission", "id": b, "decision": "deny"])), "deny")
        XCTAssertNil(d.decide(["cmd": "permission", "id": a, "decision": "once"]))
        XCTAssertNil(d.decide(["cmd": "permission", "id": "nope", "decision": "once"]))
    }

    // R3: nothing but a tap approves. An answer in the terminal, or a hook that gave up, lets the hook go with nothing.
    func testR3_NeverApprovedWithoutATap() {
        let d = Desk()
        let b = d.take(event("PermissionRequest", push), at: 3).hold!
        XCTAssertTrue(d.take(event("PreToolUse", push), at: 3).settled.isEmpty, "the same call's late PreToolUse doesn't settle it")
        let ran = d.take(event("PostToolUse", push), at: 4)
        XCTAssertEqual(ran.settled.map(\.id), [b])
        XCTAssertTrue(ran.settled.allSatisfy { $0.body.isEmpty })
        XCTAssertNil(d.decide(["cmd": "permission", "id": b, "decision": "once"]), "too late to approve")

        let c = d.take(event("PermissionRequest", push), at: 5).hold!
        XCTAssertEqual(d.take(event("Stop"), at: 6).settled.map(\.id), [c])

        let e = d.take(event("PermissionRequest", push), at: 10).hold!
        XCTAssertEqual(d.expire(at: 611).map(\.id), [e], "past the hook's own 10 min timeout")
        XCTAssertNil(d.heartbeat(at: 611)["prompt"])
    }

    // R3: an app that restarted never reuses an id: the Buddy core hides a prompt whose id it already answered.
    func testR3_PromptIDsDifferAcrossRestarts() {
        XCTAssertNotEqual(Desk().take(event("PermissionRequest", push), at: 1).hold, Desk().take(event("PermissionRequest", push), at: 1).hold)
    }

    // R2: /hook answers the home network only: private, link-local and loopback addresses, never one routed from outside.
    func testR2_HomeNetworkOnly() {
        for h in ["192.168.1.20", "10.0.0.5", "172.16.3.4", "169.254.158.134", "127.0.0.1", "::1", "fe80::1", "::ffff:192.168.1.20", "fd12::3"] {
            XCTAssertTrue(homeNetwork(h), h)
        }
        for h in ["8.8.8.8", "172.32.0.1", "2803:9800::1", "::ffff:1.1.1.1", ""] {
            XCTAssertFalse(homeNetwork(h), h)
        }
    }

    // R2: the hook's POST is read whole even when it arrives in pieces.
    func testR2_ReadsAPostWhole() {
        let head = "POST /hook HTTP/1.1\r\nHost: claude-yapa.local:8079\r\nContent-Length: 4\r\n\r\n"
        XCTAssertNil(HTTPRequest(Data((head + "ab").utf8)))
        let r = HTTPRequest(Data((head + "abcd").utf8))
        XCTAssertEqual(r?.path, "/hook")
        XCTAssertEqual(r?.body, Data("abcd".utf8))
    }

    // R1: each session's state comes from its own hooks: working (reading while it reads or searches), needs you,
    // finished, failed, and quiet after 30 min with nothing; in the order the sessions started.
    func testR1_EachSessionsState() {
        let d = Desk()
        func state(_ id: String, at t: Double) -> SessionState? { d.members(at: t).first { $0.id == id }?.state }
        _ = d.take(event("SessionStart"), at: 0)
        _ = d.take(event("SessionStart", session: "s2", cwd: "/Users/me/fium"), at: 1)
        XCTAssertEqual(d.members(at: 1).map(\.name), ["yapa", "fium"])
        _ = d.take(event("UserPromptSubmit"), at: 2)
        XCTAssertEqual(state("s1", at: 2), .working(reading: false))
        _ = d.take(event("PreToolUse", ["tool_name": "Grep", "tool_input": ["pattern": "x"]]), at: 3)
        XCTAssertEqual(state("s1", at: 3), .working(reading: true))
        _ = d.take(event("PermissionRequest", push), at: 4)
        XCTAssertEqual(state("s1", at: 4), .needs)
        _ = d.take(event("PostToolUse", push), at: 5)
        _ = d.take(event("Stop"), at: 6)
        XCTAssertEqual(state("s1", at: 6), .finished(at: 6))
        _ = d.take(event("UserPromptSubmit", session: "s2"), at: 7)
        _ = d.take(event("StopFailure", session: "s2"), at: 8)
        XCTAssertEqual(state("s2", at: 8), .failed)
        XCTAssertEqual(state("s1", at: 6 + 1801), .quiet)
        let before = d.members(at: 9).first { $0.id == "s1" }!.events
        _ = d.take(event("UserPromptSubmit"), at: 10)
        XCTAssertGreaterThan(d.members(at: 10).first { $0.id == "s1" }!.events, before, "each event counts, so a hidden face comes back")
    }

    // R3: a tap brings one session forward, and its prompt is the one the pad shows and a tap answers.
    func testR3_FocusPicksWhosePrompt() {
        let d = Desk()
        let a = d.take(event("PermissionRequest", push), at: 1).hold!
        let b = d.take(event("PermissionRequest", push, session: "s2", cwd: "/Users/me/fium"), at: 2).hold!
        XCTAssertEqual((d.heartbeat(at: 2)["prompt"] as? [String: Any])?["id"] as? String, a)
        d.focus = "s2"
        XCTAssertEqual((d.heartbeat(at: 2)["prompt"] as? [String: Any])?["id"] as? String, b)
        XCTAssertEqual((d.heartbeat(at: 2)["prompt"] as? [String: Any])?["hint"] as? String, "fium: git push")
    }

    // R2: with the hooks on, the manager's jeta: lines still reach the notice board: from an echo in a Bash call
    // and from the text a session ended its turn on; nothing else becomes a turn.
    func testR2_ManagerLinesComeThroughTheHooks() {
        var board = NoticeBoard()
        let echo = event("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "echo 'jeta: server needs you · Which hostname?'"]])
        board.take(Desk.turn(echo)!)
        XCTAssertEqual(board.pending.map(\.session), ["server"])
        XCTAssertEqual(board.pending.first?.from, "s1", "an answer goes back to the session that asked")
        board.take(Desk.turn(event("Stop", ["last_assistant_message": "Done.\njeta: clear server"]))!)
        XCTAssertEqual(board.pending.count, 0)
        XCTAssertNil(Desk.turn(event("PreToolUse", push)))
        XCTAssertNil(Desk.turn(event("Stop", ["last_assistant_message": "All done."])))
        XCTAssertNil(Desk.turn(event("PostToolUse", ["tool_input": ["command": "echo 'jeta: clear server'"]])))
    }

    // R1: a pad that restarts (an install) keeps its sessions, aged by the time it was off; waiting requests and
    // work in progress don't survive it, and a session quiet for 2 h is gone.
    func testR1_SessionsOutliveARestart() {
        let d = Desk()
        _ = d.take(event("Stop"), at: 100)
        _ = d.take(event("PreToolUse", push, session: "s2", cwd: "/Users/me/fium"), at: 110)
        _ = d.take(event("PermissionRequest", push, session: "s2", cwd: "/Users/me/fium"), at: 111)
        let saved = d.save(at: 120, wall: 1_000)
        let e = Desk()
        e.load(saved, at: 5, wall: 1_030)
        let m = e.members(at: 5)
        XCTAssertEqual(m.map(\.name), ["yapa", "fium"])
        XCTAssertEqual(m.map(\.events), [1, 2])
        XCTAssertNil(e.heartbeat(at: 5)["prompt"], "a request whose hook is gone isn't shown")
        XCTAssertEqual(e.heartbeat(at: 5)["running"] as? Int, 0)
        let old = Desk(); old.load(saved, at: 5, wall: 1_000 + 7300)
        XCTAssertFalse(old.active)
    }

    func testR10_QuestionsAreAnsweredOnThePad() {
        let d = Desk()
        let q: [String: Any] = ["question": "Which?", "header": "Pick", "multiSelect": true,
                                "options": [["label": "a"], ["label": "b"]]]
        let hold = d.take(["hook_event_name": "PermissionRequest", "session_id": "s", "cwd": "/x/yapa",
                           "tool_name": "AskUserQuestion", "tool_input": ["questions": [q]]], at: 1).hold!
        let a = d.asked()!
        XCTAssertEqual(a.session, "yapa")
        XCTAssertEqual(a.questions, [Asked.Question(question: "Which?", header: "Pick", options: ["a", "b"], multi: true)])
        let body = try! JSONSerialization.jsonObject(with: d.answer(hold, ["Which?": "a, b"])!.body) as! [String: Any]
        let dec = (body["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
        XCTAssertEqual(dec["behavior"] as? String, "allow")
        XCTAssertEqual((dec["updatedInput"] as! [String: Any])["answers"] as? [String: String], ["Which?": "a, b"])
        XCTAssertNil(d.asked())
        _ = d.take(["hook_event_name": "PermissionRequest", "session_id": "s", "tool_name": "Bash",
                    "tool_input": ["command": "git push origin main", "description": "Push"]], at: 2)
        XCTAssertEqual(d.asked()?.text, "Bash: git push origin main (Push)")
    }
}

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

        let g = d.take(event("PermissionRequest", push), at: 620).hold!
        d.gaveUp(g)
        XCTAssertNil(d.asked(), "a request whose hook gave up leaves the pad")
        XCTAssertNil(d.decide(["cmd": "permission", "id": g, "decision": "once"]), "nothing left to approve")
    }

    func testR3_SubagentHookDoesNotReleaseParentsPermission() {
        let d = Desk()
        let waiting = d.take(event("PermissionRequest", push), at: 1).hold!
        let child = ["agent_id": "child-1", "agent_type": "Explore", "tool_name": "Grep",
                     "tool_input": ["pattern": "foo"]] as [String: Any]
        XCTAssertTrue(d.take(event("SubagentStart", child), at: 2).settled.isEmpty)
        XCTAssertTrue(d.take(event("PreToolUse", child), at: 3).settled.isEmpty)
        XCTAssertTrue(d.take(event("PostToolUse", child), at: 4).settled.isEmpty)
        XCTAssertTrue(d.take(event("SubagentStop", child), at: 5).settled.isEmpty)
        XCTAssertEqual(d.asked()?.id, waiting)
        XCTAssertEqual(decision(d.decide(["cmd": "permission", "id": waiting, "decision": "once"])), "allow")
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

    // A request a web page made says so in its headers; a hook's curl never does.
    func testARequestFromABrowserIsKnown() {
        func r(_ headers: String) -> HTTPRequest? { HTTPRequest(Data("POST /hook HTTP/1.1\r\nHost: x\r\n\(headers)Content-Length: 0\r\n\r\n".utf8)) }
        XCTAssertEqual(r("")?.browser, false)
        XCTAssertEqual(r("Origin: http://evil.example\r\n")?.browser, true)
        XCTAssertEqual(r("sec-fetch-mode: no-cors\r\n")?.browser, true)
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
        XCTAssertEqual(state("s1", at: 6), .working(reading: false), "just stopped: another turn often follows")
        XCTAssertEqual(state("s1", at: 11.1), .finished(at: 6))
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

    // R1: a pad that restarts (an install) keeps its sessions, aged by the time it was off, a working one still
    // working; waiting requests don't survive it, and a session quiet for 2 h is gone.
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
        XCTAssertEqual(e.heartbeat(at: 5)["running"] as? Int, 1)
        XCTAssertEqual(m[1].state, .working(reading: false), "fium was mid-turn")
        XCTAssertEqual(m[1].since, 5 - 30 - 10, "its turn still began when it did")
        let late = Desk(); late.load(saved, at: 5, wall: 1_000 + 900)
        if case .stale = late.members(at: 5)[1].state {} else { XCTFail("no news for 15 min is stale") }
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

    // R2: every folder a session ran in is kept, the latest first and each once, for the dial's new session.
    func testR2_FoldersSessionsRanIn() {
        let d = Desk()
        _ = d.take(event("SessionStart", cwd: "/Users/me/yapa"), at: 1)
        _ = d.take(event("SessionStart", session: "s2", cwd: "/Users/me/fium"), at: 2)
        _ = d.take(event("PreToolUse", push), at: 3)
        XCTAssertEqual(d.folders, ["/Users/me/yapa", "/Users/me/fium"])
    }

    // R2: a session goes by its folder until the Mac names it as the Claude app does, with the session that started
    // it, and both outlive a restart.
    func testR2_SessionsNamedByTheMac() {
        let d = Desk()
        _ = d.take(event("SessionStart"), at: 1)
        _ = d.take(event("SessionStart", session: "s2"), at: 2)
        XCTAssertEqual(d.members(at: 3).map(\.name), ["yapa", "yapa"])
        XCTAssertEqual(d.unnamed, ["s1", "s2"])
        d.name("s2", "jailbreak", parent: "s1")
        d.name("s9", "gone", parent: nil)
        XCTAssertEqual(d.unnamed, ["s1"])
        XCTAssertEqual(d.members(at: 3).last, SessionInfo(id: "s2", name: "jailbreak", state: .quiet, events: 1, parent: "s1"))
        _ = d.take(event("PermissionRequest", push, session: "s2"), at: 4)
        XCTAssertEqual(d.asked()?.session, "jailbreak")
        let e = Desk()
        e.load(d.save(at: 5, wall: 100), at: 0, wall: 101)
        XCTAssertEqual(e.members(at: 1).last?.parent, "s1")
        XCTAssertEqual(e.unnamed, ["s1"])
    }

    // R10: the question a session's turn ends on in the Claude app shows on the pad with its answers, under the
    // session's name, and picking one is typed into that session.
    func testR10_NextStepQuestionsReachThePad() {
        var board = NoticeBoard()
        let wrap = event("PreToolUse", ["tool_name": "mcp__ccd_turn__wrap_up", "tool_input": [
            "recap": "Built it.", "ask": "Commit the dial · and names?",
            "actions": [["label": "Yes, commit"], ["action": "create_pr"], ["label": "Not | yet"]]]])
        board.take(Desk.turn(wrap, name: "Old iPhone SE")!)
        XCTAssertEqual(board.pending.first?.text, "Commit the dial , and names?")
        XCTAssertEqual(board.pending.first?.options, ["Yes, commit", "Create Pr", "Not / yet"])
        XCTAssertEqual(board.pending.first?.from, "s1")
        XCTAssertEqual(board.pending.first?.session, "Old\u{00A0}iPhone\u{00A0}SE")
        XCTAssertEqual(board.pending.first?.own, true, "a next-step box is its own session's")
        board.answered(by: "s1")
        XCTAssertTrue(board.pending.isEmpty)
        XCTAssertNil(Desk.turn(event("PreToolUse", ["tool_name": "mcp__ccd_turn__wrap_up", "tool_input": ["recap": "Done."]]), name: "x"))
    }

    // R2: a working session says what it's on and since when its turn began; once it stops, neither.
    func testR2_WhatEachSessionIsDoing() {
        let d = Desk()
        _ = d.take(event("UserPromptSubmit"), at: 10)
        XCTAssertEqual(d.members(at: 11).first?.doing, "thinking")
        _ = d.take(event("PreToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/Users/me/yapa/ya"]]), at: 12)
        _ = d.take(event("PreToolUse", ["tool_name": "mcp__ccd_turn__wrap_up", "tool_input": [:]], session: "s2"), at: 13)
        XCTAssertEqual(d.members(at: 14).map(\.doing), ["Read ya", "wrap up"])
        XCTAssertEqual(d.members(at: 14).map(\.since), [10, 13])
        _ = d.take(event("PostToolUse", ["tool_name": "Read"]), at: 15)
        XCTAssertEqual(d.members(at: 16).first?.doing, "thinking", "a tool done, it thinks again")
        _ = d.take(event("Stop"), at: 20)
        XCTAssertEqual(d.members(at: 26).first?.doing, "")
        XCTAssertNil(d.members(at: 26).first?.since)
    }

    // R10: a failed turn needs you like a question does, with the error as its text, until the session goes on.
    func testR10_AFailedTurnNeedsYou() {
        var board = NoticeBoard()
        board.take(Desk.turn(event("StopFailure", ["error": "rate_limit"]), name: "che")!)
        XCTAssertEqual(board.pending.first?.text, "stopped on an error: rate_limit")
        XCTAssertEqual(board.pending.first?.session, "che")
        board.answered(by: "s1")
        XCTAssertTrue(board.pending.isEmpty)
        XCTAssertNotNil(Desk.turn(event("StopFailure"), name: "che"), "with no error given, it still asks")
    }

    // R3: a request can be allowed for the rest of the session (its own suggested rules, added for the session
    // alone), or denied with the words said on the pad as the reason, and stopped.
    func testR3_AllowForTheSessionDenyWithWordsAndStop() {
        func decision(_ cmd: [String: Any], suggestions: [[String: Any]]?) -> [String: Any] {
            let d = Desk()
            var more: [String: Any] = push
            if let suggestions { more["permission_suggestions"] = suggestions }
            let id = d.take(event("PermissionRequest", more), at: 1).hold!
            XCTAssertEqual(d.asked()?.forSession, suggestions != nil)
            let body = d.decide(cmd.merging(["cmd": "permission", "id": id]) { $1 })!.body
            let o = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            return (o["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
        }
        let rule: [String: Any] = ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "git push:*"]],
                                   "behavior": "allow", "destination": "localSettings"]
        let session = decision(["decision": "session"], suggestions: [rule])
        XCTAssertEqual(session["behavior"] as? String, "allow")
        let added = session["updatedPermissions"] as? [[String: Any]]
        XCTAssertEqual(added?.first?["destination"] as? String, "session")
        XCTAssertEqual(added?.first?["type"] as? String, "addRules")
        let words = decision(["decision": "deny", "message": "use the staging db"], suggestions: nil)
        XCTAssertEqual(words["behavior"] as? String, "deny")
        XCTAssertEqual(words["message"] as? String, "Denied on the pad: use the staging db")
        XCTAssertNil(words["interrupt"])
        XCTAssertEqual(decision(["decision": "deny", "interrupt": true], suggestions: nil)["interrupt"] as? Bool, true)
    }

    // R2: one state each, by precedence: a session working with no news for 10 min is stale; one that stops and
    // starts again within 5 s never shows done; a turn whose subagents still run isn't done until they stop.
    func testR2_StaleGraceAndSubagents() {
        let d = Desk()
        func state(_ id: String, at t: Double) -> SessionState? { d.members(at: t).first { $0.id == id }?.state }
        _ = d.take(event("UserPromptSubmit"), at: 0)
        XCTAssertEqual(state("s1", at: 599), .working(reading: false))
        XCTAssertEqual(state("s1", at: 601), .stale(since: 0))
        _ = d.take(event("Stop"), at: 700)
        _ = d.take(event("UserPromptSubmit"), at: 703)
        XCTAssertEqual(state("s1", at: 704), .working(reading: false), "never done in between")
        _ = d.take(event("SubagentStart"), at: 710)
        _ = d.take(event("Stop"), at: 720)
        XCTAssertEqual(state("s1", at: 760), .working(reading: false), "its subagent still runs")
        _ = d.take(event("SubagentStop"), at: 800)
        XCTAssertEqual(state("s1", at: 806), .finished(at: 800))
    }

    // R2: a finished turn stays unseen until you look: its reply opened on the pad, a new prompt, or the Claude app
    // showing the session since it finished. It outlives a restart.
    func testR2_DoneStaysUnseenUntilLooked() {
        let d = Desk()
        var clock = 1000.0
        d.wall = { clock }
        _ = d.take(event("SessionStart"), at: 0)
        _ = d.take(event("SessionStart", session: "s2"), at: 0)
        for s in ["s1", "s2"] { _ = d.take(event("UserPromptSubmit", session: s), at: 1); _ = d.take(event("Stop", session: s), at: 2) }
        XCTAssertEqual(d.members(at: 10).map(\.unseen), [true, true])
        d.looked(at: "s1")
        clock = 1100
        d.name("s2", "che", parent: nil, focused: 999)
        XCTAssertTrue(d.members(at: 10).last!.unseen, "focused before it finished")
        let e = Desk()
        e.load(d.save(at: 10, wall: clock), at: 0, wall: clock)
        XCTAssertEqual(e.members(at: 1).map(\.unseen), [false, true])
        d.name("s2", "che", parent: nil, focused: 1050)
        XCTAssertFalse(d.members(at: 10).last!.unseen, "the Claude app showed it since")
        _ = e.take(event("UserPromptSubmit", session: "s2"), at: 2)
        XCTAssertFalse(e.members(at: 3).last!.unseen)
    }

    // A failed tool ends its step like a finished one: the session thinks again, no longer reading. One you
    // interrupted ends the turn, since no Stop follows an interrupt, and you saw it.
    func testPostToolUseFailureEndsTheStep() {
        let d = Desk()
        func me(at t: Double) -> SessionInfo { d.members(at: t).first! }
        _ = d.take(event("UserPromptSubmit"), at: 0)
        _ = d.take(event("PreToolUse", ["tool_name": "Grep", "tool_input": ["pattern": "x"]]), at: 1)
        XCTAssertEqual(me(at: 1).state, .working(reading: true))
        _ = d.take(event("PostToolUseFailure", ["tool_name": "Grep", "tool_input": ["pattern": "x"], "error": "no such file"]), at: 2)
        XCTAssertEqual(me(at: 2).state, .working(reading: false))
        XCTAssertEqual(me(at: 2).doing, "thinking")
        _ = d.take(event("PreToolUse", push), at: 3)
        _ = d.take(event("PostToolUseFailure", push.merging(["is_interrupt": true]) { $1 }), at: 4)
        XCTAssertEqual(me(at: 10).state, .finished(at: 4), "interrupted: the turn is over")
        XCTAssertFalse(me(at: 10).unseen, "you interrupted it, so you saw it")
    }

    // An interrupt stops its subagents with it, so the session's next turn isn't left waiting on them; one still at
    // work (in the background) runs again on its next tool call, and its turn ends when it stops.
    func testInterruptStopsSubagents() {
        let d = Desk()
        func me(at t: Double) -> SessionInfo { d.members(at: t).first! }
        _ = d.take(event("UserPromptSubmit"), at: 0)
        _ = d.take(event("SubagentStart", ["agent_id": "a1", "agent_type": "Explore"]), at: 1)
        _ = d.take(event("PreToolUse", ["tool_name": "Grep", "tool_input": ["pattern": "x"], "agent_id": "a1"]), at: 2)
        _ = d.take(event("PostToolUseFailure", ["tool_name": "Grep", "tool_input": ["pattern": "x"], "agent_id": "a1",
                                                "is_interrupt": true]), at: 3)
        XCTAssertEqual(me(at: 10).state, .finished(at: 3), "interrupted in a subagent: the turn is over")
        XCTAssertEqual(me(at: 10).agents.map(\.stopped), [3])
        _ = d.take(event("UserPromptSubmit"), at: 20)
        _ = d.take(event("Stop"), at: 21)
        XCTAssertEqual(me(at: 30).state, .finished(at: 21), "the next turn isn't left waiting on the interrupted subagent")
        _ = d.take(event("UserPromptSubmit"), at: 40)
        _ = d.take(event("SubagentStart", ["agent_id": "b1", "agent_type": "general-purpose"]), at: 41)
        _ = d.take(event("PostToolUseFailure", push.merging(["is_interrupt": true]) { $1 }), at: 42)
        _ = d.take(event("PreToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/x"], "agent_id": "b1"]), at: 50)
        XCTAssertEqual(me(at: 60).state, .working(reading: false), "b1 kept working in the background")
        _ = d.take(event("SubagentStop", ["agent_id": "b1"]), at: 70)
        XCTAssertEqual(me(at: 80).state, .finished(at: 70))
    }

    // Subagents are kept by id and type, with when each started and stopped and what it last did; a Stop waits
    // for those still running. One whose start was missed is picked up by its first tool call.
    func testSubagentsByIdAndType() {
        let d = Desk()
        func me(at t: Double) -> SessionInfo { d.members(at: t).first! }
        _ = d.take(event("UserPromptSubmit"), at: 0)
        _ = d.take(event("PreToolUse", ["tool_name": "Agent", "tool_input": ["description": "find the hooks"]]), at: 1)
        _ = d.take(event("SubagentStart", ["agent_id": "a1", "agent_type": "Explore"]), at: 2)
        _ = d.take(event("PreToolUse", ["tool_name": "Grep", "tool_input": ["pattern": "hook"], "agent_id": "a1", "agent_type": "Explore"]), at: 3)
        XCTAssertEqual(me(at: 3).doing, "Agent find the hooks", "the session is on its Agent call, not the subagent's Grep")
        XCTAssertEqual(me(at: 3).state, .working(reading: false))
        XCTAssertEqual(me(at: 3).agents, [Subagent(id: "a1", type: "Explore", doing: "Grep hook", started: 2)])
        _ = d.take(event("PreToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/x/a.swift"], "agent_id": "a2", "agent_type": "Plan"]), at: 4)
        XCTAssertEqual(me(at: 4).agents.map(\.type), ["Explore", "Plan"])
        _ = d.take(event("SubagentStop", ["agent_id": "a1", "agent_type": "Explore"]), at: 5)
        XCTAssertEqual(me(at: 5).agents.first?.stopped, 5)
        _ = d.take(event("Stop"), at: 6)
        XCTAssertEqual(me(at: 20).state, .working(reading: false), "Plan still runs")
        _ = d.take(event("SubagentStop"), at: 30)
        XCTAssertEqual(me(at: 36).state, .finished(at: 30), "a stop with no id closes the oldest still running")
        XCTAssertEqual(me(at: 36).agents.map(\.stopped), [5, 30])
        _ = d.take(event("UserPromptSubmit"), at: 40 + 600)
        XCTAssertEqual(me(at: 641).agents, [], "agents stopped 10 min ago are dropped")
    }

    // A session on one long tool call, or waiting on a subagent, is working however long it takes (up to an hour);
    // one with nothing running and no news for 10 min is stale: the pad likely missed its end. Notifications
    // aren't news of progress.
    func testLongStepIsNotStale() {
        let d = Desk()
        func me(at t: Double) -> SessionInfo { d.members(at: t).first { $0.id == "s1" }! }
        _ = d.take(event("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "make test"], "tool_use_id": "t1"]), at: 0)
        XCTAssertEqual(me(at: 900).state, .working(reading: false), "a long step")
        XCTAssertEqual(me(at: 900).progress, 0)
        XCTAssertEqual(me(at: 3601).state, .stale(since: 0), "an hour with no news even of a long step")
        _ = d.take(event("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": "make test"], "tool_use_id": "t1"]), at: 3700)
        _ = d.take(event("Notification", ["message": "Claude is waiting for your input"]), at: 4000)
        XCTAssertEqual(me(at: 4301).state, .stale(since: 3700), "thinking 10 min with no news")
        _ = d.take(event("UserPromptSubmit", session: "s2"), at: 0)
        _ = d.take(event("SubagentStart", ["agent_id": "a"], session: "s2"), at: 1)
        XCTAssertEqual(d.members(at: 900).first { $0.id == "s2" }?.state, .working(reading: false), "waiting on its subagent")
        _ = d.take(event("Stop", session: "s3"), at: 5001)
        _ = d.take(event("PreToolUse", ["tool_name": "Grep", "tool_input": ["pattern": "x"], "agent_id": "late"], session: "s3"), at: 5002)
        _ = d.take(event("SubagentStop", ["agent_id": "late"], session: "s3"), at: 5003)
        XCTAssertEqual(d.members(at: 5010).first { $0.id == "s3" }?.state, .finished(at: 5003), "a subagent at work after its Stop ends the turn when it stops")
    }

    // The text a session last stopped on, its first plain line, for the session list.
    func testLastReplyIsSaid() {
        let d = Desk()
        _ = d.take(event("UserPromptSubmit"), at: 0)
        _ = d.take(event("Stop", ["last_assistant_message": "## Built the dial.\nMore here.\njeta: clear x"]), at: 1)
        XCTAssertEqual(d.members(at: 10).first?.said, "Built the dial.")
    }
}

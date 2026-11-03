import XCTest
import BuddyKit

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
}

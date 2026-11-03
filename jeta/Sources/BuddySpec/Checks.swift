import BuddyKit
import JetaKit
import Foundation

/// One check against the Hardware Buddy spec: `run` returns nil when it passes, or what went wrong.
public struct Check { public let name: String; public let run: () -> String? }

func line(_ o: [String: Any]) -> [UInt8] {
    Array(try! JSONSerialization.data(withJSONObject: o)) + [0x0a]
}
func json(_ s: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
}
func hb(_ extra: [String: Any] = [:]) -> [UInt8] {
    line(["total": 1, "running": 0, "waiting": 0, "msg": "", "entries": [], "tokens": 0, "tokens_today": 0].merging(extra) { $1 })
}
func prompt(_ id: String) -> [String: Any] { ["waiting": 1, "prompt": ["id": id, "tool": "Bash", "hint": "ls"]] }
func expect<T: Equatable>(_ got: T, _ want: T, _ what: String) -> String? { got == want ? nil : "\(what): got \(got), want \(want)" }
func first(_ checks: String?...) -> String? { checks.compactMap { $0 }.first }

/// Sends `bytes` at each time in `times` and returns the buddy.
func buddy(_ steps: [(Double, [UInt8])]) -> Buddy {
    let b = Buddy(name: "Claude-yapa", now: 0)
    for (t, bytes) in steps { _ = b.receive(bytes, at: t) }
    return b
}
/// Heartbeats every 10 s from `a` to `b`, the way the desktop keeps the link alive.
func every10(_ a: Double, _ b: Double, _ extra: [String: Any] = [:]) -> [(Double, [UInt8])] {
    stride(from: a, through: b, by: 10).map { ($0, hb(extra)) }
}
func reply(_ cmd: [String: Any]) -> [[String: Any]] {
    Buddy(name: "Claude-yapa", now: 0).receive(line(cmd), at: 1).map(json)
}

public let specChecks: [Check] = [
    // R1: the line framer.
    Check(name: "R1 joins fragments until newline") {
        var f = LineFramer()
        let a = f.feed(Array(#"{"a":"#.utf8)), b = f.feed(Array("1}\n{\"b\"".utf8)), c = f.feed(Array(":2}\n".utf8))
        return first(expect(a, [], "after a fragment"), expect(b, [#"{"a":1}"#], "first line"), expect(c, [#"{"b":2}"#], "second line"))
    },
    Check(name: "R1 splits several lines in one write and skips blank ones") {
        var f = LineFramer()
        return expect(f.feed(Array("{}\r\n\n[1]\n".utf8)), ["{}", "[1]"], "lines")
    },
    Check(name: "R1 skips a line that isn't UTF-8") {
        var f = LineFramer()
        return expect(f.feed([0xff, 0xfe, 0x0a] + Array("{}\n".utf8)), ["{}"], "lines")
    },
    Check(name: "R1 drops a runaway line and recovers") {
        var f = LineFramer()
        let junk = f.feed([UInt8](repeating: 0x41, count: 70_000))
        return first(expect(junk, [], "runaway"), expect(f.feed(Array("x\n{}\n".utf8)), ["{}"], "after"))
    },
    // R2: parsing and acks.
    Check(name: "R2 a bad line doesn't break the link") {
        let b = buddy([(0, Array("not json\n{\"total\":\n".utf8) + hb())])
        return expect(b.connected(at: 1), true, "connected")
    },
    Check(name: "R2 status ack carries name, sec, bat and sys") {
        let b = Buddy(name: "Claude-yapa", now: 0)
        b.secure = true; b.battery = (87, true)
        guard let r = b.receive(line(["cmd": "status"]), at: 42).first.map(json) else { return "no reply" }
        let d = r["data"] as? [String: Any] ?? [:], bat = d["bat"] as? [String: Any] ?? [:], sys = d["sys"] as? [String: Any] ?? [:]
        return first(expect(r["ack"] as? String, "status", "ack"), expect(r["ok"] as? Bool, true, "ok"),
                     expect(d["name"] as? String, "Claude-yapa", "name"), expect(d["sec"] as? Bool, true, "sec"),
                     expect(bat["pct"] as? Int, 87, "bat.pct"), expect(bat["usb"] as? Bool, true, "bat.usb"),
                     expect(sys["up"] as? Int, 42, "sys.up"))
    },
    // Claude's desktop app rejects a status ack unless bat, sys and stats each carry every field, so none is optional here.
    Check(name: "R2 status ack has every field the desktop validates, and counts decisions") {
        let b = buddy([(0, hb(prompt("a")))])
        _ = b.decide(true, at: 2); _ = b.receive(hb(prompt("b")), at: 3); _ = b.decide(false, at: 4)
        guard let r = b.receive(line(["cmd": "status"]), at: 5).first.map(json), let d = r["data"] as? [String: Any] else { return "no data" }
        let need = ["bat": ["pct", "mV", "mA"], "sys": ["up", "heap"], "stats": ["appr", "deny", "vel", "nap", "lvl"]]
        for (k, fields) in need {
            guard let o = d[k] as? [String: Any] else { return "\(k) missing" }
            if let f = fields.first(where: { (o[$0] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? true }) { return "\(k).\(f) not a number" }
        }
        let bat = d["bat"] as? [String: Any], stats = d["stats"] as? [String: Any]
        return first(expect(bat?["usb"] as? Bool != nil, true, "bat.usb"), expect(d["sec"] as? Bool != nil, true, "sec"),
                     expect(stats?["appr"] as? Int, 1, "appr"), expect(stats?["deny"] as? Int, 1, "deny"))
    },
    Check(name: "R2 name, owner and unpair are acked with ok and n") {
        let b = Buddy(name: "Claude-yapa", now: 0)
        var why: String?
        for c in ["name", "owner", "unpair"] {
            let r = b.receive(line(["cmd": c, "name": "Clawd"]), at: 1).map(json)
            why = why ?? first(expect(r.count, 1, "\(c) replies"), expect(r.first?["ack"] as? String, c, "ack"),
                               expect(r.first?["ok"] as? Bool, true, "\(c) ok"), expect(r.first?["n"] as? Int, 0, "\(c) n"))
        }
        let s = b.receive(line(["cmd": "status"]), at: 2).first.map(json)?["data"] as? [String: Any]
        return why ?? first(expect(s?["name"] as? String, "Clawd", "renamed"), expect(b.owner, "Clawd", "owner"))
    },
    Check(name: "R2 folder pushes are declined by never acking") {
        let b = Buddy(name: "Claude-yapa", now: 0)
        let cmds: [[String: Any]] = [["cmd": "char_begin", "name": "bufo", "total": 10], ["cmd": "file", "path": "a", "size": 1],
                                     ["cmd": "chunk", "d": "QQ=="], ["cmd": "file_end"], ["cmd": "char_end"]]
        return expect(cmds.flatMap { b.receive(line($0), at: 1) }, [], "replies")
    },
    Check(name: "R2 an unknown command is acked not ok") {
        let r = reply(["cmd": "dance"])
        return first(expect(r.first?["ack"] as? String, "dance", "ack"), expect(r.first?["ok"] as? Bool, false, "ok"))
    },
    Check(name: "R2 heartbeats, time and turn events need no reply") {
        let b = Buddy(name: "Claude-yapa", now: 0)
        let r = b.receive(hb() + line(["time": [1775731234, -25200]]) + line(["evt": "turn", "role": "assistant", "content": []]), at: 1)
        return expect(r, [], "replies")
    },
    Check(name: "R2 turn events reach onTurn as they arrived, across writes; nothing else does") {
        let b = Buddy(name: "Claude-yapa", now: 0)
        var got: [String] = []
        b.onTurn = { got.append($0) }
        let turn = #"{"evt":"turn","role":"assistant","content":[{"type":"text","text":"jeta: server needs you · Which host?"}]}"#
        let bytes = Array(turn.utf8)
        _ = b.receive(hb() + Array(bytes[..<20]), at: 1)
        _ = b.receive(Array(bytes[20...]) + [0x0a] + line(["time": [1775731234, -25200]]) + line(["cmd": "status"]), at: 2)
        return expect(got, [turn], "turn lines")
    },
    // R3: moods.
    Check(name: "R3 asleep before any heartbeat and 30 s after the last") {
        let b = buddy([(0, hb())])
        return first(expect(Buddy(name: "C", now: 0).mood(at: 1), .sleep, "never heard"),
                     expect(b.mood(at: 29), .idle, "29 s"), expect(b.mood(at: 31), .sleep, "31 s"))
    },
    Check(name: "R3 busy while running, curious while reading or searching") {
        let a = buddy([(0, hb(["running": 1, "msg": "writing code"]))])
        let r = buddy([(0, hb(["running": 1, "msg": "Reading file..."]))])
        let s = buddy([(0, hb(["running": 1, "msg": "working", "entries": ["10:39 grep -r foo", "10:30 Read a.swift"]]))])
        return first(expect(a.mood(at: 1), .busy, "running"), expect(r.mood(at: 1), .curious, "reading"), expect(s.mood(at: 1), .curious, "grep"))
    },
    Check(name: "R3 focused after 2 min running, proud when that run ends") {
        let b = buddy(every10(0, 130, ["running": 1, "msg": "writing"]))
        let focused = b.mood(at: 131)
        _ = b.receive(hb(), at: 135)
        return first(expect(focused, .focused, "after 130 s"), expect(b.mood(at: 136), .proud, "run ended"), expect(b.mood(at: 145), .idle, "later"))
    },
    Check(name: "R3 a short run ends without pride") {
        let b = buddy([(0, hb(["running": 1])), (30, hb())])
        return expect(b.mood(at: 31), .idle, "after 30 s run")
    },
    Check(name: "R3 attention while a prompt waits, impatient after 30 s") {
        let b = buddy(every10(0, 40, prompt("req_1")))
        return first(expect(b.mood(at: 5), .attention, "5 s"), expect(b.mood(at: 41), .impatient, "41 s"))
    },
    // The desktop leaves `prompt` out for requests it won't let a device answer; the pad still shows that one waits.
    Check(name: "R3 attention while a session waits without a prompt the pad may answer, and no decision") {
        let b = buddy(every10(0, 40, ["waiting": 1]))
        return first(expect(b.mood(at: 5), .attention, "5 s"), expect(b.mood(at: 41), .impatient, "41 s"),
                     expect(b.waiting(at: 41), true, "waiting"), expect(b.decide(true, at: 41), nil, "decision"))
    },
    Check(name: "R3 celebrates every 50K tokens, not on connect") {
        let b = buddy([(0, hb(["tokens": 184_502])), (10, hb(["tokens": 199_000]))])
        let calm = b.mood(at: 11)
        _ = b.receive(hb(["tokens": 200_100]), at: 20)
        return first(expect(calm, .idle, "below 200K"), expect(b.mood(at: 21), .celebrate, "crossed 200K"), expect(b.mood(at: 30), .idle, "later"))
    },
    Check(name: "R3 bored after 30 min idle") {
        let b = buddy(every10(0, 1810))
        return first(expect(b.mood(at: 1000), .idle, "17 min"), expect(b.mood(at: 1811), .bored, "30 min"))
    },
    Check(name: "R3 heart only for an approval within 5 s") {
        let fast = buddy([(0, hb(prompt("a")))]), slow = buddy([(0, hb(prompt("b")))]), no = buddy([(0, hb(prompt("c")))])
        _ = fast.decide(true, at: 3); _ = slow.decide(true, at: 6); _ = no.decide(false, at: 1)
        return first(expect(fast.mood(at: 3.5), .heart, "approved in 3 s"), expect(slow.mood(at: 6.5) == .heart, false, "approved in 6 s"),
                     expect(no.mood(at: 1.5) == .heart, false, "denied"))
    },
    // R4: decisions.
    Check(name: "R4 a decision echoes prompt.id exactly") {
        let id = "req_é/\"x\\y 1"
        let b = buddy([(0, hb(prompt(id)))])
        let r = b.decide(true, at: 1).map(json) ?? [:]
        let d = buddy([(0, hb(prompt("req_2")))]).decide(false, at: 1).map(json) ?? [:]
        return first(expect(r["cmd"] as? String, "permission", "cmd"), expect(r["id"] as? String, id, "id"),
                     expect(r["decision"] as? String, "once", "approve"), expect(d["decision"] as? String, "deny", "deny"),
                     expect(b.decide(true, at: 1.1).map { _ in "sent" }, nil, "twice"))
    },
    Check(name: "R4 lines end in one newline") {
        let s = buddy([(0, hb(prompt("a")))]).decide(true, at: 1) ?? ""
        let ack = reply(["cmd": "owner", "name": "F"]).count
        return first(expect(s.hasSuffix("\n") && s.filter { $0 == "\n" }.count == 1, true, "decision line"), expect(ack, 1, "ack lines"))
    },
    Check(name: "R4 nothing is sent without a prompt") {
        expect(buddy([(0, hb())]).decide(true, at: 1), nil, "decision")
    },
    Check(name: "R4 nothing is sent for a prompt the desktop withdrew") {
        expect(buddy([(0, hb(prompt("a"))), (2, hb())]).decide(true, at: 3), nil, "decision")
    },
    Check(name: "R4 nothing is sent once the link is dead") {
        let b = buddy([(0, hb(prompt("a")))])
        return first(expect(b.decide(true, at: 31), nil, "decision"), expect(b.prompt(at: 31)?.id, nil, "prompt"))
    },
    Check(name: "R4 an answered prompt isn't answered again when it repeats") {
        let b = buddy([(0, hb(prompt("a")))])
        _ = b.decide(false, at: 1)
        _ = b.receive(hb(prompt("a")), at: 2)
        return first(expect(b.prompt(at: 2)?.id, nil, "prompt"), expect(b.decide(true, at: 2), nil, "decision"), expect(b.mood(at: 2) == .attention, false, "mood"))
    },
    Check(name: "R4 a new prompt replaces the old one") {
        let b = buddy([(0, hb(prompt("a"))), (1, hb(prompt("b")))])
        return expect(b.decide(true, at: 2).map(json)?["id"] as? String, "b", "id")
    },
]

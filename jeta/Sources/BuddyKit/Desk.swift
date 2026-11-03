import Foundation

// Claude Code's hooks on the Mac post every session's events to the pad's /hook. The pad turns them into the
// heartbeat the Claude app sends over Bluetooth, so the Hardware Buddy core reads them unchanged, and holds each
// permission request until a tap answers it or the session shows it was answered in the terminal.

/// The answer to a held permission hook: a decision, or empty to leave it to the terminal's own dialog.
public struct Settle: Equatable {
    public let id: String, body: Data
}

/// Every Claude Code session on the Mac, as their hooks report them to the pad.
public final class Desk {
    struct Session { var name: String, running = false, seen = 0.0 }
    struct Held { let id, session, tool, hint: String, input: NSDictionary, since: Double }
    var sessions: [String: Session] = [:], held: [Held] = [], msg = "", count = 0
    // Ids carry this run's tag, so a che that restarted never reuses one the pad already answered.
    let run = UUID().uuidString.prefix(4).lowercased()

    public init() {}

    /// Takes one hook event. `hold` is set when a permission request should wait for the pad; `settled` are the
    /// held requests this event shows were answered elsewhere (in the terminal), each to be let go with no decision.
    public func take(_ e: [String: Any], at t: Double) -> (hold: String?, settled: [Settle]) {
        guard let event = e["hook_event_name"] as? String, let id = e["session_id"] as? String else { return (nil, []) }
        let tool = e["tool_name"] as? String ?? "", input = e["tool_input"] as? [String: Any] ?? [:]
        var s = sessions[id] ?? Session(name: ((e["cwd"] as? String ?? "") as NSString).lastPathComponent)
        s.seen = t
        sessions[id] = s
        sessions = sessions.filter { t - $0.value.seen < 7200 } // a session that went quiet for 2 h is gone
        switch event {
        case "PermissionRequest":
            count += 1
            let h = Held(id: "\(run)-\(count)", session: id, tool: tool, hint: "\(s.name): \(detail(input))", input: input as NSDictionary, since: t)
            held.append(h)
            return (h.id, [])
        case "SessionEnd":
            sessions[id] = nil
        case "UserPromptSubmit", "PreToolUse":
            sessions[id]?.running = true
            if event == "PreToolUse" { msg = "\(s.name): \(tool) \(detail(input))" }
        case "Stop", "StopFailure":
            sessions[id]?.running = false
        default:
            break
        }
        // Any later step of the session means its waiting request was answered in the terminal; a background hook for
        // that same call, arriving late, doesn't.
        guard event != "Notification" else { return (nil, []) }
        let done = held.filter { $0.session == id && !(event == "PreToolUse" && $0.tool == tool && $0.input == input as NSDictionary) }
        return (nil, release(done))
    }

    /// Answers a held request with the pad's `{"cmd":"permission"}` line, or nil if it's no longer waiting.
    public func decide(_ cmd: [String: Any]) -> Settle? {
        guard let id = cmd["id"] as? String, let h = held.first(where: { $0.id == id }) else { return nil }
        held.removeAll { $0.id == id }
        let allow = cmd["decision"] as? String == "once"
        var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if !allow { decision["message"] = "Denied on the pad." }
        let out = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return Settle(id: h.id, body: try! JSONSerialization.data(withJSONObject: out))
    }

    /// Requests older than their hook's own 10 min timeout: that hook has given up, so the pad stops showing them.
    public func expire(at t: Double) -> [Settle] { release(held.filter { t - $0.since > 600 }) }

    /// Whether any session is reporting: while one is, the hooks drive the face and Bluetooth is ignored.
    public var active: Bool { !sessions.isEmpty }

    /// The heartbeat as the Claude app writes it, one newline-terminated JSON line.
    public func line(at t: Double) -> [UInt8] {
        Array(try! JSONSerialization.data(withJSONObject: heartbeat(at: t))) + [0x0a]
    }

    /// What the Claude app's heartbeat says, built from the hooks.
    public func heartbeat(at t: Double) -> [String: Any] {
        var h: [String: Any] = ["total": sessions.count, "running": sessions.values.filter(\.running).count,
                                "waiting": Set(held.map(\.session)).count, "msg": msg,
                                "entries": sessions.values.map { "\($0.name): \($0.running ? "working" : "idle")" }.sorted()]
        if let p = held.first { h["prompt"] = ["id": p.id, "tool": p.tool, "hint": p.hint] }
        return h
    }

    func release(_ hs: [Held]) -> [Settle] {
        let ids = Set(hs.map(\.id))
        held.removeAll { ids.contains($0.id) }
        return hs.map { Settle(id: $0.id, body: Data()) }
    }
}

/// The part of a tool call worth a glance: the command, the file, the URL or the pattern.
private func detail(_ input: [String: Any]) -> String {
    let v = ["command", "file_path", "url", "pattern", "path", "query", "description"].lazy.compactMap { input[$0] as? String }.first ?? ""
    let one = v.split(separator: "\n").first.map(String.init) ?? ""
    return one.count > 80 ? String(one.prefix(79)) + "…" : one
}

/// Whether an address is on the home network: private, link-local or loopback, IPv4 or IPv6.
public func homeNetwork(_ host: String) -> Bool {
    let h = host.lowercased().hasPrefix("::ffff:") ? String(host.dropFirst(7)) : host.lowercased()
    let v4 = h.split(separator: ".").compactMap { Int($0) }
    if v4.count == 4 {
        return v4[0] == 10 || v4[0] == 127 || (v4[0] == 192 && v4[1] == 168) || (v4[0] == 172 && (16...31).contains(v4[1]))
            || (v4[0] == 169 && v4[1] == 254)
    }
    return h == "::1" || h.hasPrefix("fe80:") || h.hasPrefix("fc") || h.hasPrefix("fd")
}

/// One HTTP/1.1 request, parsed only once its whole body (Content-Length) has arrived.
public struct HTTPRequest {
    public let method: String, path: String, body: Data
    public init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        let length = lines.dropFirst().compactMap { line -> Int? in
            let kv = line.split(separator: ":", maxSplits: 1)
            return kv.count == 2 && kv[0].lowercased() == "content-length" ? Int(kv[1].trimmingCharacters(in: .whitespaces)) : nil
        }.first ?? 0
        guard data.count - end.upperBound >= length else { return nil }
        method = String(first[0]); path = String(first[1])
        body = data.subdata(in: end.upperBound..<end.upperBound + length)
    }
}

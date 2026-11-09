#if canImport(JetaKit)
import JetaKit // the app compiles JetaKit and BuddyKit into one module
#endif
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
    struct Session {
        var name: String, started: Double, running = false, reading = false, seen = 0.0, events = 0
        /// The session that started it, and whether the Mac has named it yet (until then it goes by its folder).
        var parent: String?, named = false
        /// The tool it's on and with what, and when its turn began.
        var doing = "", turn: Double?
        var finished: Double?, failed = false
        /// A finished turn you haven't looked at yet, and when it finished by the wall clock (to compare with when the
        /// Claude app last showed the session).
        var unseen = false, finishedWall = 0.0
        /// Its subagents by id, and a Stop that waits for those still running.
        var agents: [String: Subagent] = [:], stopWaits = false
        /// Its own tool calls that haven't ended, by id, and when it last made progress (any hook but a notification).
        var tools: Set<String> = [], progress = 0.0
        var runningAgents: Int { agents.values.filter { $0.stopped == nil }.count }
        /// The text the session last stopped on, and when.
        var reply: String?, replied = 0.0
    }
    struct Held {
        let id, session, tool, hint: String, input: NSDictionary, since: Double; var event = "PermissionRequest"
        /// The rules the request suggests adding, which "this session" adds for the session alone.
        var suggestions: [[String: Any]] = []
    }
    var sessions: [String: Session] = [:], held: [Held] = [], msg = "", count = 0
    /// The wall clock, in seconds since 1970; tests set their own.
    public var wall: () -> Double = { Date().timeIntervalSince1970 }
    /// A session that stopped is shown done only this long after, since another turn often follows at once.
    public static let grace = 5.0
    /// A session working with nothing running and no news for this long is stale: the pad likely missed its Stop.
    /// One on a tool call or waiting on a subagent is on a long step, until an hour with no news.
    public static let staleAfter = 600.0, longStep = 3600.0
    /// The session a tap brought forward: its prompt is the one shown and answered.
    public var focus: String?
    /// The folders sessions ran in, the latest first: where the dial offers to start a new one.
    public var folders: [String] = []
    // Ids carry this run's tag, so a pad that restarted never reuses one a hook still holds from before.
    let run = UUID().uuidString.prefix(4).lowercased()

    public init() {}

    /// Takes one hook event. `hold` is set when a permission request should wait for the pad; `settled` are the
    /// held requests this event shows were answered elsewhere (in the terminal), each to be let go with no decision.
    public func take(_ e: [String: Any], at t: Double) -> (hold: String?, settled: [Settle]) {
        guard let event = e["hook_event_name"] as? String, let id = e["session_id"] as? String else { return (nil, []) }
        let tool = e["tool_name"] as? String ?? "", input = e["tool_input"] as? [String: Any] ?? [:]
        if let cwd = e["cwd"] as? String, cwd.hasPrefix("/"), folders.first != cwd {
            folders = Array(([cwd] + folders.filter { $0 != cwd }).prefix(12))
        }
        var s = sessions[id] ?? Session(name: ((e["cwd"] as? String ?? "") as NSString).lastPathComponent, started: t)
        s.seen = t
        s.events += 1
        if event != "Notification" { s.progress = t }
        s.agents = s.agents.filter { $0.value.stopped.map { t - $0 < 600 } ?? true }
        // A tool call inside a subagent is that subagent's; its start may have been missed.
        let agent = e["agent_id"] as? String
        if let a = agent {
            var g = s.agents[a] ?? Subagent(id: a, type: e["agent_type"] as? String ?? "agent", started: t)
            if event == "PreToolUse" { g.doing = Desk.doing(tool, input) }
            if event != "SubagentStop" { s.agents[a] = g }
        }
        let call = e["tool_use_id"] as? String ?? "\(tool) \(detail(input))"
        sessions[id] = s
        sessions = sessions.filter { t - $0.value.seen < 7200 } // a session that went quiet for 2 h is gone
        // The Claude app asks AskUserQuestion's questions itself, with no permission request, so a hook waits on them
        // before the tool runs (`jeta_hold`); answered on the pad they never show at the desk.
        if event == "PreToolUse", e["jeta_hold"] as? Bool == true {
            count += 1
            var h = Held(id: "\(run)-\(count)", session: id, tool: tool, hint: "\(s.name): \(detail(input))", input: input as NSDictionary, since: t)
            h.event = event
            held.append(h)
            return (h.id, [])
        }
        switch event {
        case "PermissionRequest":
            count += 1
            var h = Held(id: "\(run)-\(count)", session: id, tool: tool, hint: "\(s.name): \(detail(input))", input: input as NSDictionary, since: t)
            h.suggestions = e["permission_suggestions"] as? [[String: Any]] ?? []
            held.append(h)
            return (h.id, [])
        case "SessionEnd":
            sessions[id] = nil
        // A subagent still at work after its session stopped: the turn ends when it does.
        case "PreToolUse" where agent != nil:
            if sessions[id]?.running != true { sessions[id]?.stopWaits = true }
            sessions[id]?.running = true
            sessions[id]?.finished = nil
            if sessions[id]?.turn == nil { sessions[id]?.turn = t }
        case "UserPromptSubmit", "PreToolUse":
            let fresh = sessions[id]?.running != true
            sessions[id]?.running = true
            sessions[id]?.finished = nil
            sessions[id]?.failed = false
            sessions[id]?.unseen = false
            sessions[id]?.stopWaits = false
            sessions[id]?.reading = ["Read", "Grep", "Glob", "WebFetch", "WebSearch", "LS"].contains(tool)
            if event == "UserPromptSubmit" || fresh || sessions[id]?.turn == nil { sessions[id]?.turn = t }
            if event == "UserPromptSubmit" { sessions[id]?.doing = "thinking"; sessions[id]?.tools = [] }
            if event == "PreToolUse" { sessions[id]?.tools.insert(call) }
            if event == "PreToolUse" { sessions[id]?.doing = Desk.doing(tool, input) }
            if event == "PreToolUse" { msg = "\(s.name): \(tool) \(detail(input))" }
        case "PostToolUse" where agent != nil, "PostToolUseFailure" where agent != nil:
            break
        // You interrupted it: no Stop follows, so its turn ends here, and you saw it.
        case "PostToolUseFailure" where e["is_interrupt"] as? Bool == true:
            finish(id, failed: false, at: t)
            sessions[id]?.unseen = false
        // A tool done or failed, the model is thinking again until its next one.
        case "PostToolUse" where sessions[id]?.running == true, "PostToolUseFailure" where sessions[id]?.running == true:
            sessions[id]?.tools.remove(call)
            sessions[id]?.doing = "thinking"; sessions[id]?.reading = false
        case "SubagentStart" where agent == nil:
            count += 1
            sessions[id]?.agents["\(count)"] = Subagent(id: "\(count)", type: e["agent_type"] as? String ?? "agent", started: t)
        case "SubagentStop":
            // One with no id closes the oldest still running.
            let key = agent ?? sessions[id]?.agents.values.filter { $0.stopped == nil }.min { ($0.started, $0.id) < ($1.started, $1.id) }?.id
            if let k = key { sessions[id]?.agents[k]?.stopped = t }
            // The last subagent it waited on is done, so its turn is.
            if sessions[id]?.runningAgents == 0, sessions[id]?.stopWaits == true { finish(id, failed: false, at: t) }
        case "Stop", "StopFailure":
            if let m = e["last_assistant_message"] as? String, !m.isEmpty { sessions[id]?.reply = m; sessions[id]?.replied = t }
            // A turn whose subagents are still at work isn't done until they are.
            if event == "Stop", (sessions[id]?.runningAgents ?? 0) > 0 { sessions[id]?.stopWaits = true; break }
            finish(id, failed: event == "StopFailure", at: t)
        default:
            break
        }
        // Any later step of the session means its waiting request was answered in the terminal; a background hook for
        // that same call, arriving late, doesn't.
        guard event != "Notification" else { return (nil, []) }
        let done = held.filter { $0.session == id && !(event == "PreToolUse" && $0.tool == tool && $0.input == input as NSDictionary) }
        return (nil, release(done))
    }

    /// The manager's `jeta:` lines, which over Bluetooth come in the Claude app's turn events, as a turn event the
    /// notice board reads: an `echo` in a Bash call (seen before it runs), or the text a session ended its turn on.
    /// The question a session's turn ends on in the Claude app (its next-step box, with a button per answer) becomes
    /// the same kind of line, under `name`, so the pad offers those answers and a pick is typed into the session.
    public static func turn(_ e: [String: Any], name: String = "") -> Data? {
        let block: [String: Any]
        var own = false
        switch e["hook_event_name"] as? String {
        case "PreToolUse" where (e["tool_name"] as? String ?? "").hasSuffix("__wrap_up"):
            let input = e["tool_input"] as? [String: Any] ?? [:]
            guard let ask = (input["ask"] as? String).map(clean), !ask.isEmpty, !name.isEmpty else { return nil }
            // An app action's button shows the app's own label, which the call may leave out.
            let options = (input["actions"] as? [[String: Any]] ?? []).compactMap { a in
                (a["label"] as? String ?? (a["action"] as? String).map { $0.replacingOccurrences(of: "_", with: " ").capitalized })
                    .map(clean)
            }.filter { !$0.isEmpty }
            // A line's session is one word, so the name's spaces are non-breaking ones; one answer isn't a choice.
            let line = "jeta: \(name.replacingOccurrences(of: " ", with: "\u{00A0}")) needs you · \(ask)"
                + (options.count >= 2 ? " · " + options.joined(separator: " | ") : "")
            block = ["type": "text", "text": line]
            own = true
        // A failed turn needs you: it won't go on until you look, so it asks like a question, with the error.
        case "StopFailure" where !name.isEmpty:
            let why = [e["error"], e["error_message"], e["last_assistant_message"]].lazy.compactMap { $0 as? String }.first { !$0.isEmpty }
            let line = "jeta: \(name.replacingOccurrences(of: " ", with: "\u{00A0}")) needs you · "
                + clean("stopped on an error" + (why.map { ": " + String($0.prefix(200)) } ?? ""))
            block = ["type": "text", "text": line]
        case "PreToolUse":
            guard let c = (e["tool_input"] as? [String: Any])?["command"] as? String, c.contains("jeta:") else { return nil }
            block = ["type": "tool_use", "input": ["command": c]]
        case "Stop":
            guard let m = e["last_assistant_message"] as? String, m.contains("jeta:") else { return nil }
            block = ["type": "text", "text": m]
        default:
            return nil
        }
        var turn: [String: Any] = ["evt": "turn", "role": "assistant", "content": [block], "session_id": e["session_id"] ?? ""]
        // A session's own next-step box: a pick goes to it alone, even once the pad knows it by another name.
        if own { turn["own"] = true }
        return try? JSONSerialization.data(withJSONObject: turn)
    }

    /// The first plain line of a reply: no headings, list marks or `jeta:` lines.
    static func said(_ text: String) -> String {
        let line = text.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*-` ")) }
            .first { !$0.isEmpty && !$0.hasPrefix("jeta:") } ?? ""
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }

    /// A tool call in a few words: an MCP tool by its own name, then what it's on.
    static func doing(_ tool: String, _ input: [String: Any]) -> String {
        let name = tool.hasPrefix("mcp__") ? (tool.components(separatedBy: "__").last ?? tool).replacingOccurrences(of: "_", with: " ") : tool
        var on = detail(input)
        if on.hasPrefix("/"), !on.contains(" ") { on = (on as NSString).lastPathComponent }
        return on.isEmpty ? name : name + " " + (on.count > 40 ? String(on.prefix(39)) + "…" : on)
    }

    private func finish(_ id: String, failed: Bool, at t: Double) {
        sessions[id]?.running = false
        sessions[id]?.finished = failed ? nil : t
        sessions[id]?.failed = failed
        sessions[id]?.unseen = !failed
        sessions[id]?.finishedWall = wall()
        sessions[id]?.stopWaits = false
        sessions[id]?.tools = []
    }

    /// You looked at a session's finished turn (its reply opened on the pad).
    public func looked(at id: String) { sessions[id]?.unseen = false }

    /// What the pad calls a session.
    public func name(of id: String) -> String { sessions[id]?.name ?? "" }

    /// Text that can sit in one part of a `jeta:` line: no dots or bars, on one line.
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "·", with: ",").replacingOccurrences(of: "|", with: "/")
            .components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// The request a tap answers (the one forward, else the first), with what it would really do.
    public func asked() -> Asked? {
        guard let h = held.first(where: { $0.session == focus }) ?? held.first else { return nil }
        let input = h.input as? [String: Any] ?? [:], name = sessions[h.session]?.name ?? ""
        let questions = (input["questions"] as? [[String: Any]] ?? []).map { q in
            Asked.Question(question: q["question"] as? String ?? "", header: q["header"] as? String ?? "",
                           options: (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String },
                           multi: q["multiSelect"] as? Bool ?? false)
        }
        return Asked(id: h.id, session: name, tool: h.tool, text: "\(h.tool): \(full(input))", questions: questions,
                     forSession: !h.suggestions.isEmpty)
    }

    /// The sessions the Mac hasn't named yet.
    public var unnamed: [String] { sessions.filter { !$0.value.named }.map(\.key).sorted() }
    public var ids: [String] { sessions.keys.sorted() }

    /// Names a session as the Claude app does, with the session that started it; what's already up keeps its name.
    public func name(_ id: String, _ name: String, parent: String?, focused: Double? = nil) {
        guard sessions[id] != nil, !name.isEmpty else { return }
        // The Claude app showed it since its turn finished: you've seen it.
        if let f = focused, let s = sessions[id], s.unseen, f > s.finishedWall { sessions[id]?.unseen = false }
        sessions[id]?.name = name
        sessions[id]?.parent = parent == id ? nil : parent
        sessions[id]?.named = true
    }

    /// Answers a held AskUserQuestion with the labels picked on the pad, as if they were picked in the terminal.
    public func answer(_ id: String, _ answers: [String: String]) -> Settle? {
        guard let h = held.first(where: { $0.id == id }) else { return nil }
        held.removeAll { $0.id == id }
        var input = h.input as? [String: Any] ?? [:]
        input["answers"] = answers
        let out: [String: Any] = h.event == "PreToolUse"
            ? ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": input]]
            : ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow", "updatedInput": input]]]
        return Settle(id: h.id, body: try! JSONSerialization.data(withJSONObject: out))
    }

    /// Answers a held request with the pad's `{"cmd":"permission"}` line, or nil if it's no longer waiting.
    public func decide(_ cmd: [String: Any]) -> Settle? {
        guard let id = cmd["id"] as? String, let h = held.first(where: { $0.id == id }) else { return nil }
        held.removeAll { $0.id == id }
        // Questions held before they run aren't refused: let go, they show at the desk.
        if h.event == "PreToolUse" { return Settle(id: h.id, body: Data()) }
        // "once", "session" (allowed, with the request's own suggested rules added for this session alone) or "deny",
        // with the words said on the pad as the reason, and "interrupt" to stop the session too.
        let how = cmd["decision"] as? String, allow = how == "once" || how == "session"
        var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if how == "session", !h.suggestions.isEmpty {
            decision["updatedPermissions"] = h.suggestions.map { $0.merging(["destination": "session"]) { $1 } }
        }
        if !allow {
            decision["message"] = (cmd["message"] as? String).flatMap { $0.isEmpty ? nil : "Denied on the pad: " + $0 } ?? "Denied on the pad."
            if cmd["interrupt"] as? Bool == true { decision["interrupt"] = true }
        }
        let out = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return Settle(id: h.id, body: try! JSONSerialization.data(withJSONObject: out))
    }

    /// Requests older than their hook's own 10 min timeout: that hook has given up, so the pad stops showing them.
    public func expire(at t: Double) -> [Settle] { release(held.filter { t - $0.since > 600 }) }

    /// The hook waiting on request `id` gave up before its 10 min (its curl timed out, or it was killed): nothing can
    /// answer it now, so it leaves the pad.
    public func gaveUp(_ id: String) { _ = release(held.filter { $0.id == id }) }

    /// Each session and what it's doing, in the order they started. One state each, by precedence: it needs you, it
    /// failed, it's stale (working, but no news for 10 min), it's working (or stopped under 5 s ago, since another
    /// turn often follows), it's done, it's quiet (30 min with nothing new).
    public func members(at t: Double) -> [SessionInfo] {
        sessions.sorted { ($0.value.started, $0.key) < ($1.value.started, $1.key) }.map { id, s in
            let graced = s.finished.map { t - $0 < Desk.grace } ?? false
            let state: SessionState = held.contains { $0.session == id } ? .needs
                : s.failed ? .failed
                : s.running && t - s.progress >= (s.tools.isEmpty && s.runningAgents == 0 ? Desk.staleAfter : Desk.longStep)
                    ? .stale(since: s.progress)
                : s.running || graced ? .working(reading: s.reading)
                : t - s.seen >= 1800 ? .quiet
                : s.finished.map { .finished(at: $0) } ?? .quiet
            let working = s.running || graced
            var info = SessionInfo(id: id, name: s.name, state: state, events: s.events, parent: s.parent,
                                   doing: working ? s.doing : "", since: working ? s.turn : nil, unseen: s.unseen)
            info.progress = working ? s.progress : nil
            info.said = s.reply.map(Desk.said) ?? ""
            info.agents = s.agents.values.sorted { ($0.started, $0.id) < ($1.started, $1.id) }
            return info
        }
    }

    /// What each session last said, the newest first.
    public func replies() -> [Reply] {
        sessions.compactMap { id, s in s.reply.map { Reply(id: id, session: s.name, text: $0, at: s.replied) } }
            .sorted { ($0.at, $0.id) > ($1.at, $1.id) }
    }

    /// The sessions as JSON, so a pad that restarts (an install) keeps its faces. `wall` is the wall clock now
    /// (seconds since 1970), since `t` starts over with the app. Waiting requests aren't kept: their hooks are gone.
    public func save(at t: Double, wall: Double) -> Data {
        let list: [[String: Any]] = sessions.map { id, s in
            var o: [String: Any] = ["id": id, "name": s.name, "started": s.started - t, "seen": s.seen - t, "events": s.events, "failed": s.failed]
            if let f = s.finished { o["finished"] = f - t }
            o["progress"] = s.progress - t
            if s.running { o["running"] = true; o["turn"] = (s.turn ?? s.seen) - t; o["doing"] = s.doing; o["reading"] = s.reading }
            if s.named { o["named"] = true; o["parent"] = s.parent }
            if s.unseen { o["unseen"] = true; o["finishedWall"] = s.finishedWall }
            if let r = s.reply { o["reply"] = r; o["replied"] = s.replied - t }
            return o
        }
        return try! JSONSerialization.data(withJSONObject: ["wall": wall, "sessions": list])
    }

    /// Takes back what `save` wrote, aged by the wall-clock time since. A session working then is still working (an
    /// install mid-turn shouldn't put its ant to sleep); one that sends no news for a while goes stale as usual.
    public func load(_ data: Data, at t: Double, wall: Double) {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let then = o["wall"] as? Double,
              let list = o["sessions"] as? [[String: Any]] else { return }
        let now = t - max(0, wall - then)
        for s in list {
            guard let id = s["id"] as? String, let name = s["name"] as? String, let seen = s["seen"] as? Double,
                  let started = s["started"] as? Double else { continue }
            var v = Session(name: name, started: now + started)
            v.seen = now + seen
            v.progress = now + (s["progress"] as? Double ?? seen)
            v.events = s["events"] as? Int ?? 0
            v.failed = s["failed"] as? Bool ?? false
            v.named = s["named"] as? Bool ?? false
            v.unseen = s["unseen"] as? Bool ?? false
            v.finishedWall = s["finishedWall"] as? Double ?? 0
            v.parent = s["parent"] as? String
            v.finished = (s["finished"] as? Double).map { now + $0 }
            v.reply = s["reply"] as? String
            v.running = s["running"] as? Bool ?? false
            v.turn = (s["turn"] as? Double).map { now + $0 }
            v.doing = s["doing"] as? String ?? ""
            v.reading = s["reading"] as? Bool ?? false
            v.replied = now + (s["replied"] as? Double ?? 0)
            if sessions[id] == nil { sessions[id] = v }
        }
        sessions = sessions.filter { t - $0.value.seen < 7200 }
    }

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
        if let p = held.first(where: { $0.session == focus }) ?? held.first { h["prompt"] = ["id": p.id, "tool": p.tool, "hint": p.hint] }
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

/// What a tool call would do, enough to judge it: the command and why, the file and the start of what goes in it.
func full(_ input: [String: Any]) -> String {
    let s = { (k: String) in input[k] as? String }
    let parts = [s("command"), s("description").map { "(\($0))" }, s("file_path") ?? s("path") ?? s("url"),
                 s("new_string") ?? s("content"), s("pattern"), s("query"), s("prompt")].compactMap { $0 }
    let one = parts.joined(separator: " ").split(whereSeparator: \.isNewline).joined(separator: " ")
    return one.count > 400 ? String(one.prefix(399)) + "…" : one
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

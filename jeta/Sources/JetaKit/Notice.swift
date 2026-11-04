import Foundation

/// A session's question for you, as the manager session relays it.
public struct Notice: Equatable {
    public var session: String, text: String
    /// Answers the user can tap instead of speaking, when the question offers them.
    public var options: [String] = []
    /// The Claude Code session the line came from (the manager's), when the hooks say; an answer goes back there.
    public var from: String? = nil
}

/// One line of the manager's session list.
public struct Roster: Equatable {
    public var session: String, state: String
}

/// What one manager line says.
public enum NoticeLine: Equatable {
    case needs(String, String)
    case choose(String, String, [String])
    case list([Roster])
    case clear(String)
}

/// Reads the manager session's notices out of the Hardware Buddy turn events. The Claude app forwards every
/// session's messages but never says which session they came from, so the manager names the session itself, in
/// lines like `jeta: server needs you · Which hostname?`, `jeta: list · server needs you; che done` and
/// `jeta: clear server`. A line counts only if it starts an assistant text line, or is the whole of an `echo` in a
/// tool call (what reaches the phone when the app strips text); anything else that mentions `jeta:` is just talk.
public struct NoticeBoard {
    /// Open questions, newest first, one per session.
    public private(set) var pending: [Notice] = []
    /// The latest session list.
    public private(set) var roster: [Roster] = []

    public init() {}

    /// The user wrote to the Claude Code session that asked (they answered at the desktop): its questions go.
    public mutating func answered(by session: String) {
        pending.removeAll { $0.from == session }
    }

    public mutating func take(_ event: Data) {
        if let e = (try? JSONSerialization.jsonObject(with: event)) as? [String: Any] { take(e) }
    }

    public mutating func take(_ event: [String: Any]) {
        for line in NoticeBoard.lines(in: event) {
            switch NoticeBoard.parse(line) {
            case .needs(let s, let q)?, .choose(let s, let q, _)?:
                var options: [String] = []
                if case .choose(_, _, let o)? = NoticeBoard.parse(line) { options = o }
                pending.removeAll { $0.session == s }
                pending.insert(Notice(session: s, text: q, options: options, from: event["session_id"] as? String), at: 0)
                if let i = roster.firstIndex(where: { $0.session == s }) { roster[i].state = "needs you" }
                else { roster.append(Roster(session: s, state: "needs you")) }
            case .list(let r)?: roster = r
            case .clear(let s)?: pending.removeAll { $0.session == s }
            case nil: break
            }
        }
    }

    static func lines(in event: [String: Any]) -> [String] {
        guard event["role"] as? String == "assistant", let content = event["content"] as? [[String: Any]] else { return [] }
        var out: [String] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                for l in (block["text"] as? String ?? "").split(whereSeparator: \.isNewline) {
                    let l = l.trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("jeta:") { out.append(l) }
                }
            case "tool_use":
                guard let cmd = (block["input"] as? [String: Any])?["command"] as? String else { continue }
                var c = cmd.trimmingCharacters(in: .whitespaces)
                guard c.hasPrefix("echo ") else { continue }
                c = String(c.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if let q = c.first, q == "'" || q == "\"", c.count > 1, c.last == q { c = String(c.dropFirst().dropLast()) }
                c = c.trimmingCharacters(in: .whitespaces)
                if c.hasPrefix("jeta:") { out.append(c) }
            default: continue
            }
        }
        return out
    }

    static func parse(_ line: String) -> NoticeLine? {
        guard line.hasPrefix("jeta:") else { return nil }
        let body = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("clear ") {
            let s = body.dropFirst(6).trimmingCharacters(in: .whitespaces)
            return s.isEmpty || s.contains(" ") ? nil : .clear(s)
        }
        // A model writing fast swaps the dot for a bullet or a spaced dash; only lines without a dot pay for that.
        var b = body
        if !b.contains("·") {
            if let r = b.range(of: "•") ?? b.range(of: " - ") { b.replaceSubrange(r, with: "·") }
        }
        let parts = b.components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 || parts.count == 3, !parts[1].isEmpty else { return nil }
        // A third part offers options, split by bars: at least two, or it isn't a choice.
        var options: [String] = []
        if parts.count == 3 {
            options = parts[2].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard options.count >= 2, parts[0] != "list" else { return nil }
        }
        if parts[0] == "list" {
            let r = parts[1].split(separator: ";").compactMap { item -> Roster? in
                let w = item.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
                return w.count == 2 ? Roster(session: w[0], state: w[1]) : nil
            }
            return r.isEmpty ? nil : .list(r)
        }
        let head = parts[0].split(separator: " ").map(String.init)
        guard head.count == 3, head[1] == "needs", head[2] == "you" else { return nil }
        return options.isEmpty ? .needs(head[0], parts[1]) : .choose(head[0], parts[1], options)
    }
}

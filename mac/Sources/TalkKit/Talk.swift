import Foundation

/// Lowercased words with accents and punctuation stripped, so "Revisá, dale." and "revisa dale" compare equal.
func words(_ s: String) -> [String] {
    s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
}

/// Edits (substitutions, insertions, deletions) to turn the hypothesis into the reference, per reference word.
public func wordErrorRate(reference: String, hypothesis: String) -> Double {
    let r = words(reference), h = words(hypothesis)
    guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
    var row = Array(0...h.count)
    for i in 1...r.count {
        var prev = row[0]
        row[0] = i
        for j in stride(from: 1, through: h.count, by: 1) {
            let keep = row[j]
            row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (r[i - 1] == h[j - 1] ? 0 : 1))
            prev = keep
        }
    }
    return Double(row[h.count]) / Double(r.count)
}

/// What one language's transcriber made of a clip.
public struct Heard: Equatable {
    public let lang: String, text: String, confidence: Double
    public init(lang: String, text: String, confidence: Double) {
        self.lang = lang; self.text = text; self.confidence = confidence
    }
}

/// The clip is transcribed in every language at once; the most confident non-empty reading wins.
public func pick(_ heard: [Heard]) -> Heard? {
    heard.filter { !words($0.text).isEmpty }.max { $0.confidence < $1.confidence }
}

/// One HTTP/1.1 request, parsed only once its whole body (Content-Length) has arrived.
public struct Request {
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

/// The text a /say body carries, trimmed so a trailing newline can't press Return; nil if it isn't UTF-8 or is blank.
public func said(_ body: Data) -> String? {
    guard let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty else { return nil }
    return text
}

public let claudeBundle = "com.anthropic.claudefordesktop"
let terminals: Set = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                      "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", claudeBundle]

public enum Route: Equatable { case typeFrontmost, sendTo(Int32), clipboard }

/// Where heard text goes without ever taking focus: typed into Claude or a terminal in front, else
/// keyed straight into the Claude app behind, else left on the clipboard.
public func route(frontmost: String?, claude: Int32?) -> Route {
    if let f = frontmost, terminals.contains(f) { return .typeFrontmost }
    if let pid = claude { return .sendTo(pid) }
    return .clipboard
}

/// Presses Enter a moment after the text lands, so a tap on the pad can stop a wrong reply.
public final class PendingEnter {
    let delay: TimeInterval, press: () -> Void
    var work: DispatchWorkItem?
    public init(after delay: TimeInterval, press: @escaping () -> Void) { self.delay = delay; self.press = press }

    public func arm() {
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.work = nil; self?.press() }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// True when an Enter was waiting and won't be pressed.
    @discardableResult public func cancel() -> Bool {
        defer { work?.cancel(); work = nil }
        return work != nil
    }
}

/// Whether a peer may post: this Mac always, else only the listed hosts (an IPv4-mapped address counts as its IPv4).
public func allowed(_ host: String, from hosts: [String]) -> Bool {
    let h = host.hasPrefix("::ffff:") ? String(host.dropFirst(7)) : host
    return h == "127.0.0.1" || h == "::1" || hosts.contains(h)
}

/// A request path's query, like `/talk?dry&session=abc`: each key and its value ("" for a bare key).
public func query(_ path: String) -> [String: String] {
    guard let q = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
    var out: [String: String] = [:]
    for kv in q.split(separator: "&") {
        let p = kv.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        out[p[0]] = p.count > 1 ? p[1] : ""
    }
    return out
}

/// The Claude app's own id (`local_…`) for the Claude Code session its hooks call `cli`, from the session files the
/// app keeps under `root`; nil when the session isn't the app's (it runs in a terminal).
public func desktopSession(cli: String, in root: URL) -> String? {
    guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
    for case let f as URL in files where f.lastPathComponent.hasPrefix("local_") && f.pathExtension == "json" {
        guard let d = try? Data(contentsOf: f), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              o["cliSessionId"] as? String == cli, o["isArchived"] as? Bool != true else { continue }
        return o["sessionId"] as? String
    }
    return nil
}

/// The session the Claude app last focused, from its log's `setFocusedSession` lines.
public func focusedSession(log: String) -> String? {
    guard let r = log.range(of: "setFocusedSession: sessionId=", options: .backwards) else { return nil }
    return log[r.upperBound...].prefix { $0 != "\n" && $0 != "," && $0 != " " }.description
}

/// The link that opens a new Claude Code session in the Claude app, in `folder`: the one its own Finder service
/// ("New Claude Code Session Here") opens. Nil unless the folder is an absolute path to a folder that's there.
public func newSession(in folder: String) -> URL? {
    var dir: ObjCBool = false
    guard folder.hasPrefix("/"), FileManager.default.fileExists(atPath: folder, isDirectory: &dir), dir.boolValue,
          let f = folder.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))
    else { return nil }
    return URL(string: "claude://code/new?folder=\(f)&source=services")
}


/// What the pad calls a session, and the session that started it.
public struct Named: Equatable {
    public var name: String, title: String, parent: String?
    /// When the Claude app last showed the session, in seconds since 1970.
    public var focused: Double? = nil
}

/// The Claude app's names for the Claude Code sessions `ids` (their hooks' `session_id`), from the session files it
/// keeps under `root`: the short name the session was started with by another (a side session), else its title cut
/// to a few words. `parent` is the session that started or forked it, as one of `ids` when the pad has it.
public func named(_ ids: Set<String>, in root: URL) -> [String: Named] {
    guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
    var all: [String: [String: Any]] = [:]
    for case let f as URL in files where f.lastPathComponent.hasPrefix("local_") && f.pathExtension == "json" {
        guard let d = try? Data(contentsOf: f), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let id = o["sessionId"] as? String else { continue }
        all[id] = o
    }
    // A session's hooks name it by its current Claude Code id, which a resumed session changes.
    func cli(_ o: [String: Any]) -> [String] { [o["lastAssistantCliSessionId"], o["cliSessionId"]].compactMap { $0 as? String } }
    var out: [String: Named] = [:]
    for o in all.values {
        guard let id = cli(o).first(where: ids.contains) else { continue }
        let from = o["spawnedFrom"] as? [String: Any], title = o["title"] as? String ?? ""
        let up = (from?["sessionId"] as? String ?? o["forkedFromSessionId"] as? String).flatMap { all[$0] }
        let name = (from?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? short(title)
        guard !name.isEmpty else { continue }
        out[id] = Named(name: name, title: title, parent: up.flatMap { p in cli(p).first(where: ids.contains) ?? cli(p).first },
                        focused: (o["lastFocusedAt"] as? Double).map { $0 / 1000 })
    }
    return out
}

/// A title cut at a word to at most 24 characters.
func short(_ title: String) -> String {
    var out = ""
    for w in title.split(separator: " ") {
        let next = out.isEmpty ? String(w) : out + " " + w
        if next.count > 24 { return out.isEmpty ? String(next.prefix(24)) : out }
        out = next
    }
    return out
}

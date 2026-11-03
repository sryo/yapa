#if canImport(JetaKit)
import JetaKit // the app compiles JetaKit and BuddyKit into one module
#endif
import Foundation

/// Joins the fragments a BLE link delivers into newline-terminated UTF-8 lines.
public struct LineFramer {
    private var buffer: [UInt8] = [], discarding = false
    private let limit: Int

    public init(limit: Int = 65_536) { self.limit = limit }

    /// Returns every complete, non-empty, valid UTF-8 line in `bytes`; a line longer than `limit` is dropped whole.
    public mutating func feed<S: Sequence>(_ bytes: S) -> [String] where S.Element == UInt8 {
        var lines: [String] = []
        for b in bytes {
            if b == 0x0a {
                if !discarding, let s = String(bytes: buffer, encoding: .utf8) {
                    let l = s.hasSuffix("\r") ? String(s.dropLast()) : s
                    if !l.isEmpty { lines.append(l) }
                }
                buffer.removeAll(keepingCapacity: true); discarding = false
            } else if !discarding {
                buffer.append(b)
                if buffer.count > limit { buffer.removeAll(); discarding = true }
            }
        }
        return lines
    }
}

public struct Prompt: Equatable { public let id, tool, hint: String }

/// The desktop's side of a Hardware Buddy link, seen from the device: what to show, what to answer.
public final class Buddy {
    public var name: String
    public private(set) var owner: String?
    /// Whether the link is encrypted; reported as `sec` in the status ack.
    public var secure = false
    public var battery: (pct: Int, usb: Bool)?
    /// Bytes of memory the app uses, reported as `sys.heap`.
    public var heap = 0
    /// Gets each turn event, the raw line as it arrived.
    public var onTurn: ((String) -> Void)?

    private var framer = LineFramer()
    private let start: Double
    private var heard: Double?, runningSince: Double?, idleSince: Double?, waitingSince: Double?
    private var pending: (prompt: Prompt, since: Double)?, answered: String?
    private var tokenStep: Int?, flash: (mood: Mood, until: Double)?
    private var activity = "", approved = 0, denied = 0, lastAnswer = 0.0

    public init(name: String, now: Double) { self.name = name; start = now }

    /// Takes bytes written by the desktop and returns the lines to send back.
    public func receive(_ bytes: [UInt8], at t: Double) -> [String] {
        framer.feed(bytes).compactMap { l in
            guard let o = (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any] else { return nil }
            if let cmd = o["cmd"] as? String { return command(cmd, o, at: t) }
            if o["evt"] as? String == "turn" { onTurn?(l); return nil }
            if o["evt"] == nil, o["time"] == nil, o["total"] != nil || o["running"] != nil || o["waiting"] != nil { heartbeat(o, at: t) }
            return nil
        }
    }

    public func connected(at t: Double) -> Bool { heard.map { t - $0 <= 30 } ?? false }

    /// The prompt a tap can answer now: none once the link is dead or this prompt was answered.
    public func prompt(at t: Double) -> Prompt? { connected(at: t) ? pending?.prompt : nil }

    /// Whether a session is blocked on a permission prompt, answerable here or only at the desktop.
    public func waiting(at t: Double) -> Bool { connected(at: t) && (pending != nil || waitingSince != nil) }

    /// The line answering the waiting prompt, or nil when there is nothing that may be answered.
    public func decide(_ approve: Bool, at t: Double) -> String? {
        guard let p = prompt(at: t), let since = pending?.since else { return nil }
        answered = p.id; pending = nil
        if approve { approved += 1 } else { denied += 1 }
        lastAnswer = t - since
        if approve && t - since < 5 { flash = (.heart, t + 5) }
        return encode(["cmd": "permission", "id": p.id, "decision": approve ? "once" : "deny"])
    }

    public func mood(at t: Double) -> Mood {
        guard connected(at: t) else { return .sleep }
        if let since = pending?.since ?? waitingSince { return t - since > 30 ? .impatient : .attention }
        if let f = flash, t < f.until { return f.mood }
        if let r = runningSince {
            let words = activity.lowercased().split { !$0.isLetter }
            if words.contains(where: { w in ["read", "search", "grep", "glob", "find", "fetch", "explor"].contains { w.hasPrefix($0) } }) { return .curious }
            return t - r >= 120 ? .focused : .busy
        }
        if let i = idleSince, t - i >= 1800 { return .bored }
        return .idle
    }

    private func heartbeat(_ o: [String: Any], at t: Double) {
        heard = t
        let running = (o["running"] as? NSNumber)?.intValue ?? 0
        activity = ([o["msg"] as? String ?? ""] + ((o["entries"] as? [String])?.prefix(1) ?? [])).joined(separator: " ")
        if running > 0 {
            runningSince = runningSince ?? t
        } else if let r = runningSince {
            if t - r >= 120 { flash = (.proud, t + 5) }
            runningSince = nil
        }
        if let p = o["prompt"] as? [String: Any], let id = p["id"] as? String {
            if id == answered { pending = nil }
            else if pending?.prompt.id != id { pending = (Prompt(id: id, tool: p["tool"] as? String ?? "", hint: p["hint"] as? String ?? ""), t) }
        } else {
            pending = nil
        }
        // A prompt this pad already answered still counts as waiting until the desktop catches up; don't show it again.
        let waiting = (o["waiting"] as? NSNumber)?.intValue ?? 0
        let answeredOnly = answered != nil && (o["prompt"] as? [String: Any])?["id"] as? String == answered && waiting <= 1
        waitingSince = waiting > 0 && pending == nil && !answeredOnly ? waitingSince ?? t : nil
        idleSince = running == 0 && pending == nil && waitingSince == nil ? idleSince ?? t : nil
        if let tokens = (o["tokens"] as? NSNumber)?.intValue {
            let step = tokens / 50_000
            if let s = tokenStep, step > s { flash = (.celebrate, t + 5) }
            tokenStep = step
        }
    }

    private func command(_ cmd: String, _ o: [String: Any], at t: Double) -> String? {
        switch cmd {
        case "status":
            // The desktop drops a status that lacks any of these fields, so unknown ones are sent as 0.
            let data: [String: Any] = [
                "name": name, "sec": secure,
                "bat": ["pct": battery?.pct ?? 0, "mV": 0, "mA": 0, "usb": battery?.usb ?? false],
                "sys": ["up": Int(t - start), "heap": heap],
                "stats": ["appr": approved, "deny": denied, "vel": Int(lastAnswer.rounded()), "nap": 0, "lvl": 0],
            ]
            return encode(["ack": cmd, "ok": true, "n": 0, "data": data])
        case "name":
            if let n = o["name"] as? String { name = n }
        case "owner":
            owner = o["name"] as? String
        case "unpair":
            break // iOS keeps the bond itself; the next pairing comes from forgetting it there.
        case "char_begin", "file", "chunk", "file_end", "char_end":
            return nil // Not acking char_begin declines a folder push.
        default:
            return encode(["ack": cmd, "ok": false, "n": 0, "error": "unknown command"])
        }
        return encode(["ack": cmd, "ok": true, "n": 0])
    }

    private func encode(_ o: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: o, options: .withoutEscapingSlashes), as: UTF8.self) + "\n"
    }
}

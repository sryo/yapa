import Darwin
import Foundation

/// A Claude Code session running on this Mac outside the Claude app: its process, folder, and what its record says
/// it's doing (`idle`, `busy`, `waiting` on a dialog, or `shell` mode).
public struct LiveSession: Equatable {
    public let pid: Int32, cwd: String, status: String?
    public init(pid: Int32, cwd: String, status: String?) { self.pid = pid; self.cwd = cwd; self.status = status }

    /// Whether keys typed into its terminal reach its prompt: idle, or busy (they queue). A dialog takes them as its
    /// answer, shell mode runs them.
    public var takesText: Bool { status == "idle" || status == "busy" }
}

/// The running session whose id is `cli`, from the record Claude Code keeps for each one under `root`
/// (`~/.claude/sessions/<pid>.json`). The record outlives a process that died without cleaning up, and its pid can be
/// reused, so it counts only while `started` (a process's start, as `processStart` reads it) still says what the
/// record wrote.
public func liveSession(cli: String, in root: URL, started: (Int32) -> String?) -> LiveSession? {
    guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
    for f in files where f.pathExtension == "json" {
        guard let d = try? Data(contentsOf: f), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              o["sessionId"] as? String == cli, let pid = (o["pid"] as? NSNumber)?.int32Value,
              let start = o["procStart"] as? String, started(pid) == start else { continue }
        return LiveSession(pid: pid, cwd: o["cwd"] as? String ?? "", status: o["status"] as? String)
    }
    return nil
}

private func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
    guard pid > 0 else { return nil }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
}

/// When process `pid` started, written as `ps -o lstart` writes it in UTC ("Mon Nov  9 05:59:25 2026"), which is how
/// Claude Code's session records say it; nil when there's no such process.
public func processStart(_ pid: Int32) -> String? {
    guard let info = bsdInfo(pid) else { return nil }
    var t = time_t(info.pbi_start_tvsec), tm = tm()
    gmtime_r(&t, &tm)
    var out = [CChar](repeating: 0, count: 64)
    let n = strftime(&out, out.count, "%a %b %e %H:%M:%S %Y", &tm)
    return n > 0 ? String(cString: out) : nil
}

/// The terminal process `pid` reads from ("/dev/ttys003"); nil when it has none.
public func controllingTTY(_ pid: Int32) -> String? {
    guard let info = bsdInfo(pid), info.e_tdev != UInt32.max, let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR)
    else { return nil }
    return "/dev/" + String(cString: name)
}

/// Session `cli`'s transcript, `<root>/<project>/<cli>.jsonl`, whichever project folder it's in.
public func transcript(cli: String, in root: URL) -> URL? {
    guard !cli.isEmpty, !cli.contains("/"), !cli.hasPrefix("."),
          let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
    return dirs.map { $0.appendingPathComponent("\(cli).jsonl") }.first { FileManager.default.fileExists(atPath: $0.path) }
}

/// Whether a transcript's whole lines have `text` as a prompt of the user's: one it took, or one queued while busy.
public func prompted(transcript: String, text: String) -> Bool {
    func says(_ content: Any?) -> Bool {
        if let s = content as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) == text }
        guard let blocks = content as? [[String: Any]] else { return false }
        return blocks.contains { $0["type"] as? String == "text" && says($0["text"]) }
    }
    for line in transcript.split(separator: "\n", omittingEmptySubsequences: false).dropLast() where line.contains("\"") {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
        if o["type"] as? String == "user", let m = o["message"] as? [String: Any], says(m["content"]) { return true }
        if o["type"] as? String == "attachment", let a = o["attachment"] as? [String: Any],
           a["type"] as? String == "queued_command", says(a["prompt"]) { return true }
        // A busy session writes the prompt it queued at once; its queued_command comes only once a turn takes it.
        if o["type"] as? String == "queue-operation", o["operation"] as? String == "enqueue", says(o["content"]) { return true }
    }
    return false
}

/// What became of text che typed for a session: still on its way (typed and entered, not yet seen arriving), seen
/// arriving, or left on the clipboard.
public enum Delivery: String { case pending, sent, copied }

/// /sent's answer: `state` in a word (null for a delivery che doesn't know), and `sent` true or false once it's settled.
public func sentReply(_ d: Delivery?) -> [String: Any] {
    ["state": d?.rawValue ?? NSNull(), "sent": d == .sent ? true as Any : d == .copied ? false as Any : NSNull()]
}

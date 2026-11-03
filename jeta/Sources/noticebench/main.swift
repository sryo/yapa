import JetaKit
import Foundation

// Replays 1,000 seeded streams of Hardware Buddy turn events, as the Claude app forwards them from every session,
// through NoticeBoard. Each stream mixes the manager's notices (in text, or in an echo when the app strips text,
// written with the small slips a model makes) with other sessions' chatter, user turns and talk about the format.
// Prints, as JSON arrays: notices missed, misread and invented per 1,000 streams, and µs per event.
var rng = Seeded(7)
let sessions = ["server", "che", "bluetooth", "push-to-talk", "jeta", "docs"]
let questions = ["Which hostname for the tunnel?", "Merge the branch now?", "Keep the old build?",
                 "Use port 8080 or 8443?", "Is 10 MB a day fine for logs?", "Try again after the reboot?"]

func pick<T>(_ a: [T]) -> T { a[Int.random(in: 0..<a.count, using: &rng)] }
func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
func text(_ s: String, role: String = "assistant") -> [String: Any] { ["evt": "turn", "role": role, "content": [["type": "text", "text": s]]] }
func echo(_ s: String) -> [String: Any] {
    ["evt": "turn", "role": "assistant", "content": [["type": "tool_use", "id": "toolu_x", "name": "Bash", "input": ["command": "echo '\(s)'"]]]]
}

/// A notice as a model might write it: mostly exact, sometimes with extra spaces, a different dot, or a stray
/// period at the end. Returns the line and the question as meant.
func written(_ s: String, _ q: String) -> String {
    switch Int.random(in: 0..<10, using: &rng) {
    case 0: return "jeta:  \(s) needs you  ·  \(q)"
    case 1: return "jeta: \(s) needs you • \(q)"
    case 2: return "jeta: \(s) needs you - \(q)"
    case 3: return "  jeta: \(s) needs you · \(q)  "
    default: return "jeta: \(s) needs you · \(q)"
    }
}

var missed = 0, misread = 0, invented = 0, events = 0, ns: UInt64 = 0
for _ in 0..<1000 {
    var board = NoticeBoard(), want: [String: String] = [:], stream: [[String: Any]] = []
    for _ in 0..<Int.random(in: 6...14, using: &rng) {
        let s = pick(sessions), q = pick(questions)
        switch Int.random(in: 0..<10, using: &rng) {
        case 0, 1: stream.append(text("Running the tests now.\nAll green."))
        case 2: stream.append(text("Notices look like jeta: \(s) needs you · \(q) on the phone."))
        case 3: stream.append(text("jeta: \(s) needs you · \(q)", role: "user"))
        case 4: stream.append(echo("grep -n jeta: notes.md"))
        case 5, 6:
            let line = written(s, q)
            stream.append(chance(0.3) ? echo(line) : text("Checked on the others.\(chance(0.5) ? "\r\n" : "\n")\(line)"))
            want[s] = q
        case 7:
            stream.append(chance(0.3) ? echo("jeta: clear \(s)") : text("jeta: clear \(s)"))
            want[s] = nil
        default:
            stream.append(text("jeta: list · " + sessions.prefix(3).map { "\($0) working" }.joined(separator: "; ")))
        }
    }
    for e in stream {
        let t0 = DispatchTime.now().uptimeNanoseconds
        board.take(e)
        ns += DispatchTime.now().uptimeNanoseconds - t0
        events += 1
    }
    let got = Dictionary(board.pending.map { ($0.session, $0.text) }, uniquingKeysWith: { a, _ in a })
    for (s, q) in want { if let g = got[s] { if g != q { misread += 1 } } else { missed += 1 } }
    invented += got.keys.filter { want[$0] == nil }.count
}
print("[\(missed)]")
print("[\(misread)]")
print("[\(invented)]")
print("[\(String(format: "%.3f", Double(ns) / Double(events) / 1000))]")

/// A seeded generator (splitmix64), so every run replays the same streams.
struct Seeded: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

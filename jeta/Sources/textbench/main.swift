import JetaKit
import Foundation
import simd

// Replays 1,000 seeded runs of jeta's screen on the SE in landscape (568×320 pt) at 60 fps: questions arrive (some
// with options), you tap, swipe both ways, press and choose options, and questions clear, while the face lifts and
// steps aside as the app moves it. Prints, as JSON arrays: frames where a line jumps (moves over 40 pt or changes
// opacity by over 0.35, or appears or vanishes while visible anywhere but at the face or off the screen) per 1,000
// runs; frames where a line resting in its place covers the face per 1,000 runs (lines on their way out of or into
// the face don't count); ms for a change to settle (p50); and µs of CPU per frame of text for each 100 runs. Then
// leaves each screen (a question, its detail, the session list, a reply, a permission request) up for 10 minutes with
// nobody touching the pad, at 30 fps from three start times, and prints the longest s a visible line stays within 1 pt
// of one spot (burn-in), and the longest s any text but a permission request stays up untouched.
var rng = Seeded(5)
let w = 568.0, h = 320.0, u = min(w, h), mid = SIMD2(w / 2, h / 2)
let sessions = ["server", "che", "bluetooth", "docs"]
let questions = ["Which hostname for the tunnel?", "Merge the branch now that every check passes?", "Keep the old build?",
                 "Use port 8080 or 8443?", "Is 10 MB a day fine for the logs, or should we cut them sooner?"]
let options = [["yes", "no"], ["8443", "8080"], ["yapa", "home", "skip"]]

func pick<T>(_ a: [T]) -> T { a[Int.random(in: 0..<a.count, using: &rng)] }
func turn(_ s: String) -> [String: Any] { ["evt": "turn", "role": "assistant", "content": [["type": "text", "text": s]]] }

/// The face's eyes, as a box in points.
func eyes(_ f: Frame) -> (lo: SIMD2<Double>, hi: SIMD2<Double>) {
    let pts = f.eyes.flatMap { $0.outline() }.map { mid + $0 * u }
    return (pts.reduce(pts[0]) { simd_min($0, $1) }, pts.reduce(pts[0]) { simd_max($0, $1) })
}
/// Where the words themselves sit inside a line's frame: about 0.52 em a character, centred or from the left.
func ink(_ s: Shown) -> (lo: SIMD2<Double>, hi: SIMD2<Double>) {
    let wide = min(s.line.width, Double(s.line.text.count) * s.line.size * 0.52) * s.sx, tall = s.line.size * s.sy
    let x = s.line.left ? s.cx - s.line.width / 2 * s.sx : s.cx - wide / 2
    return (SIMD2(x, s.cy - tall / 2), SIMD2(x + wide, s.cy + tall / 2))
}

/// Wholly past an edge of the screen.
func off(_ s: Shown) -> Bool {
    s.cx + s.line.width / 2 * s.sx < 0 || s.cx - s.line.width / 2 * s.sx > w || s.cy + s.line.height / 2 * s.sy < 0
        || s.cy - s.line.height / 2 * s.sy > h
}

var jumps = 0, covered = 0, settles: [Double] = [], ns: UInt64 = 0, frames = 0, batches: [Double] = []
for run in 0..<1000 {
    if run % 100 == 0 && frames > 0 { batches.append(Double(ns) / Double(frames) / 1000); ns = 0; frames = 0 }
    let face = Face(seed: UInt64(run), now: 0)
    face.bounds = SIMD2(max(0, w / u / 2 - 0.27), 0.3)
    face.screen = SIMD2(w / u / 2, h / u / 2)
    let motion = TextMotion()
    motion.screen = SIMD2(w, h)
    var board = NoticeBoard(), screen = Screen(), swipe = 0.0, prev: [Shown] = [], was = Screen.Mode.face
    var last = SIMD2(0.0, 0.0), next = 0.5, changedAt: Double? = nil, choosing: (key: String, at: Double)? = nil
    for k in 0..<480 {
        let t = Double(k) / 60
        if t >= next {
            next = t + Double.random(in: 0.3...1.6, using: &rng)
            let s = pick(sessions)
            switch Int.random(in: 0..<10, using: &rng) {
            case 0, 1, 2:
                let o = Int.random(in: 0..<3, using: &rng) == 0 ? "" : " · " + pick(options).joined(separator: " | ")
                board.take(turn("jeta: \(s) needs you · \(pick(questions))\(o)"))
                screen.update(board)
            case 3, 4: screen.tap()
            case 5, 6: screen.swipe(); swipe = Int.random(in: 0..<2, using: &rng) == 0 ? -1 : 1
            case 7:
                let opts = screen.place(width: w, height: h).filter { $0.style == .option || $0.style == .suggestion }
                if let o = opts.randomElement(using: &rng) { motion.press(o.key, at: t); choosing = (o.key, t + 0.12) }
            case 8: board.take(turn("jeta: clear \(s)")); screen.update(board)
            default: screen.swipeDown()
            }
        }
        if let c = choosing, t >= c.at { motion.choose(c.key, at: t); choosing = nil }
        face.aside(screen.mode == .detail || screen.mode == .roster, at: t)
        face.lift(screen.mode == .question, at: t)
        let f = face.frame(at: t)
        let placed = screen.place(width: w, height: h)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let anchor = mid + f.centre * u
        motion.show(placed, from: anchor, swipe: swipe, wait: Screen.wait(from: was, to: screen.mode), at: t)
        was = screen.mode
        let shown = motion.frame(at: t)
        ns += DispatchTime.now().uptimeNanoseconds - t0
        frames += 1
        swipe = 0
        // Jumps: anything that moves or flashes faster than the eye can follow at 60 fps.
        var jumped = false
        for a in shown {
            if let b = prev.first(where: { $0.line.key == a.line.key }) {
                let seen = (a.opacity > 0.05 && !off(a)) || (b.opacity > 0.05 && !off(b))
                if seen && (hypot(a.cx - b.cx, a.cy - b.cy) > 40 || abs(a.opacity - b.opacity) > 0.35) { jumped = true }
            } else if a.opacity > 0.05 && !off(a) { jumped = true }
        }
        for b in prev where b.opacity > 0.05 && !shown.contains(where: { $0.line.key == b.line.key })
            && simd_distance(SIMD2(b.cx, b.cy), last) > 8 && !off(b) { jumped = true }
        last = anchor
        if jumped { jumps += 1 }
        let e = eyes(f)
        if shown.contains(where: { s in
            let i = ink(s)
            let resting = abs(s.cx - (s.line.x + s.line.width / 2)) < 2 && abs(s.cy - (s.line.y + s.line.height / 2)) < 2
            return resting && s.opacity > 0.5 && i.lo.x < e.hi.x && i.hi.x > e.lo.x && i.lo.y < e.hi.y && i.hi.y > e.lo.y
        }) { covered += 1 }
        // Settling: from a change in what's placed until every line rests where it belongs.
        let still = shown.allSatisfy { s in
            abs(s.cx - (s.line.x + s.line.width / 2)) < 0.5 && abs(s.cy - (s.line.y + s.line.height / 2)) < 0.5
                && (abs(s.opacity - s.line.opacity) < 0.01 || s.line.style == .option)
        }
        if Set(shown.map(\.line.key)) != Set(prev.map(\.line.key)) && changedAt == nil { changedAt = t }
        if still, let c = changedAt { settles.append((t - c) * 1000); changedAt = nil }
        prev = shown
    }
}
batches.append(Double(ns) / Double(frames) / 1000)
settles.sort()

var stillLongest = 0.0, upLongest = 0.0
let left: [(asks: Bool, set: (inout Screen) -> Void)] = [
    (false, { $0.update(board("jeta: server needs you · Use port 8080 or 8443? · 8443 | 8080")) }),
    (false, { $0.update(board("jeta: che needs you · \(questions[4])")); $0.tap() }),
    (false, { $0.update(board("jeta: list · server needs you; che done; docs working")); $0.swipeDown() }),
    (false, { s in
        s.update(replies: [Reply(id: "a", session: "che", text: (0..<12).map { "Line \($0) of what che said." }.joined(separator: "\n"), at: s.now)])
        s.read(session: "a")
    }),
    (true, { $0.ask(session: "che", "Bash: swift build -c release") }),
]
for (asks, set) in left {
    for start in [3.0, 1337.0, 4111.0] {
        let motion = TextMotion()
        motion.screen = SIMD2(w, h)
        var screen = Screen(), rest: [String: (at: SIMD2<Double>, since: Double)] = [:], upSince: Double? = nil
        screen.now = start
        set(&screen)
        for k in 0..<(600 * 30) {
            let t = start + Double(k) / 30
            screen.now = t
            motion.show(screen.place(width: w, height: h), from: mid, at: t)
            let seen = motion.frame(at: t).filter { $0.opacity > 0.05 && !off($0) }
            for s in seen {
                let p = SIMD2(s.cx, s.cy)
                if let r = rest[s.line.key], simd_distance(r.at, p) <= 1 { stillLongest = max(stillLongest, t - r.since) }
                else { rest[s.line.key] = (p, t) }
            }
            if seen.isEmpty || asks { upSince = nil } else { upSince = upSince ?? t; upLongest = max(upLongest, t - upSince!) }
        }
    }
}
func board(_ line: String) -> NoticeBoard { var b = NoticeBoard(); b.take(turn(line)); return b }
print("[\(jumps)]")
print("[\(covered)]")
print("[\(String(format: "%.0f", settles.isEmpty ? 0 : settles[settles.count / 2]))]")
print("[" + batches.map { String(format: "%.3f", $0) }.joined(separator: ", ") + "]")
print("[\(String(format: "%.0f", stillLongest))]")
print("[\(String(format: "%.0f", upLongest))]")

/// A seeded generator (splitmix64), so every run replays the same screens.
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

import Foundation

/// A line of text where it settles on screen, in points: its frame, its font, and how bright it is at rest.
/// `key` names the line across screens, so the same words stay the same line.
public struct Placed: Equatable {
    public var key: String, text: String, style: Screen.Style
    public var x: Double, y: Double, width: Double, height: Double
    public var size: Double, bold: Bool, opacity: Double, left: Bool
}

/// A line as drawn this frame: where its frame's centre is now, how see-through, and how stretched.
public struct Shown: Equatable {
    public var line: Placed
    public var cx: Double, cy: Double, opacity: Double, sx: Double, sy: Double
}

/// The text's motion, with the face's rules: every value is a spring that picks up a new target mid-move, so
/// nothing jumps. Lines come out of the face one after another and overshoot into place; they gather back
/// toward it, quicker, when they go. A line on both screens glides between them. A swipe carries the page the
/// way the finger went. Pressing an option squashes it; choosing it pops it and keeps it lit while the others dim
/// and shrink. Talk's notes fade in where they rest, since they don't come from the face. Settled text holds still: the exaggeration is only in the changes.
public final class TextMotion {
    static let step = 1.0 / 240, stagger = 0.04, travel = 120.0

    final class Item {
        var line: Placed, start: Double
        var cx, cy, op, s, sq: Spring
        var leaving = false, exit = SIMD2<Double>(0, 0)
        init(_ l: Placed, at p: SIMD2<Double>, start: Double) {
            line = l; self.start = start
            cx = Spring(x: p.x); cy = Spring(x: p.y); op = Spring(x: 0); s = Spring(x: 0.6); sq = Spring(x: 0)
        }
        var centre: SIMD2<Double> { SIMD2(line.x + line.width / 2, line.y + line.height / 2) }
    }

    private var items: [Item] = [], last: [Placed]? = nil, now = 0.0
    private var pressed: String?, chosen: String?

    public init() {}

    /// The lines to show, laid out by `Screen.place`; `anchor` is the face's centre, and `swipe` the way the
    /// finger went for a page change (-1 left, 1 right, 0 none). New lines wait `wait` seconds first, so the face
    /// can step out of their way. Showing the same lines again changes nothing.
    public func show(_ lines: [Placed], from anchor: SIMD2<Double>, swipe: Double = 0, wait: Double = 0, at t: Double) {
        advance(to: t)
        guard lines != last else { return }
        last = lines
        let keys = Set(lines.map(\.key))
        for i in items where !i.leaving && !keys.contains(i.line.key) {
            i.leaving = true
            i.exit = swipe != 0 ? SIMD2(i.cx.x + swipe * TextMotion.travel, i.cy.x) : i.centre + (anchor - i.centre) * 0.4
        }
        var n = 0
        for l in lines {
            if let i = items.first(where: { $0.line.key == l.key }) {
                i.line = l
                i.leaving = false
                continue
            }
            let target = SIMD2(l.x + l.width / 2, l.y + l.height / 2)
            let from = swipe != 0 ? target - SIMD2(swipe * TextMotion.travel, 0)
                : l.key.hasPrefix("note:") ? target : target + (anchor - target) * 0.5
            items.append(Item(l, at: from, start: t + wait + Double(n) * TextMotion.stagger))
            n += 1
        }
        if let c = chosen, !keys.contains(c) { chosen = nil }
        if let p = pressed, !keys.contains(p) { pressed = nil }
    }

    /// A finger down on an option (nil when it lifts).
    public func press(_ key: String?, at t: Double) {
        advance(to: t)
        pressed = key
    }

    /// The option was picked: it pops and stays lit until its question is cleared.
    public func choose(_ key: String, at t: Double) {
        advance(to: t)
        pressed = nil
        chosen = key
        items.first { $0.line.key == key }?.s.v += 4
    }

    public func frame(at t: Double) -> [Shown] {
        advance(to: t)
        return items.map { i in
            let s = max(0, i.s.x), q = max(-0.3, min(0.3, i.sq.x))
            return Shown(line: i.line, cx: i.cx.x, cy: i.cy.x, opacity: max(0, min(1, i.op.x)),
                         sx: s * (1 + 0.5 * q), sy: s * (1 - q))
        }
    }

    private func target(_ i: Item) -> (p: SIMD2<Double>, op: Double, s: Double) {
        if i.leaving { return (i.exit, 0, 0.7) }
        if i.line.key == chosen { return (i.centre, 1, 1.12) }
        let dim = chosen != nil && (i.line.style == .option || i.line.style == .suggestion)
        return (i.centre, i.line.opacity * (dim ? 0.3 : 1), dim ? 0.9 : 1)
    }

    private func advance(to t: Double) {
        // A long gap (the app was in the background) isn't replayed in full; a second is enough to settle.
        var at = max(now, t - 1)
        while at < t {
            let dt = min(TextMotion.step, t - at)
            at += dt
            for i in items where at >= i.start {
                let (p, op, s) = target(i)
                // Entering overshoots; moving glides; leaving is quick and doesn't bounce.
                let (k, d) = i.leaving ? (320.0, 1.0) : i.op.x < 0.5 * op ? (170.0, 0.55) : (120.0, 0.75)
                i.cx.step(to: p.x, k: k, damping: d, dt: dt)
                i.cy.step(to: p.y, k: k, damping: d, dt: dt)
                // Leaving fades faster than it travels, so it's gone before it reaches the face.
                i.op.step(to: op, k: i.leaving ? 600 : k, damping: max(d, 0.8), dt: dt)
                i.s.step(to: s, k: k, damping: d, dt: dt)
                i.sq.step(to: i.line.key == pressed ? 0.14 : 0, k: 400, damping: 0.7, dt: dt)
            }
            items.removeAll { $0.leaving && $0.op.x < 0.01 && abs($0.op.v) < 0.5 }
        }
        now = max(now, t)
    }
}

extension Screen {
    /// Seconds new text waits, going from one mode to another, for the face to get out of its way: stepping
    /// aside for the detail and the session list, rising for a question.
    public static func wait(from a: Mode, to b: Mode) -> Double {
        let side = { (m: Mode) in m == .detail || m == .roster }
        if side(b) && !side(a) { return 0.2 }
        if b == .question && a == .face { return 0.15 }
        return 0
    }

    /// Where each line goes on a `width`×`height` point screen. A question sits under the face, centred, its
    /// options side by side (the suggested one first, bigger and bolder); the detail and the session list take
    /// the right of the screen while the face waits in the corner.
    public func place(width w: Double, height h: Double) -> [Placed] {
        let open = mode == .detail || mode == .roster
        let size = min(w, h) * 0.055, left = open ? w * 0.3 : w * 0.12
        let lines = self.lines(width: max(12, Int((w - left - w * 0.08) / (size * 0.52))))
        let isOption = { (l: Line) in l.style == .option || l.style == .suggestion }
        let options = lines.filter(isOption).count
        let optionWidth = options == 0 ? 0 : min(w * 0.22, (w - (open ? left : w * 0.12) * 2) / Double(options) - 10)
        var optionX = open ? left : (w - (optionWidth + 10) * Double(options) + 10) / 2
        // A note alone, on the bare face, sits at the bottom.
        var y = open ? h * 0.14 : mode == .face ? h - Double(lines.count) * size * 1.3 - size * 0.4 : h * (options > 0 ? 0.6 : 0.66)
        var seen: [String: Int] = [:], out: [Placed] = []
        for (i, l) in lines.enumerated() {
            let id = (isOption(l) ? "option" : l.style == .hint && !note.isEmpty ? "note" : "\(l.style)") + ":" + l.text
            let key = id + (seen[id].map { "#\($0)" } ?? "")
            seen[id, default: 0] += 1
            if isOption(l) {
                let suggested = l.style == .suggestion, s = suggested ? size * 1.35 : size
                let mid = y + size * 0.95
                out.append(Placed(key: key, text: l.text, style: l.style, x: optionX, y: mid - s * 0.62, width: optionWidth,
                                  height: s * 1.4, size: s, bold: suggested, opacity: suggested ? 1 : 0.6, left: open))
                optionX += optionWidth + 10
                if i + 1 < lines.count, !isOption(lines[i + 1]) { y += size * 2.5 }
                continue
            }
            let s = l.style == .title ? size * 1.1 : l.style == .body ? size : size * 0.85
            out.append(Placed(key: key, text: l.text, style: l.style, x: open ? left : 0, y: y, width: open ? w - left : w,
                              height: s * 1.4, size: s, bold: false, opacity: l.style == .title ? 1 : l.style == .body ? 0.65 : 0.4,
                              left: open))
            y += s * (l.style == .hint && i > 0 && lines[i - 1].style != .hint ? 2.0 : 1.5)
        }
        return out
    }
}

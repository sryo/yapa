import Foundation
import simd

/// A line of text where it settles on screen, in points: its frame, its font, and how bright it is at rest.
/// `key` names the line across screens, so the same words stay the same line.
public struct Placed: Equatable {
    public var key: String, text: String, style: Screen.Style
    public var x: Double, y: Double, width: Double, height: Double
    public var size: Double, bold: Bool, opacity: Double, left: Bool
}

/// A line as drawn this frame: where its frame's centre is now, how see-through, how stretched, and how blurred
/// (a radius in points).
public struct Shown: Equatable {
    public var line: Placed
    public var cx: Double, cy: Double, opacity: Double, sx: Double, sy: Double, blur: Double
}

/// The text's motion, with the face's rules: every value is a spring that picks up a new target mid-move, so
/// nothing jumps. And every line comes from somewhere and goes somewhere you can see. What the face says comes out
/// of it: a line starts at the eyes, small, and travels to its place, overshooting a little. What's done goes back:
/// a cleared question returns into the face, readable until it gets there, and the face swallows it; a chosen
/// option is handed to the face the same way, while the options not taken drop off the bottom of the screen. A
/// swipe carries the page off the side it went. A line comes into focus as it appears and blurs as it goes. Talk's notes aren't the face talking, so they rise from the bottom
/// edge and sink back. A line on both screens glides between them, and settled text holds still.
public final class TextMotion {
    static let step = 1.0 / 240, stagger = 0.05
    /// No line moves faster than this, so the eye can still follow it (30 pt a frame at 60 fps).
    static let fastest = 1800.0

    /// The screen's size in points, so lines leaving it know where its edges are.
    public var screen = SIMD2<Double>(568, 320)
    /// The face lets a line go, and takes the last one back.
    public var onSay: (() -> Void)?, onSwallow: (() -> Void)?
    /// The lines last shown.
    public var lines: [Placed] { last ?? [] }

    enum Exit: Equatable { case none, face, drop, side(Double), page(Double), sink }

    final class Item {
        var line: Placed, start: Double, exit = Exit.none, said = false, leads = false, out = 0.0
        var cx, cy, op, s, sq, bl: Spring
        init(_ l: Placed, at p: SIMD2<Double>, scale: Double, opacity: Double, start: Double) {
            line = l; self.start = start
            cx = Spring(x: p.x); cy = Spring(x: p.y); op = Spring(x: opacity); s = Spring(x: scale); sq = Spring(x: 0); bl = Spring(x: 0)
        }
        var home: SIMD2<Double> { SIMD2(line.x + line.width / 2, line.y + line.height / 2) }
        var at: SIMD2<Double> { SIMD2(cx.x, cy.x) }
        var note: Bool { line.key.hasPrefix("note:") }
    }

    private var items: [Item] = [], last: [Placed]? = nil, now = 0.0, anchor = SIMD2<Double>(0, 0)
    private var pressed: String?, gone: Set<String> = []

    public init() {}

    /// The lines to show, laid out by `Screen.place`; `anchor` is the face's centre, and `swipe` the way the
    /// finger went for a page change (-1 left, 1 right, 0 none). New lines wait `wait` seconds first, so the face
    /// can step out of their way. Showing the same lines again only follows the face.
    /// `page` is a scroll: -1 when the text moves up (the next page), 1 down; the lines leave and come that way.
    public func show(_ lines: [Placed], from anchor: SIMD2<Double>, swipe: Double = 0, page: Double = 0, wait: Double = 0, at t: Double) {
        advance(to: t)
        self.anchor = anchor
        guard lines != last else { return }
        last = lines
        let keys = Set(lines.map(\.key))
        gone.formIntersection(keys)
        for i in items where i.exit == .none && !keys.contains(i.line.key) {
            i.exit = swipe != 0 ? .side(swipe) : page != 0 && !i.note ? .page(page) : i.note ? .sink : .face
        }
        var n = 0
        for l in lines where !gone.contains(l.key) {
            if let i = items.first(where: { $0.line.key == l.key }) {
                i.line = l
                i.exit = .none
                continue
            }
            let item = l.key.hasPrefix("note:")
                ? Item(l, at: SIMD2(l.x + l.width / 2, screen.y + l.height), scale: 1, opacity: l.opacity, start: t)
                : page != 0 ? Item(l, at: SIMD2(l.x + l.width / 2, l.y + l.height / 2 - page * screen.y * 0.4), scale: 1, opacity: 0, start: t)
                : Item(l, at: anchor, scale: 0.15, opacity: 0, start: t + wait + Double(n) * TextMotion.stagger)
            // The face says a batch of lines once, as the first one leaves it.
            if !item.note { item.leads = n == 0; n += 1 }
            items.append(item)
        }
        if let p = pressed, !keys.contains(p) { pressed = nil }
    }

    /// A finger down on an option (nil when it lifts).
    public func press(_ key: String?, at t: Double) {
        advance(to: t)
        pressed = key
    }

    /// The option was picked: it pops and goes to the face, and the options not taken drop away.
    public func choose(_ key: String, at t: Double) {
        advance(to: t)
        pressed = nil
        for i in items where i.exit == .none && (i.line.style == .option || i.line.style == .suggestion) {
            gone.insert(i.line.key)
            if i.line.key == key {
                i.exit = .face
                i.s.v += 4
            } else {
                i.exit = .drop
                i.cy.v = -150
            }
        }
    }

    public func frame(at t: Double) -> [Shown] {
        advance(to: t)
        return items.map { i in
            let s = max(0, i.s.x), q = max(-0.3, min(0.3, i.sq.x))
            let op = max(0, min(1, i.op.x)), shown = i.line.opacity > 0 ? min(1, op / i.line.opacity) : 1
            return Shown(line: i.line, cx: i.cx.x, cy: i.cy.x, opacity: op, sx: s * (1 + 0.5 * q), sy: s * (1 - q),
                         blur: i.line.size * 0.35 * max(1 - shown, i.bl.x))
        }
    }

    private func offScreen(_ i: Item) -> Bool {
        let w = i.line.width / 2 * i.s.x, h = i.line.height / 2 * i.s.x
        return i.cx.x + w < 0 || i.cx.x - w > screen.x || i.cy.x + h < 0 || i.cy.x - h > screen.y
    }

    private func advance(to t: Double) {
        // A long gap (the app was in the background) isn't replayed in full; a second is enough to settle.
        var at = max(now, t - 1)
        var said = false, swallowed = false
        while at < t {
            let dt = min(TextMotion.step, t - at)
            at += dt
            // Lines that hadn't left the face yet when they were sent away never show.
            items.removeAll { $0.exit != .none && at < $0.start }
            for i in items where at >= i.start {
                if !i.said { i.said = true; if i.leads { said = true } }
                switch i.exit {
                case .none:
                    let overshoot = simd_distance(i.at, i.home) > 2 && i.s.x < 0.9
                    let (k, d) = overshoot ? (140.0, 0.55) : (120.0, 0.75)
                    i.cx.step(to: i.home.x, k: k, damping: d, dt: dt)
                    i.cy.step(to: i.home.y, k: k, damping: d, dt: dt)
                    i.s.step(to: 1, k: k, damping: d, dt: dt)
                case .face:
                    i.cx.step(to: anchor.x, k: 150, damping: 1, dt: dt)
                    i.cy.step(to: anchor.y, k: 150, damping: 1, dt: dt)
                    i.s.step(to: 0.15, k: 150, damping: 1, dt: dt)
                case .drop:
                    i.cy.v = min(TextMotion.fastest, i.cy.v + 1800 * dt)
                    i.cy.x += i.cy.v * dt
                    i.s.step(to: 0.9, k: 150, damping: 1, dt: dt)
                case .page(let way):
                    i.cy.v = way * min(TextMotion.fastest, max(300, abs(i.cy.v + way * 2400 * dt)))
                    i.cy.x += i.cy.v * dt
                case .side(let way):
                    i.cx.v = way * min(TextMotion.fastest, max(300, abs(i.cx.v + way * 2400 * dt)))
                    i.cx.x += i.cx.v * dt
                case .sink:
                    i.cy.step(to: screen.y + i.line.height, k: 150, damping: 1, dt: dt)
                }
                // The options not taken dim as they fall; heading into the face, a line stays readable until it's
                // nearly there.
                let fade = i.exit == .drop ? 0.5 : i.exit == .face ? min(1, max(0, simd_distance(i.at, anchor) - 6) / 40) : 1
                i.op.step(to: i.line.opacity * fade, k: 900, damping: 0.8, dt: dt)
                i.sq.step(to: i.line.key == pressed ? 0.14 : 0, k: 400, damping: 0.7, dt: dt)
                i.bl.step(to: i.exit == .none ? 0 : 1, k: 120, damping: 1, dt: dt)
                // A long way, from a face in the corner to the bottom of the screen, still moves at a speed the eye follows.
                let speed = (i.cx.v * i.cx.v + i.cy.v * i.cy.v).squareRoot()
                if speed > TextMotion.fastest { i.cx.v *= TextMotion.fastest / speed; i.cy.v *= TextMotion.fastest / speed }
                i.out = i.exit != .none && i.exit != .face && offScreen(i) ? i.out + dt : 0
            }
            // In the face and faded out: swallowed.
            let arrived = items.filter { $0.exit == .face && simd_distance($0.at, anchor) < 10 && $0.op.x < 0.03 }
            if !arrived.isEmpty {
                items.removeAll { a in arrived.contains { $0 === a } }
                if !items.contains(where: { $0.exit == .face }) { swallowed = true }
            }
            // Gone past an edge for a moment: off the screen for good.
            items.removeAll { $0.out > 0.05 }
        }
        now = max(now, t)
        if said { onSay?() }
        if swallowed { onSwallow?() }
    }
}

extension Screen {
    /// Seconds new text waits, going from one mode to another, for the face to get out of its way: stepping
    /// aside for the detail and the session list, rising for a question.
    public static func wait(from a: Mode, to b: Mode) -> Double {
        let side = { (m: Mode) in m == .detail || m == .roster || m == .reply }
        if side(b) && !side(a) { return 0.2 }
        if b == .question && a == .face { return 0.15 }
        return 0
    }

    /// How many characters fit across a line.
    static func columns(width w: Double, height h: Double, open: Bool) -> Int {
        let size = min(w, h) * 0.055, left = open ? w * 0.3 : w * 0.12
        return max(12, Int((w - left - w * 0.08) / (size * 0.52)))
    }

    /// Where each line goes on a `width`×`height` point screen. A question sits under the face, centred, its
    /// options side by side (the suggested one first, bigger and bolder); the detail and the session list take
    /// the right of the screen while the face waits in the corner.
    public func place(width w: Double, height h: Double) -> [Placed] {
        let open = mode == .detail || mode == .roster || mode == .reply
        let size = min(w, h) * 0.055, left = open ? w * 0.3 : w * 0.12
        let lines = self.lines(width: Screen.columns(width: w, height: h, open: open))
        let isOption = { (l: Line) in l.style == .option || l.style == .suggestion }
        let options = lines.filter(isOption).count
        let optionWidth = options == 0 ? 0 : min(w * 0.22, (w - (open ? left : w * 0.12) * 2) / Double(options) - 10)
        var optionX = open ? left : (w - (optionWidth + 10) * Double(options) + 10) / 2
        // A note alone, on the bare face, sits at the bottom. Lines keep clear of the edges by as far as the drift goes.
        let (mx, my) = (11.0, 9.0)
        var y = open ? h * 0.14 : mode == .face ? h - Double(lines.count) * size * 1.3 - size * 0.4 - my : h * (options > 0 ? 0.6 : 0.66)
        var seen: [String: Int] = [:], out: [Placed] = []
        for (i, l) in lines.enumerated() {
            // A box ticked or not is the same option, so it stays where it is.
            let words = isOption(l) && (l.text.hasPrefix("○ ") || l.text.hasPrefix("✓ ")) ? String(l.text.dropFirst(2)) : l.text
            let id = (isOption(l) ? "option" : l.style == .hint && !note.isEmpty ? "note" : "\(l.style)") + ":" + words
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
            out.append(Placed(key: key, text: l.text, style: l.style, x: open ? left : mx, y: y, width: open ? w - left - mx : w - 2 * mx,
                              height: s * 1.4, size: s, bold: false, opacity: l.style == .title ? 1 : l.style == .body ? 0.65 : 0.4,
                              left: open))
            y += s * (l.style == .hint && i > 0 && lines[i - 1].style != .hint ? 2.0 : 1.5)
        }
        let d = drift
        return out.map { var p = $0; p.x += d.x; p.y += d.y; return p }
    }
}

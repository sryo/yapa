import Foundation

/// The pad's dial: what has no other way in, as words to turn through. Two fingers landing open it on its first
/// level (a new session, the server, the tunnel and disk), twisting moves through the words, and letting go on one
/// opens what's under it or does it. A level below the first starts with "back". Sessions aren't on it: they're
/// answered where they are, by tapping, swiping and holding.
///
/// It's typography, like the rest of the screen: the word it's on sits in the middle, big and bold, with what it is
/// under it, and its neighbours above and below, smaller and dimmer the farther they are. The lines are keyed by
/// their words, so turning glides them through the middle; a level opening or closing sends its words back into
/// the face and the new ones out of it.
public struct Dial {
    public struct Item: Equatable {
        public var title: String, detail: String
        /// Letting go on it opens these, or runs `act` (an id the app knows); with neither, it only says something.
        public var children: [Item]?, act: String?
        public init(_ title: String, _ detail: String = "", children: [Item]? = nil, act: String? = nil) {
            self.title = title; self.detail = detail; self.children = children; self.act = act
        }
    }
    public enum Release: Equatable { case opened, back, act(String), nothing }

    /// The first level, rebuilt by the app as what it shows changes.
    public var root: [Item] = []
    public private(set) var isOpen = false
    /// What the last act said, shown under the word until the dial closes.
    public var note = ""
    /// Seconds untouched before it closes on its own.
    public static let unattended = 12.0
    static let back = Item("back")

    private var trail: [String] = [], at = 0, touched = 0.0

    public init() {}

    /// The words on the level open now.
    public var level: [Item] {
        var items = root
        for t in trail {
            guard let i = items.first(where: { $0.title == t }), let c = i.children else { return root }
            items = [Dial.back] + c
        }
        return items
    }
    /// The word it's on, kept in range as the level changes under it.
    public var current: Item? { let l = level; return l.isEmpty ? nil : l[min(at, l.count - 1)] }
    /// The titles of the levels opened, from the first.
    public var path: [String] { trail }

    public mutating func begin(at t: Double) {
        touched = t
        guard !isOpen else { return }
        isOpen = true; trail = []; at = 0; note = ""
    }

    public mutating func turn(_ n: Int, at t: Double) {
        touched = t
        note = ""
        at = max(0, min(level.count - 1, min(at, level.count - 1) + n))
    }

    public mutating func release(at t: Double) -> Release {
        touched = t
        guard let c = current else { return .nothing }
        if c == Dial.back {
            // Back up a level, on the word it came from.
            let from = trail.removeLast()
            at = level.firstIndex { $0.title == from } ?? 0
            return .back
        }
        if c.children != nil {
            trail.append(c.title)
            at = level.count > 1 ? 1 : 0
            return .opened
        }
        return c.act.map { .act($0) } ?? .nothing
    }

    public mutating func close() { isOpen = false; trail = []; note = "" }

    /// Every frame: left alone, it closes.
    public mutating func idle(at t: Double) {
        if isOpen && t - touched > Dial.unattended { close() }
    }

    /// The lines to draw on a `width`×`height` point screen: the levels opened as a small line at the top, the word
    /// it's on in the middle with what it is (or what the last act said) under it, two neighbours either side.
    /// `turn` is how far the fingers have twisted past the last whole step, in steps (-1 to 1): the words roll that
    /// far toward the next one as they twist, so turning shows from the first degree, and settle on the step. Past
    /// either end they give a little and spring back.
    public func place(width w: Double, height h: Double, turn: Double = 0) -> [Placed] {
        guard isOpen else { return [] }
        let size = min(w, h) * 0.055, l = level, here = min(at, max(0, l.count - 1)), mid = h * 0.5
        let key = "dial:" + trail.joined(separator: "/") + ":"
        var out: [Placed] = []
        if !trail.isEmpty {
            let t = trail.joined(separator: " · ")
            out.append(Placed(key: "dial-path:" + t, text: t, style: .hint, x: 0, y: h * 0.1, width: w, height: size * 1.2,
                              size: size * 0.85, bold: false, opacity: 0.4, left: false))
        }
        let end = (turn > 0 && here == l.count - 1) || (turn < 0 && here == 0)
        let f = max(-1, min(1, turn)) * (end ? 0.3 : 1)
        for (i, item) in l.enumerated() where abs(Double(i - here) - f) <= 2.5 {
            // How far from the middle it sits now, in words, and what that makes it: lower, smaller and dimmer.
            let e = Double(i - here) - f, a = abs(e), big = size * 1.6
            let y = mid + e * size * 1.9 + max(0, min(1, e)) * size * 1.1
            let fade = a <= 1 ? 1 - 0.55 * a : 0.45 - 0.27 * min(1, a - 1)
            var p = Placed(key: key + item.title, text: item.title, style: .body, x: 0, y: y - big * 0.7, width: w,
                           height: big * 1.4, size: big, bold: a < 0.5, opacity: max(0, fade), left: false)
            p.scale = a <= 1 ? 1 - 0.3 * a : 0.7 - 0.15 * min(1, a - 1)
            out.append(p)
        }
        let under = note.isEmpty ? l.isEmpty ? "" : l[here].detail : note
        if !under.isEmpty {
            out.append(Placed(key: "dial-detail:" + under, text: under, style: .hint, x: 0, y: mid + size * 1.15, width: w,
                              height: size * 1.2, size: size * 0.85, bold: false, opacity: 0.55, left: false))
        }
        return out
    }
}

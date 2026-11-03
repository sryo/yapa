import simd
import XCTest
@testable import JetaKit

final class TextMotionTests: XCTestCase {
    // The SE in landscape, in points.
    let w = 568.0, h = 320.0
    let face = SIMD2(284.0, 110.0)

    func screen(_ lines: String...) -> Screen {
        var b = NoticeBoard()
        for l in lines { b.take(["evt": "turn", "role": "assistant", "content": [["type": "text", "text": l]]]) }
        var s = Screen()
        s.update(b)
        return s
    }
    func frames(_ m: TextMotion, from a: Double, to b: Double, hz: Double = 60) -> [[Shown]] {
        stride(from: a, through: b, by: 1 / hz).map { m.frame(at: $0) }
    }
    /// The biggest change between two frames in any line that's in both: points moved, and opacity.
    func jump(_ x: [Shown], _ y: [Shown]) -> (Double, Double) {
        var d = 0.0, o = 0.0
        for a in x { if let b = y.first(where: { $0.line.key == a.line.key }) {
            d = max(d, hypot(a.cx - b.cx, a.cy - b.cy)); o = max(o, abs(a.opacity - b.opacity))
        } }
        return (d, o)
    }
    func settled(_ s: Shown) -> Bool {
        abs(s.cx - (s.line.x + s.line.width / 2)) < 0.5 && abs(s.cy - (s.line.y + s.line.height / 2)) < 0.5
            && abs(s.opacity - s.line.opacity) < 0.01 && abs(s.sx - 1) < 0.01 && abs(s.sy - 1) < 0.01
    }
    var question: Screen { screen("jeta: server needs you · Which port? · 8443 | 8080") }

    // T1: lines come out of the face: they start see-through, small and near it, then settle where they belong.
    func testT1_LinesEnterFromTheFaceAndSettle() {
        let m = TextMotion(), placed = question.place(width: w, height: h)
        m.show(placed, from: face, at: 0)
        let first = m.frame(at: 0)
        XCTAssertEqual(first.count, placed.count)
        for s in first {
            XCTAssertLessThan(s.opacity, 0.05, "\(s.line.text) pops in")
            XCTAssertLessThan(s.sx, 0.9, "\(s.line.text) starts full size")
            let target = SIMD2(s.line.x + s.line.width / 2, s.line.y + s.line.height / 2)
            XCTAssertLessThan(simd_distance(SIMD2(s.cx, s.cy), face), simd_distance(target, face), "\(s.line.text) doesn't come from the face")
        }
        XCTAssert(m.frame(at: 1.2).allSatisfy(settled), "lines haven't settled after 1.2 s")
    }

    // T1: entrances are exaggerated (they overshoot) and staggered, one line after another.
    func testT1_EntrancesOvershootAndStagger() {
        let m = TextMotion(), placed = question.place(width: w, height: h)
        m.show(placed, from: face, at: 0)
        let fs = frames(m, from: 0, to: 1, hz: 240)
        let peak = fs.map { $0[0].sx }.max()!
        XCTAssertGreaterThan(peak, 1.02, "the entrance doesn't overshoot")
        let early = m.frame(at: 0.06)
        XCTAssertGreaterThan(early[0].opacity, early.last!.opacity + 0.05, "lines don't come in one after another")
    }

    // T2: nothing jumps: at 60 fps no line moves more than a step or blinks in or out, through any change.
    func testT2_NothingJumps() {
        let m = TextMotion()
        var s = screen("jeta: server needs you · Which port? · 8443 | 8080", "jeta: che needs you · Merge now?")
        var all: [[Shown]] = []
        m.show(s.place(width: w, height: h), from: face, at: 0)
        all += frames(m, from: 0, to: 0.15)
        s.tap()                                                // detail, mid-entrance
        m.show(s.place(width: w, height: h), from: SIMD2(80, 50), at: 0.15)
        all += frames(m, from: 0.15, to: 0.5)
        s.swipe()                                              // next session
        m.show(s.place(width: w, height: h), from: SIMD2(80, 50), swipe: -1, at: 0.5)
        all += frames(m, from: 0.5, to: 1)
        m.show([], from: face, at: 1)                          // cleared
        all += frames(m, from: 1, to: 2)
        for (x, y) in zip(all, all.dropFirst()) {
            let (d, o) = jump(x, y)
            XCTAssertLessThan(d, 40, "a line jumps \(d) pt in one frame")
            XCTAssertLessThan(o, 0.35, "a line blinks by \(o) in one frame")
            for a in x where !y.contains(where: { $0.line.key == a.line.key }) {
                XCTAssertLessThan(a.opacity, 0.05, "\(a.line.text) vanishes while visible")
            }
            for b in y where !x.contains(where: { $0.line.key == b.line.key }) {
                XCTAssertLessThan(b.opacity, 0.05, "\(b.line.text) appears already visible")
            }
        }
        XCTAssert(m.frame(at: 2).isEmpty, "cleared lines linger")
    }

    // T3: a line on both screens keeps its identity: it glides to its new place instead of fading out and in.
    func testT3_SharedLinesGlide() {
        let m = TextMotion()
        var s = screen("jeta: server needs you · Which port? · 8443 | 8080")
        m.show(s.place(width: w, height: h), from: face, at: 0)
        _ = m.frame(at: 1.5)
        let before = m.frame(at: 1.5).first { $0.line.text == "8443" }!
        s.tap()
        m.show(s.place(width: w, height: h), from: SIMD2(80, 50), at: 1.5)
        let fs = frames(m, from: 1.5, to: 2.5)
        let path = fs.compactMap { $0.first { $0.line.key == before.line.key } }
        XCTAssertEqual(path.count, fs.count, "the option left the screen instead of moving")
        XCTAssertGreaterThan(path.map(\.opacity).min()!, 0.5, "the option faded out on the way")
        XCTAssertGreaterThan(hypot(path.last!.cx - before.cx, path.last!.cy - before.cy), 20, "the option didn't move to the detail's place")
        XCTAssert(settled(path.last!))
    }

    // T4: calling show with the same lines every frame changes nothing: the entrance isn't restarted.
    func testT4_SameLinesDontRestart() {
        let m = TextMotion(), placed = question.place(width: w, height: h)
        for t in stride(from: 0.0, through: 1.2, by: 1 / 60) { m.show(placed, from: face, at: t); _ = m.frame(at: t) }
        XCTAssert(m.frame(at: 1.2).allSatisfy(settled))
    }

    // T5: a swipe moves the page the way the finger went: the old lines leave that way, the new ones come from the other.
    func testT5_SwipesHaveADirection() {
        let m = TextMotion()
        var s = screen("jeta: server needs you · Which port?", "jeta: che needs you · Merge now?")
        s.tap()
        m.show(s.place(width: w, height: h), from: SIMD2(80, 50), at: 0)
        let old = m.frame(at: 1.5)
        s.swipe()
        m.show(s.place(width: w, height: h), from: SIMD2(80, 50), swipe: -1, at: 1.5)
        let later = m.frame(at: 1.6)
        let leaving = later.filter { l in old.contains { $0.line.key == l.line.key } && !s.place(width: w, height: h).contains { $0.key == l.line.key } }
        let coming = later.filter { l in !old.contains { $0.line.key == l.line.key } }
        XCTAssertFalse(leaving.isEmpty); XCTAssertFalse(coming.isEmpty)
        for l in leaving { XCTAssertLessThan(l.cx, l.line.x + l.line.width / 2, "\(l.line.text) doesn't leave to the left") }
        for l in coming { XCTAssertGreaterThan(l.cx, l.line.x + l.line.width / 2, "\(l.line.text) doesn't come from the right") }
    }

    // T6: pressing an option squashes it; choosing it pops it in place while the others dim, until it's cleared.
    func testT6_OptionsRespond() {
        let m = TextMotion(), placed = question.place(width: w, height: h)
        m.show(placed, from: face, at: 0)
        _ = m.frame(at: 1.5)
        let key = placed.first { $0.text == "8443" }!.key
        m.press(key, at: 1.5)
        let pressed = m.frame(at: 1.6).first { $0.line.key == key }!
        XCTAssertLessThan(pressed.sy, 0.95, "pressing doesn't squash it")
        XCTAssertGreaterThan(pressed.sx, pressed.sy, "it doesn't squash flat under the finger")
        m.choose(key, at: 1.6)
        let fs = frames(m, from: 1.6, to: 3, hz: 240)
        let chosen = fs.compactMap { $0.first { $0.line.key == key } }
        XCTAssertGreaterThan(chosen.map(\.sx).max()!, 1.08, "choosing doesn't pop it")
        let end = fs.last!
        let c = end.first { $0.line.key == key }!, other = end.first { $0.line.text == "8080" }!
        XCTAssertEqual(c.cx, c.line.x + c.line.width / 2, accuracy: 0.5, "the chosen option leaves its place")
        XCTAssertEqual(c.cy, c.line.y + c.line.height / 2, accuracy: 0.5, "the chosen option leaves its place")
        XCTAssertLessThan(other.opacity, 0.35, "the other options don't dim")
        XCTAssertGreaterThan(c.opacity, 0.9, "the chosen option doesn't stay lit")
        m.show([], from: face, at: 3)
        XCTAssert(m.frame(at: 4).isEmpty)
    }

    // T8: Talk's notes (listening, sending, what che typed) take the hint's place, as a line like any other; on the
    // bare face the note sits alone at the bottom.
    func testT8_NotesReplaceTheHint() {
        var s = question
        s.note = "Sending…"
        let p = s.place(width: w, height: h)
        XCTAssertEqual(p.last?.text, "Sending…")
        let m = TextMotion()
        m.show(p, from: face, at: 0)
        let n = m.frame(at: 0).last!
        XCTAssertEqual(n.cy, n.line.y + n.line.height / 2, accuracy: 0.5, "the note flies in from the face across the options")
        XCTAssertFalse(p.contains { $0.text.hasPrefix("tap") }, "the hint stays under the note")
        var bare = Screen()
        bare.note = "Mac didn't answer: is che running?"
        let b = bare.place(width: w, height: h)
        XCTAssertEqual(b.map(\.text), ["Mac didn't answer: is che running?"])
        XCTAssertGreaterThan(b[0].y, h * 0.8, "the note doesn't sit at the bottom")
        bare.note = ""
        XCTAssert(bare.place(width: w, height: h).isEmpty)
    }

    // T7: the layout keeps every line on screen, lines apart from each other, and the question below the lifted face.
    func testT7_LayoutFits() {
        var s = screen("jeta: server needs you · Which hostname for the tunnel? · yapa | home | skip", "jeta: che needs you · x")
        for k in 0..<4 {
            if k == 3 { s.note = "Listening… (no Mac found yet: is che running?)" }
            let p = s.place(width: w, height: h)
            for l in p {
                XCTAssertGreaterThanOrEqual(l.x, 0); XCTAssertLessThanOrEqual(l.x + l.width, w + 0.5, "\(l.text) runs off the right")
                XCTAssertLessThanOrEqual(l.y + l.height, h, "\(l.text) runs off the bottom")
            }
            for (i, a) in p.enumerated() { for b in p[(i + 1)...] {
                let r = CGRect(x: a.x, y: a.y, width: a.width, height: a.height), q = CGRect(x: b.x, y: b.y, width: b.width, height: b.height)
                XCTAssertFalse(r.insetBy(dx: 1, dy: 1).intersects(q.insetBy(dx: 1, dy: 1)), "\(a.text) overlaps \(b.text)")
            } }
            XCTAssertEqual(Set(p.map(\.key)).count, p.count, "two lines share a key")
            s.tap()
        }
    }
}

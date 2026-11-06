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
    func motion() -> TextMotion {
        let m = TextMotion()
        m.screen = SIMD2(w, h)
        return m
    }
    func frames(_ m: TextMotion, from a: Double, to b: Double, hz: Double = 60, face f: SIMD2<Double>? = nil) -> [[Shown]] {
        stride(from: a, through: b, by: 1 / hz).map { t in
            if let f { m.show(m.lines, from: f, at: t) }
            return m.frame(at: t)
        }
    }
    func centre(_ s: Shown) -> SIMD2<Double> { SIMD2(s.cx, s.cy) }
    func home(_ s: Shown) -> SIMD2<Double> { SIMD2(s.line.x + s.line.width / 2, s.line.y + s.line.height / 2) }
    func offScreen(_ s: Shown) -> Bool {
        s.cx + s.line.width / 2 * s.sx < 0 || s.cx - s.line.width / 2 * s.sx > w
            || s.cy + s.line.height / 2 * s.sy < 0 || s.cy - s.line.height / 2 * s.sy > h
    }
    func settled(_ s: Shown) -> Bool {
        simd_distance(centre(s), home(s)) < 0.5 && abs(s.opacity - s.line.opacity) < 0.01
            && abs(s.sx - 1) < 0.01 && abs(s.sy - 1) < 0.01
    }
    var question: Screen { screen("jeta: server needs you · Which port? · 8443 | 8080") }

    // T1: what the face says comes out of it: each line starts at the eyes, small, shows while it's still there,
    // and travels the whole way to its place.
    func testT1_LinesComeOutOfTheFace() {
        let m = motion(), placed = question.place(width: w, height: h)
        m.show(placed, from: face, at: 0)
        let first = m.frame(at: 0)
        XCTAssertEqual(first.count, placed.count)
        for s in first {
            XCTAssertLessThan(simd_distance(centre(s), face), 1, "\(s.line.text) doesn't start at the face")
            XCTAssertLessThan(s.sx, 0.3, "\(s.line.text) starts full size")
            XCTAssertLessThan(s.opacity, 0.05, "\(s.line.text) is visible before it leaves the face")
        }
        let early = m.frame(at: 0.06)[0]
        XCTAssertGreaterThan(early.opacity, 0.3, "the first line isn't visible as it leaves the face")
        XCTAssertLessThan(simd_distance(centre(early), face), simd_distance(home(early), face) * 0.5, "it shows up away from the face")
        XCTAssert(m.frame(at: 1.4).allSatisfy(settled), "lines haven't settled after 1.4 s")
    }

    // T1: entrances are exaggerated (they overshoot), staggered, and the face reacts as it says them.
    func testT1_EntrancesOvershootStaggerAndTheFaceSaysThem() {
        let m = motion(), placed = question.place(width: w, height: h)
        var said = 0
        m.onSay = { said += 1 }
        m.show(placed, from: face, at: 0)
        let fs = frames(m, from: 0, to: 1, hz: 240)
        XCTAssertGreaterThan(fs.map { $0[0].sx }.max()!, 1.02, "the entrance doesn't overshoot")
        let early = m.frame(at: 0.08)
        XCTAssertGreaterThan(early[0].opacity, early.last!.opacity + 0.05, "lines don't come in one after another")
        XCTAssertEqual(said, 1, "the face doesn't say it once")
    }

    // T2: nothing jumps, and nothing appears or vanishes anywhere but at the face or off the screen.
    func testT2_LinesComeAndGoOnlyAtTheFaceOrTheEdge() {
        let m = motion()
        var s = screen("jeta: server needs you · Which port? · 8443 | 8080", "jeta: che needs you · Merge now?")
        var all: [[Shown]] = [], anchors: [SIMD2<Double>] = []
        func run(_ a: Double, _ b: Double, _ f: SIMD2<Double>) {
            all += frames(m, from: a, to: b, face: f); anchors += stride(from: a, through: b, by: 1 / 60).map { _ in f }
        }
        m.show(s.place(width: w, height: h), from: face, at: 0)
        run(0, 0.15, face)
        s.tap()                                                // detail, mid-entrance
        m.show(s.place(width: w, height: h), from: SIMD2(80, 50), at: 0.15)
        run(0.15, 0.5, SIMD2(80, 50))
        s.swipe()                                              // next session
        m.show(s.place(width: w, height: h), from: SIMD2(80, 50), swipe: -1, at: 0.5)
        run(0.5, 1.2, SIMD2(80, 50))
        m.show([], from: face, at: 1.2)                        // cleared
        run(1.2, 2.6, face)
        for (k, (x, y)) in zip(all, all.dropFirst()).enumerated() {
            for a in x { if let b = y.first(where: { $0.line.key == a.line.key }) {
                XCTAssertLessThan(simd_distance(centre(a), centre(b)), 40, "\(a.line.text) jumps")
                XCTAssertLessThan(abs(a.opacity - b.opacity), 0.35, "\(a.line.text) blinks")
                XCTAssertLessThan(abs(a.blur - b.blur), 2, "\(a.line.text) snaps in or out of focus")
            } }
            for a in x where !y.contains(where: { $0.line.key == a.line.key }) && a.opacity > 0.05 {
                XCTAssert(simd_distance(centre(a), anchors[k]) < 8 || offScreen(a), "\(a.line.text) vanishes in mid-air at \(centre(a))")
            }
            for b in y where !x.contains(where: { $0.line.key == b.line.key }) {
                XCTAssert(b.opacity < 0.05 || offScreen(b), "\(b.line.text) appears out of nowhere")
            }
        }
        XCTAssert(m.frame(at: 2.6).isEmpty, "cleared lines linger")
    }

    // T3: a cleared question goes back into the face, readable most of the way, and the face swallows it.
    func testT3_ClearedLinesGoBackIntoTheFace() {
        let m = motion()
        var swallowed = 0
        m.onSwallow = { swallowed += 1 }
        m.show(question.place(width: w, height: h), from: face, at: 0)
        let before = m.frame(at: 1.5)
        m.show([], from: face, at: 1.5)
        let fs = frames(m, from: 1.5, to: 2.5, face: face)
        let title = fs.compactMap { $0.first { $0.line.style == .title } }
        let halfway = title.first { simd_distance(centre($0), face) < simd_distance(home($0), face) * 0.5 }
        XCTAssertNotNil(halfway, "the title doesn't head into the face")
        XCTAssertGreaterThan(halfway!.opacity, 0.5, "the title fades out before it gets near the face")
        XCTAssert(fs.last!.isEmpty)
        XCTAssertGreaterThan(before.count, 0)
        XCTAssertEqual(swallowed, 1, "the face doesn't swallow once")
    }

    // T4: a line on both screens keeps its identity: it glides to its new place instead of going and coming back.
    func testT4_SharedLinesGlide() {
        let m = motion()
        var s = question
        m.show(s.place(width: w, height: h), from: face, at: 0)
        let before = m.frame(at: 1.5).first { $0.line.text == "8443" }!
        s.tap()
        m.show(s.place(width: w, height: h), from: SIMD2(80, 50), at: 1.5)
        let fs = frames(m, from: 1.5, to: 2.5)
        let path = fs.compactMap { $0.first { $0.line.key == before.line.key } }
        XCTAssertEqual(path.count, fs.count, "the option left the screen instead of moving")
        XCTAssertGreaterThan(path.map(\.opacity).min()!, 0.5, "the option faded out on the way")
        XCTAssertGreaterThan(simd_distance(centre(path.last!), centre(before)), 20, "the option didn't move to the detail's place")
        XCTAssert(settled(path.last!))
    }

    // T4: calling show with the same lines every frame changes nothing: the entrance isn't restarted.
    func testT4_SameLinesDontRestart() {
        let m = motion(), placed = question.place(width: w, height: h)
        for t in stride(from: 0.0, through: 1.4, by: 1 / 60) { m.show(placed, from: face, at: t); _ = m.frame(at: t) }
        XCTAssert(m.frame(at: 1.4).allSatisfy(settled))
    }

    // T5: a swipe carries the page off the screen the way the finger went; the next session's lines come out of the face.
    func testT5_SwipesCarryThePageAway() {
        let m = motion(), corner = SIMD2(80.0, 50.0)
        var s = screen("jeta: server needs you · Which port?", "jeta: che needs you · Merge now?")
        s.tap()
        m.show(s.place(width: w, height: h), from: corner, at: 0)
        let old = Set(m.frame(at: 1.5).map(\.line.key))
        s.swipe()
        let next = s.place(width: w, height: h)
        m.show(next, from: corner, swipe: -1, at: 1.5)
        let start = m.frame(at: 1.5)
        let fs = frames(m, from: 1.5, to: 2.5, face: corner)
        for l in start where old.contains(l.line.key) && !next.contains(where: { $0.key == l.line.key }) {
            let path = fs.compactMap { $0.first { $0.line.key == l.line.key } }
            XCTAssertLessThan(path.last.map(\.cx) ?? -1, l.cx, "\(l.line.text) doesn't go left")
            XCTAssert(path.last.map(offScreen) ?? true, "\(l.line.text) stops before the edge")
        }
        for l in start where !old.contains(l.line.key) {
            XCTAssertLessThan(simd_distance(centre(l), corner), 1, "\(l.line.text) doesn't come out of the face")
        }
    }

    // T5: while a finger drags sideways the lines follow it 1:1, and let go short, they glide back with no jump.
    func testT5_TextFollowsTheFinger() {
        let m = motion(), placed = question.place(width: w, height: h)
        m.show(placed, from: face, at: 0)
        _ = frames(m, from: 0, to: 1.5, face: face)
        var t = 1.5
        for dx in stride(from: 0.0, through: -90, by: -6) {
            t += 1 / 60
            m.hold(dx, at: t)
            for l in m.frame(at: t) { XCTAssertEqual(l.cx - (l.line.x + l.line.width / 2), dx, accuracy: 0.5, "\(l.line.text) lags the finger") }
        }
        m.hold(nil, speed: -300, at: t)
        let back = frames(m, from: t, to: t + 1.5, face: face)
        for (a, b) in zip(back, back.dropFirst()) {
            for (x, y) in zip(a, b) { XCTAssertLessThan(abs(y.cx - x.cx), 30, "\(x.line.text) jumps on the way back") }
        }
        XCTAssert(m.frame(at: t + 1.5).allSatisfy(settled), "let go, the lines don't go home")
    }

    // T6: pressing an option squashes it; choosing it pops it and hands it to the face, which swallows it, while
    // the other options drop off the bottom of the screen. Neither comes back while the question stays up.
    func testT6_ChosenOptionsGoToTheFaceAndTheRestDrop() {
        let m = motion(), placed = question.place(width: w, height: h)
        var swallowed = 0
        m.onSwallow = { swallowed += 1 }
        m.show(placed, from: face, at: 0)
        _ = m.frame(at: 1.5)
        let key = placed.first { $0.text == "8443" }!.key, other = placed.first { $0.text == "8080" }!.key
        m.press(key, at: 1.5)
        let pressed = m.frame(at: 1.6).first { $0.line.key == key }!
        XCTAssertLessThan(pressed.sy, 0.95, "pressing doesn't squash it")
        XCTAssertGreaterThan(pressed.sx, pressed.sy, "it doesn't squash flat under the finger")
        m.choose(key, at: 1.6)
        let fs = frames(m, from: 1.6, to: 3.2, hz: 240, face: face)
        let chosen = fs.compactMap { $0.first { $0.line.key == key } }
        XCTAssertGreaterThan(chosen.map(\.sx).max()!, 1.05, "choosing doesn't pop it")
        XCTAssertLessThan(simd_distance(centre(chosen.last!), face), 8, "the chosen option doesn't reach the face")
        let dropped = fs.compactMap { $0.first { $0.line.key == other } }
        XCTAssert(dropped.last.map(offScreen) ?? false, "the other option doesn't drop off the screen")
        XCTAssertGreaterThan(dropped.last!.cy, h, "the other option doesn't go down")
        XCTAssertFalse(fs.last!.contains { $0.line.key == key || $0.line.key == other }, "the options come back")
        XCTAssertEqual(swallowed, 1)
        XCTAssert(fs.last!.contains { $0.line.style == .title }, "the question goes with its answer")
    }

    // T9: lines blur as they appear and disappear, and are sharp once they've settled.
    func testT9_LinesBlurInAndOut() {
        let m = motion()
        m.show(question.place(width: w, height: h), from: face, at: 0)
        XCTAssert(m.frame(at: 0.02).allSatisfy { $0.blur > 4 }, "lines aren't blurred as they leave the face")
        let settledLines = m.frame(at: 1.5)
        XCTAssert(settledLines.allSatisfy { $0.blur < 0.05 }, "settled lines stay blurred")
        m.show([], from: face, at: 1.5)
        let fs = frames(m, from: 1.5, to: 2.5, face: face)
        let title = fs.compactMap { $0.first { $0.line.style == .title } }
        XCTAssertGreaterThan(title.last!.blur, 4, "the title doesn't blur as it goes")
        XCTAssertLessThan(title[title.count / 4].blur, title.last!.blur, "the blur doesn't grow as it goes")
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

    // T7: options too long to sit side by side, popped as when chosen, go one per row, each whole and on screen.
    func testT7_LongOptionsGoOnePerRow() {
        let s = screen("jeta: server needs you · Which way? · keep the old build | rebuild everything from scratch | skip")
        let o = s.place(width: w, height: h).filter { $0.style == .option || $0.style == .suggestion }
        XCTAssertEqual(o.count, 3)
        XCTAssertEqual(Set(o.map(\.y)).count, 3, "options share a row")
        for l in o {
            XCTAssertLessThanOrEqual(Double(l.text.count) * l.size * 0.52 * 1.15, l.width, "\(l.text) doesn't fit popped")
            XCTAssertLessThanOrEqual(l.y + l.height, h, "\(l.text) runs off the bottom")
        }
        let short = question.place(width: w, height: h).filter { $0.style == .option || $0.style == .suggestion }
        XCTAssertEqual(Set(short.map(\.y)).count <= 2 && short[0].x != short[1].x, true, "short options stay side by side")
    }

    // T8: Talk's notes (listening, sending, what che typed) take the hint's place; they rise from the bottom edge
    // and sink back below it, since the face isn't what's saying them.
    func testT8_NotesRiseFromTheBottom() {
        var s = question
        s.note = "Sending…"
        let p = s.place(width: w, height: h)
        XCTAssertEqual(p.last?.text, "Sending…")
        XCTAssertFalse(p.contains { $0.text.hasPrefix("tap") }, "the hint stays under the note")
        let m = motion()
        m.show(p, from: face, at: 0)
        XCTAssert(offScreen(m.frame(at: 0).last!), "the note doesn't start below the screen")
        s.note = ""
        m.show(s.place(width: w, height: h), from: face, at: 1.5)
        let fs = frames(m, from: 1.5, to: 2.5)
        let path = fs.compactMap { $0.first { $0.line.text == "Sending…" } }
        XCTAssert(offScreen(path.last!) && path.last!.cy > h, "the note doesn't sink below the screen")
        var bare = Screen()
        bare.note = "Mac didn't answer: is che running?"
        let b = bare.place(width: w, height: h)
        XCTAssertEqual(b.map(\.text), ["Mac didn't answer: is che running?"])
        XCTAssertGreaterThan(b[0].y, h * 0.8, "the note doesn't sit at the bottom")
    }
}

import simd
import XCTest
@testable import JetaKit

final class ColonyTests: XCTestCase {
    // One ant per session; one that ends walks off the screen and is gone.
    func testOneAntPerSession() {
        let c = Colony(seed: 1, now: 0)
        c.update([("a", .idle, false, nil), ("b", .busy, false, nil)], at: 0)
        XCTAssertEqual(c.shapes(at: 1).count, 2)
        c.update([("a", .idle, false, nil)], at: 1)
        var t = 1.0
        while c.shapes(at: t).count > 1 && t < 30 { t += 0.5 }
        XCTAssertEqual(c.shapes(at: t).map(\.id), ["a"], "b walked off")
    }

    // A new ant grows in from nothing, and every part of it is drawn from its first frame on.
    func testNewAntIsWhole() {
        let c = Colony(seed: 1, now: 0)
        c.update([("a", .idle, true, nil)], at: 0)
        for t in [0.02, 1.0, 5.0] {
            let s = c.shapes(at: t)[0]
            XCTAssertEqual(s.fills.count, 4)
            XCTAssertFalse((s.fills.flatMap { $0 } + s.strokes.flatMap(\.points)).contains { $0.x.isNaN || $0.y.isNaN })
        }
    }

    // A planted foot never slides: a foot moves only while it's in the air.
    func testFeetStayPlanted() {
        var rng = SplitMix(3)
        let a = Ant(at: SIMD2(160, 284), heading: 0, rng: &rng)
        a.set(.work, at: 0, rng: &rng)
        var slid = 0.0, steps = 0, t = 0.0
        for _ in 0..<1200 {
            let before = a.feet
            t += 1.0 / 120
            a.update(1.0 / 120, t: t, screen: SIMD2(320, 568), listenAt: nil, rng: &rng)
            for (f0, f1) in zip(before, a.feet) {
                if f0.s >= 1 && f1.s >= 1 { slid = max(slid, simd_length(f0.at - f1.at)) }
                if f0.s >= 1 && f1.s < 1 { steps += 1 }
            }
        }
        XCTAssertGreaterThan(steps, 30, "it walked")
        XCTAssertEqual(slid, 0, "planted feet stay put")
    }

    // Calm: an idle ant mostly stands, and a busy one with no new hook events stops after its errand; standing, it
    // still creeps (burn-in) but by under a point a second.
    func testCalmUnlessSessionActsAndDriftWhenStill() {
        let c = Colony(seed: 4, now: 0)
        c.update([("a", .idle, false, nil), ("b", .busy, false, 5)], at: 0)
        _ = c.shapes(at: 30)
        var moved = 0.0, last = [c.position(of: "a")!, c.position(of: "b")!], start = last
        for k in 1...600 {
            _ = c.shapes(at: 30 + Double(k) / 10)
            let now = [c.position(of: "a")!, c.position(of: "b")!]
            if k > 0 { moved = max(moved, simd_length(now[1] - last[1]) * 10) }
            last = now
        }
        XCTAssertLessThan(moved, 1, "b, with no new events, stands still but for the drift")
        XCTAssertGreaterThan(simd_length(last[1] - start[1]), 5, "it drifted over a minute")
        c.update([("a", .idle, false, nil), ("b", .busy, false, 6)], at: 90)
        start = [c.position(of: "b")!]
        _ = c.shapes(at: 93)
        XCTAssertGreaterThan(simd_length(c.position(of: "b")! - start[0]), 20, "a new hook event sends it on an errand")
    }

    // Only an ant that needs you grows; a finished one doesn't hop or spin.
    func testOnlyNeedsDrawsAttention() {
        var rng = SplitMix(5)
        let a = Ant(at: SIMD2(160, 284), heading: 0, rng: &rng)
        a.set(.done, at: 0, rng: &rng)
        var biggest = 0.0, h0 = a.h, turned = 0.0
        for k in 1...480 {
            a.update(1.0 / 120, t: Double(k) / 120, screen: SIMD2(320, 568), listenAt: nil, rng: &rng)
            biggest = max(biggest, a.size.x); turned = max(turned, abs(a.h - h0))
        }
        XCTAssertLessThan(biggest, 1.02)
        XCTAssertLessThan(turned, 0.1)
    }

    // Reading a session's text: its ant waits in the top left corner by the text, the others along the bottom; none
    // walks off, and when the text closes they're the same ants.
    func testReadingSendsTheTalkerToTheCornerOthersAside() {
        let c = Colony(seed: 6, now: 0)
        let all: [(id: String, mood: Mood, front: Bool, events: Int?)] = [("a", .idle, false, nil), ("b", .busy, false, 1), ("c", .idle, false, nil)]
        c.update(all, at: 0)
        c.solo = "b"
        for k in 1...600 { c.update(all, at: Double(k) / 60) }
        XCTAssertLessThan(simd_length(c.position(of: "b")! - SIMD2(44, 70)), 15, "by the corner, drifting")
        for id in ["a", "c"] { XCTAssertGreaterThan(c.position(of: id)!.y, 568 - 90, "\(id) stepped aside") }
        c.solo = nil
        c.update(all, at: 11)
        XCTAssertEqual(Set(c.shapes(at: 12).map(\.id)), ["a", "b", "c"])
    }

    // The session that needs you comes to the middle and grows; one asleep curls up and stays where it is.
    func testNeedsComesForwardSleepStays() {
        let c = Colony(seed: 2, now: 0)
        c.update([("a", .attention, true, nil), ("b", .sleep, false, nil)], at: 0)
        _ = c.shapes(at: 2)
        let b0 = c.position(of: "b")!
        _ = c.shapes(at: 8)
        XCTAssertLessThan(simd_length(c.position(of: "a")! - SIMD2(160, 254)), 6)
        XCTAssertLessThan(simd_length(c.position(of: "b")! - b0), 9, "asleep, it only drifts (under 1.5 pt a second)")
    }
}

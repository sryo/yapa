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

    // Walking, the abdomen swings right while the right front and hind legs are in the air and left for the left ones.
    func testAbdomenSwingsWithTheTripod() {
        var rng = SplitMix(8)
        let a = Ant(at: SIMD2(160, 284), heading: 0, rng: &rng)
        a.set(.work, at: 0, rng: &rng)
        var right = 0, left = 0
        for k in 1...1200 {
            a.update(1.0 / 120, t: Double(k) / 120, screen: SIMD2(320, 568), listenAt: nil, rng: &rng)
            let r1Up = a.feet.contains { $0.i == 0 && $0.side > 0 && $0.s < 0.6 && $0.s > 0.4 }
            let l1Up = a.feet.contains { $0.i == 0 && $0.side < 0 && $0.s < 0.6 && $0.s > 0.4 }
            if r1Up && a.hips.x > 0.3 { right += 1 }
            if l1Up && a.hips.x < -0.3 { left += 1 }
        }
        XCTAssertGreaterThan(right, 10); XCTAssertGreaterThan(left, 10)
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

    // Calm: a resting ant stands, creeping against burn-in. A busy one, thinking or running tools, walks slowly about
    // its spot on a leash, turning either way and never stopping, and a hook event doesn't send it anywhere.
    func testCalmUnlessSessionActsAndDriftWhenStill() {
        let c = Colony(seed: 4, now: 0)
        c.update([("a", .idle, false, nil), ("b", .busy, false, 5)], at: 0)
        _ = c.shapes(at: 30)
        let start = [c.position(of: "a")!, c.position(of: "b")!]
        var fastest = [0.0, 0.0], farthest = [0.0, 0.0], last = start, headings: [Double] = [], stillFor = 0.0, longestStill = 0.0
        var offSpot = 0.0
        for k in 1...600 {
            let t = 30 + Double(k) / 10
            if k == 300 { c.update([("a", .idle, false, nil), ("b", .busy, false, 6)], at: t) }
            let shapes = c.shapes(at: t)
            let now = [c.position(of: "a")!, c.position(of: "b")!]
            for i in 0..<2 {
                fastest[i] = max(fastest[i], simd_length(now[i] - last[i]) * 10)
                farthest[i] = max(farthest[i], simd_length(now[i] - start[i]))
            }
            offSpot = max(offSpot, simd_length(now[1] - c.spot(of: "b")!))
            // Which way b faces, from its head to its abdomen.
            if let b = shapes.first(where: { $0.id == "b" }), let head = b.fills.last, let rear = b.fills.first {
                let d = head.reduce(.zero, +) / Double(head.count) - rear.reduce(.zero, +) / Double(rear.count)
                let a = atan2(d.y, d.x)
                if let p = headings.last, abs(remainder(a - p, 2 * .pi)) < 0.002 { stillFor += 0.1 } else { stillFor = 0 }
                longestStill = max(longestStill, stillFor)
                headings.append(a)
            }
            last = now
        }
        XCTAssertLessThan(fastest[0], 1.5, "a, resting, only creeps")
        XCTAssertLessThan(offSpot, 35, "b walks about but keeps to its patch, even after a hook event")
        XCTAssertLessThan(fastest[1], 25, "slowly")
        let spread = headings.map { remainder($0 - headings[0], 2 * .pi) }
        XCTAssertGreaterThan(spread.max()! - spread.min()!, 1.0, "b turns either way")
        XCTAssertLessThan(longestStill, 1.0, "and never stops")
    }

    // Needing you: a short freeze and a pop, then the one forward runs to the middle and grows, and pulses every 3 s;
    // the others hold still meanwhile. Allowed, it hurries home; denied, it walks home slowly.
    func testNeedsPopsPulsesAndOthersHoldStill() {
        func run(allowed: Bool) -> (popped: Bool, pulses: Int, othersMoved: Double, homeAfter: Double) {
            let c = Colony(seed: 7, now: 0)
            c.update([("a", .idle, false, nil), ("b", .busy, false, 1)], at: 0)
            _ = c.shapes(at: 3)
            let home = c.position(of: "a")!, b0 = c.position(of: "b")!
            c.update([("a", .attention, true, nil), ("b", .busy, false, 1)], at: 3)
            _ = c.shapes(at: 3.1)
            let froze = simd_length(c.position(of: "a")! - home) < 2
            var sizes: [Double] = [], othersMoved = 0.0
            for k in 1...1200 {
                let t = 3.1 + Double(k) / 100
                let shapes = c.shapes(at: t)
                if let a = shapes.first(where: { $0.id == "a" }) { sizes.append(a.fills[0].map { simd_length($0 - a.centre) }.max()!) }
                othersMoved = max(othersMoved, simd_length(c.position(of: "b")! - b0))
            }
            // A pulse is the body swelling past what it settled to and back.
            let settled = sizes[800...].min()!
            let pulses = (1..<sizes.count).filter { sizes[$0] > settled * 1.04 && sizes[$0 - 1] <= settled * 1.04 }.count
            c.answered("a", allowed: allowed)
            c.update([("a", .idle, false, nil), ("b", .busy, false, 1)], at: 15.1)
            _ = c.shapes(at: 16.6)
            return (froze, pulses, othersMoved, simd_length(c.position(of: "a")! - home))
        }
        let yes = run(allowed: true), no = run(allowed: false)
        XCTAssertTrue(yes.popped, "it freezes a moment first")
        XCTAssertGreaterThanOrEqual(yes.pulses, 2, "it pulses every 3 s")
        XCTAssertLessThan(yes.othersMoved, 8, "the others hold still")
        XCTAssertLessThan(yes.homeAfter, no.homeAfter - 20, "allowed hurries home, denied walks slowly")
    }

    // Held to talk, only that ant reacts: it steps out from under the fingertip and keeps its size; let go, it walks
    // back to its spot.
    func testHeldAntStepsOutFromUnderTheFinger() {
        let c = Colony(seed: 8, now: 0)
        c.update([("a", .attention, true, nil), ("b", .idle, false, nil)], at: 0)
        _ = c.shapes(at: 8)
        let finger = c.position(of: "a")!, b0 = c.position(of: "b")!
        let big = c.shapes(at: 8).first { $0.id == "a" }!.fills[0].map { simd_length($0 - finger) }.max()!
        c.listenAt = finger; c.listener = "a"
        c.update([("a", .attention, true, nil), ("b", .idle, false, nil)], at: 8)
        _ = c.shapes(at: 11)
        let held = c.shapes(at: 11).first { $0.id == "a" }!
        XCTAssertGreaterThan(simd_length(held.centre - finger), 30, "out from under the finger")
        XCTAssertEqual(held.fills[0].map { simd_length($0 - held.centre) }.max()!, big, accuracy: big * 0.15, "same size")
        XCTAssertLessThan(simd_length(c.position(of: "b")! - b0), 6, "the other doesn't react")
        c.listenAt = nil; c.listener = nil
        c.update([("a", .attention, true, nil), ("b", .idle, false, nil)], at: 11)
        _ = c.shapes(at: 15)
        XCTAssertLessThan(simd_length(c.position(of: "a")! - finger), 12, "back to where it stood")
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
        // It turns once on the spot, about a full turn, and no more.
        XCTAssertGreaterThan(turned, 2 * .pi * 0.9)
        XCTAssertLessThan(turned, 2 * .pi * 1.3)
        XCTAssertLessThan(simd_length(SIMD2(a.x, a.y) - SIMD2(160, 284)), 3)
    }

    // Left alone long enough to sleep, it curls up, antennae folded; just finished, it stands uncurled.
    func testSleepCurlsUp() {
        var rng = SplitMix(5)
        let a = Ant(at: SIMD2(160, 284), heading: 0, rng: &rng), b = Ant(at: SIMD2(160, 284), heading: 0, rng: &rng)
        XCTAssertEqual(Colony.act(for: .sleep, front: false, listening: false), .sleep)
        a.set(.sleep, at: 0, rng: &rng); b.set(.rest, at: 0, rng: &rng)
        for k in 1...600 {
            a.update(1.0 / 120, t: Double(k) / 120, screen: SIMD2(320, 568), listenAt: nil, rng: &rng)
            b.update(1.0 / 120, t: Double(k) / 120, screen: SIMD2(320, 568), listenAt: nil, rng: &rng)
        }
        XCTAssertGreaterThan(a.curl.x, 0.8)
        XCTAssertLessThan(a.antennae.x, -0.8)
        XCTAssertLessThan(b.curl.x, 0.05)
    }

    // Reading a session's text: its ant waits in the top left corner by the text, the others walk off the nearest edge
    // one after another; when the text closes the same ants walk back to where they were.
    func testReadingSendsTheTalkerToTheCornerOthersOff() {
        let c = Colony(seed: 6, now: 0)
        let all: [(id: String, mood: Mood, front: Bool, events: Int?)] = [("a", .idle, false, nil), ("b", .busy, false, 1), ("c", .idle, false, nil)]
        c.update(all, at: 0)
        _ = c.shapes(at: 1)
        let was = ["a": c.position(of: "a")!, "c": c.position(of: "c")!]
        c.solo = "b"
        for k in 61...660 { c.update(all, at: Double(k) / 60) }
        XCTAssertLessThan(simd_length(c.position(of: "b")! - SIMD2(44, 70)), 15, "by the corner, drifting")
        for id in ["a", "c"] {
            let p = c.position(of: id)!
            XCTAssertTrue(p.x < -20 || p.x > 340 || p.y < -20 || p.y > 588, "\(id) walked off: \(p)")
        }
        XCTAssertEqual(Set(c.shapes(at: 11).map(\.id)), ["a", "b", "c"], "off screen, not gone")
        c.solo = nil
        for k in 661...1260 { c.update(all, at: Double(k) / 60) }
        for id in ["a", "c"] { XCTAssertLessThan(simd_length(c.position(of: id)! - was[id]!), 30, "\(id) came back") }
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

    // Each session's ant has a spot of its own, spread over the screen, and a new one appears at its own spot, not
    // on top of another.
    func testEachAntHasItsOwnSpot() {
        let c = Colony(seed: 3, now: 0)
        var all: [(id: String, mood: Mood, front: Bool, events: Int?)] = (0..<4).map { ("s\($0)", .idle, false, nil) }
        c.update(all, at: 0)
        _ = c.shapes(at: 2)
        func apart() -> Double {
            let p = all.map { c.position(of: $0.id)! }
            return p.indices.flatMap { i in p.indices.filter { $0 > i }.map { simd_length(p[i] - p[$0]) } }.min()!
        }
        XCTAssertGreaterThan(apart(), 100)
        all.append(("s4", .idle, false, nil))
        c.update(all, at: 2)
        _ = c.shapes(at: 2.1)
        XCTAssertGreaterThan(apart(), 60, "the new one isn't on another")
        _ = c.shapes(at: 15)
        XCTAssertGreaterThan(apart(), 75, "five spread out")
    }

    // A session another started stands beside that one's ant, nearer it than any other family's, and the families
    // stay as far apart as single sessions do.
    func testFamiliesStandTogether() {
        let screen = SIMD2<Double>(320, 568)
        let ids = ["m", "a", "k1", "k2", "k3", "g"]
        let h = Colony.homes(ids, families: ["k1": "m", "k2": "m", "k3": "m", "g": "k1"], screen)
        XCTAssertEqual(h.count, ids.count)
        XCTAssertEqual(h["m"], Colony.homes(2, screen)[0])
        XCTAssertEqual(h["a"], Colony.homes(2, screen)[1])
        for k in ["k1", "k2", "k3", "g"] {
            XCTAssertLessThan(simd_length(h[k]! - h["m"]!), simd_length(h[k]! - h["a"]!), k)
        }
        let p = ids.map { h[$0]! }
        let apart = p.indices.flatMap { i in p.indices.filter { $0 > i }.map { simd_length(p[i] - p[$0]) } }.min()!
        XCTAssertGreaterThan(apart, 45, "no two spots on top of each other")
        for q in p { XCTAssertTrue(q.x >= 40 && q.x <= 280 && q.y >= 70 && q.y <= 498, "\(q) on screen") }
        // A parent that isn't here leaves its session on its own.
        XCTAssertEqual(Colony.homes(["x", "y"], families: ["y": "gone"], screen)["y"], Colony.homes(2, screen)[1])
    }

    // Busy ants run their errands near their own spot and walk around each other, so they never touch and each stays
    // where you know it.
    func testBusyAntsStayApartAndInPlace() {
        let c = Colony(seed: 4, now: 0)
        var all: [(id: String, mood: Mood, front: Bool, events: Int?)] = (0..<4).map { ("s\($0)", .busy, false, 0) }
        c.update(all, at: 0)
        _ = c.shapes(at: 2)
        let home = Dictionary(uniqueKeysWithValues: all.map { ($0.id, c.position(of: $0.id)!) })
        for k in 1...120 {
            all[k % 4].events! += 1
            c.update(all, at: 2 + Double(k))
            for f in 1...30 {
                let p = c.shapes(at: 2 + Double(k) + Double(f) / 30).map(\.centre)
                for i in p.indices { for j in p.indices where j > i { XCTAssertGreaterThan(simd_length(p[i] - p[j]), 26) } }
            }
        }
        for a in all { XCTAssertLessThan(simd_length(c.position(of: a.id)! - home[a.id]!), 70, "\(a.id) stayed near its spot, which creeps against burn-in") }
    }

    // The ant that needs you comes forward; answered, it walks back to its own spot.
    func testAnsweredItGoesBack() {
        let c = Colony(seed: 5, now: 0)
        c.update([("a", .idle, false, nil), ("b", .idle, false, nil)], at: 0)
        _ = c.shapes(at: 2)
        let home = c.position(of: "a")!
        c.update([("a", .attention, true, nil), ("b", .idle, false, nil)], at: 2)
        _ = c.shapes(at: 10)
        XCTAssertLessThan(simd_length(c.position(of: "a")! - SIMD2(160, 254)), 10)
        c.update([("a", .idle, false, nil), ("b", .idle, false, nil)], at: 10)
        _ = c.shapes(at: 20)
        XCTAssertLessThan(simd_length(c.position(of: "a")! - home), 30)
    }

    // A working ant drops a crumb each minute of its turn, in one tight pile beside its
    // spot (never under it, never one on another), and picks them all up once the turn ends; nothing shows while
    // text is up.
    func testCrumbsCountTheMinutes() {
        XCTAssertEqual([0, 59, 60, 600, 900, 7200].map(Colony.crumbs(after:)), [0, 0, 1, 10, 15, 120])
        let c = Colony(seed: 5, now: 0)
        c.update([("a", .busy, false, 1), ("b", .idle, false, 1)], at: 0)
        c.working = ["a": -300]
        c.update([("a", .busy, false, 1), ("b", .idle, false, 1)], at: 1)
        let pile = c.crumbs(at: 2)
        XCTAssertEqual(pile.count, 5)
        let centres = pile.map { $0.reduce(.zero, +) / Double($0.count) }
        let middle = centres.reduce(.zero, +) / Double(centres.count)
        for (i, p) in centres.enumerated() {
            XCTAssertLessThan(simd_length(p - c.position(of: "a")!), 80, "by its own ant")
            XCTAssertGreaterThan(simd_length(p - c.spot(of: "a")!), 16, "beside its spot, not on it")
            XCTAssertLessThan(simd_length(p - middle), 10, "in one tight pile")
            for q in centres[(i + 1)...] { XCTAssertGreaterThan(simd_length(p - q), 2.5, "not on another") }
        }
        c.solo = "a"
        XCTAssertTrue(c.crumbs(at: 2).isEmpty)
        c.solo = nil
        c.working = [:]
        c.update([("a", .idle, false, 2), ("b", .idle, false, 1)], at: 3)
        XCTAssertEqual(c.crumbs(at: 3).count, 5, "still there as it starts picking them up")
        c.update([("a", .idle, false, 2), ("b", .idle, false, 1)], at: 4.5)
        XCTAssertTrue(c.crumbs(at: 4.5).isEmpty)
    }

    // Busy ants that started together never turn in step: each has its own tempo and swing.
    func testBusyAntsDontTurnInStep() {
        let c = Colony(seed: 9, now: 0)
        let all: [(id: String, mood: Mood, front: Bool, events: Int?)] = (0..<4).map { ("s\($0)", .busy, false, 0) }
        c.update(all, at: 0)
        var turns: [String: [Double]] = [:], last: [String: Double] = [:]
        for k in 1...600 {
            for s in c.shapes(at: 5 + Double(k) / 20) {
                guard let head = s.fills.last, let rear = s.fills.first else { continue }
                let d = head.reduce(.zero, +) / Double(head.count) - rear.reduce(.zero, +) / Double(rear.count), a = atan2(d.y, d.x)
                if let p = last[s.id] { turns[s.id, default: []].append(remainder(a - p, 2 * .pi)) }
                last[s.id] = a
            }
        }
        func corr(_ a: [Double], _ b: [Double]) -> Double {
            let n = Double(min(a.count, b.count)), ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
            let cov = zip(a, b).reduce(0) { $0 + ($1.0 - ma) * ($1.1 - mb) }
            let va = a.reduce(0) { $0 + ($1 - ma) * ($1 - ma) }, vb = b.reduce(0) { $0 + ($1 - mb) * ($1 - mb) }
            return cov / max(1e-9, (va * vb).squareRoot())
        }
        let ids = turns.keys.sorted()
        for i in ids.indices { for j in ids.indices where j > i {
            XCTAssertLessThan(abs(corr(turns[ids[i]]!, turns[ids[j]]!)), 0.6, "\(ids[i]) and \(ids[j]) turn in step")
        } }
    }

    // A busy ant walks in wide, slow curves: it never spins in place, beside its crumbs or anywhere else. Its path,
    // sampled every quarter second, bends no tighter on average than a circle 10 pt across.
    // Thinking, a busy ant's antennae drum; running a tool, they don't.
    func testThinkingDrums() {
        let c = Colony(seed: 4, now: 0)
        c.update([("a", .focused, false, 1), ("b", .busy, false, 1)], at: 0)
        for k in 1...240 { c.update([("a", .focused, false, 1), ("b", .busy, false, 1)], at: Double(k) / 120) }
        XCTAssertGreaterThan(c.drumming("a"), 0.5)
        XCTAssertEqual(c.drumming("b"), 0, accuracy: 0.01)
    }

    func testBusyAntsNeverSpin() {
        for seed in 0..<6 {
            let c = Colony(seed: UInt64(seed), now: 0)
            c.screen = SIMD2(568, 320)
            c.update([("a", .busy, false, 0), ("b", .busy, false, 0)], at: 0)
            c.working = ["a": -600, "b": -600]
            c.update([("a", .busy, false, 0), ("b", .busy, false, 0)], at: 1)
            var at: [String: SIMD2<Double>] = [:], way: [String: Double] = [:], walked: [String: Double] = [:], turned: [String: Double] = [:]
            for k in 1...480 {
                _ = c.shapes(at: 5 + Double(k) / 4)
                for id in ["a", "b"] {
                    let p = c.position(of: id)!
                    if let q = at[id], simd_length(p - q) > 0.3 {
                        let w = atan2(p.y - q.y, p.x - q.x)
                        if let v = way[id] { turned[id, default: 0] += abs(remainder(w - v, 2 * .pi)) }
                        way[id] = w; walked[id, default: 0] += simd_length(p - q)
                    }
                    at[id] = p
                }
            }
            for id in ["a", "b"] {
                let radius = (walked[id] ?? 0) / max(1e-9, turned[id] ?? 0)
                XCTAssertGreaterThan(radius, 5, "seed \(seed): \(id) turns on a \(radius) pt radius: it's spinning")
            }
        }
    }

    // A finished turn you haven't seen keeps its crumbs by its ant; once you look, the ant picks them up.
    func testUnseenDoneKeepsItsCrumbs() {
        let c = Colony(seed: 3, now: 0)
        c.update([("a", .busy, false, 1), ("b", .idle, false, 1)], at: 0)
        c.working = ["a": -300]
        c.update([("a", .busy, false, 1), ("b", .idle, false, 1)], at: 1)
        XCTAssertEqual(c.crumbs(at: 2).count, 5)
        c.working = [:]; c.unseen = ["a"]
        c.update([("a", .proud, false, 2), ("b", .idle, false, 1)], at: 3)
        c.update([("a", .idle, false, 2), ("b", .idle, false, 1)], at: 10)
        XCTAssertEqual(c.crumbs(at: 10).count, 5, "done, not seen: the crumbs stay")
        c.update([("a", .sleep, false, 2), ("b", .sleep, false, 1)], at: 120)
        XCTAssertEqual(c.acting("a"), "rest", "an ant beside its crumbs never curls up")
        XCTAssertEqual(c.acting("b"), "sleep")
        c.unseen = []
        c.update([("a", .idle, false, 2), ("b", .idle, false, 1)], at: 121)
        c.update([("a", .idle, false, 2), ("b", .idle, false, 1)], at: 123)
        XCTAssertTrue(c.crumbs(at: 123).isEmpty)
    }
}

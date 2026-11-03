import XCTest
@testable import JetaKit

final class ChordTests: XCTestCase {
    typealias P = SIMD2<Double>

    /// Plays touches at 60 fps: `fingers(t)` gives the fingers down at time t (empty = all lifted), and every
    /// event the chord emits is collected, ending with one empty frame so a release always lands.
    func play(_ chord: inout Chord, for seconds: Double, _ fingers: (Double) -> [Int: P]) -> [Chord.Event] {
        var events: [Chord.Event] = []
        for t in stride(from: 0, through: seconds, by: 1.0 / 60) { events += chord.update(fingers(t), at: t) }
        return events + chord.update([:], at: seconds + 1.0 / 60)
    }

    /// Two fingers `gap` apart, landing together, still for 0.2 s, then dragged by `dy` (negative = up) over 0.3 s.
    func pair(gap: Double = 40, dy: Double, at t: Double) -> [Int: P] {
        let y = 300 + dy * min(1, max(0, (t - 0.2) / 0.3))
        return [1: P(160 - gap / 2, y), 2: P(160 + gap / 2, y)]
    }

    func decisions(_ e: [Chord.Event]) -> [Chord.Decision] {
        e.compactMap { if case .decided(let d) = $0 { d } else { nil } }
    }
    func began(_ e: [Chord.Event]) -> [Chord.Event] {
        e.filter { if case .began = $0 { true } else { false } }
    }
    func steps(_ e: [Chord.Event], _ c: Chord.Control) -> Int {
        e.reduce(0) { if case .step(c, let n) = $1 { $0 + n } else { $0 } }
    }

    // R1: one finger never acts, whatever it does, even with a prompt up.
    func testR1_OneFingerNeverActs() {
        var chord = Chord(); chord.prompt = true
        let e = play(&chord, for: 0.6) { t in [1: P(160, 400 - 400 * t)] }
        XCTAssertEqual(e, [])
    }

    // R1: the finger count settles before anything locks: fingers landing 40 ms apart lock as three, never two.
    func testR1_CountSettlesBeforeLocking() {
        var chord = Chord()
        let e = play(&chord, for: 0.5) { t in
            var f: [Int: P] = [1: P(120, 300)]
            if t >= 0.04 { f[2] = P(160, 300) }
            if t >= 0.08 { f[3] = P(200, 300) }
            return f
        }
        XCTAssertEqual(began(e), [.began(nil, fingers: 3)])
    }

    // R1: spacing is read once at touch-down: two close fingers stay close however far they spread after.
    func testR1_SpacingLocksAtTouchDown() {
        var chord = Chord()
        let e = play(&chord, for: 0.6) { t in
            let gap = t < 0.2 ? 40 : 40 + 400 * (t - 0.2)
            return [1: P(160 - gap / 2, 300), 2: P(160 + gap / 2, 300)]
        }
        XCTAssertEqual(began(e), [.began(.scrub, fingers: 2)])
        var wide = Chord()
        XCTAssertEqual(began(play(&wide, for: 0.4) { pair(gap: 160, dy: 0, at: $0) }), [.began(.spread, fingers: 2)])
    }

    // R1: step size follows the stakes: scrubbing steps every 40 pt, up is positive.
    func testR1_ScrubStepsEvery40pt() {
        var chord = Chord()
        XCTAssertEqual(steps(play(&chord, for: 0.7) { pair(dy: -125, at: $0) }, .scrub), 3)
        var down = Chord()
        XCTAssertEqual(steps(play(&down, for: 0.7) { pair(dy: 85, at: $0) }, .scrub), -2)
    }

    // R1: a decision commits only when released 20% past its 100 pt detent; anything short of it sends nothing.
    func testR1_DecisionOnlyPastTheDetent() {
        for (dy, want) in [(-130.0, [Chord.Decision.once]), (130, [.deny]), (-110, []), (90, [])] {
            var chord = Chord(); chord.prompt = true
            XCTAssertEqual(decisions(play(&chord, for: 0.7) { pair(dy: dy, at: $0) }), want, "drag \(dy)")
        }
    }

    // R1: going back below the detent before letting go takes the decision back.
    func testR1_ComingBackCancels() {
        var chord = Chord(); chord.prompt = true
        let e = play(&chord, for: 0.9) { t in
            let dy = t < 0.5 ? -140 * max(0, (t - 0.2) / 0.3) : -140 + 110 * min(1, (t - 0.5) / 0.3)
            return [1: P(140, 300 + dy), 2: P(180, 300 + dy)]
        }
        XCTAssertEqual(decisions(e), [])
        XCTAssertTrue(e.contains(.armed(.once)) && e.contains(.armed(nil)))
    }

    // R1: a finger landing after the chord locked voids it: a late third finger never turns into an approval.
    func testR1_LateFingerVoidsTheChord() {
        var chord = Chord(); chord.prompt = true
        let e = play(&chord, for: 0.8) { t in
            var f = pair(dy: -150, at: t + 0.1)
            if t >= 0.15 { f[3] = P(200, f[1]!.y) }
            return f
        }
        XCTAssertEqual(decisions(e), [])
        XCTAssertEqual(steps(e, .decide), 0)
    }

    // R1: with no prompt up, the same drag only scrubs; nothing can be decided.
    func testR1_NoPromptNoDecision() {
        var chord = Chord()
        let e = play(&chord, for: 0.7) { pair(dy: -140, at: $0) }
        XCTAssertEqual(decisions(e), [])
        XCTAssertEqual(began(e), [.began(.scrub, fingers: 2)])
    }

    // R1: lifting one finger mid-drag moves the centre but never counts as a step.
    func testR1_LiftingAFingerIsNotAStep() {
        var chord = Chord()
        let e = play(&chord, for: 0.6) { t in
            t < 0.3 ? [1: P(100, 300), 2: P(220, 120)] : [1: P(100, 300)]
        }
        XCTAssertEqual(steps(e, .spread), 0)
    }
}

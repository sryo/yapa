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

    /// Two fingers `gap` apart round (160, 300), landing together, still for 0.2 s, then twisted by `degrees`
    /// (clockwise positive) over 0.3 s.
    func pair(gap: Double = 50, degrees: Double, at t: Double) -> [Int: P] {
        let a = degrees * .pi / 180 * min(1, max(0, (t - 0.2) / 0.3)), d = P(cos(a), sin(a)) * gap / 2
        return [1: P(160, 300) - d, 2: P(160, 300) + d]
    }

    func began(_ e: [Chord.Event]) -> [Chord.Event] {
        e.filter { if case .began = $0 { true } else { false } }
    }
    func steps(_ e: [Chord.Event]) -> Int {
        e.reduce(0) { if case .step(let n) = $1 { $0 + n } else { $0 } }
    }
    func released(_ e: [Chord.Event]) -> Bool { e.contains(.released) }

    // R1: one finger never acts, whatever it does.
    func testR1_OneFingerNeverActs() {
        var chord = Chord()
        let e = play(&chord, for: 0.6) { t in [1: P(160 + 80 * cos(6 * t), 300 + 80 * sin(6 * t))] }
        XCTAssertEqual(e, [])
    }

    // R1: the finger count settles before anything locks: fingers landing 40 ms apart lock as three, never two,
    // and three fingers turn nothing and release nothing.
    func testR1_CountSettlesBeforeLocking() {
        var chord = Chord()
        let e = play(&chord, for: 0.5) { t in
            var f: [Int: P] = [1: P(120, 300)]
            if t >= 0.04 { f[2] = P(160, 300) }
            if t >= 0.08 { f[3] = P(200, 300) }
            return f
        }
        XCTAssertEqual(began(e), [.began(fingers: 3)])
        XCTAssertFalse(released(e))
    }

    // R1: a third finger landing just after two locked, before anything turned, re-counts as three.
    func testR1_AnEarlyThirdFingerRecounts() {
        var c = Chord()
        let e = play(&c, for: 0.6) { t in
            var f: [Int: P] = [1: P(140, 300), 2: P(180, 300)]
            if t >= 0.13 { f[3] = P(160, 340) }
            return f
        }
        XCTAssertEqual(began(e).last, .began(fingers: 3))
        XCTAssertFalse(released(e))
    }

    // R1: it turns by twist, a step per 22.5°, clockwise positive; spreading, pinching or sliding the fingers
    // never turns it. Letting go of two fingers is a release.
    func testR1_TwistTurnsAndNothingElseDoes() {
        var cw = Chord()
        let e = play(&cw, for: 0.7) { pair(degrees: 75, at: $0) }
        XCTAssertEqual(steps(e), 3)
        XCTAssertEqual(e.suffix(2), [.released, .ended])
        var ccw = Chord()
        XCTAssertEqual(steps(play(&ccw, for: 0.7) { pair(degrees: -50, at: $0) }), -2)
        var slide = Chord()
        let s = play(&slide, for: 0.7) { t in
            let gap = 50 + 200 * max(0, t - 0.2), x = 160 + 300 * max(0, t - 0.2)
            return [1: P(x - gap / 2, 300), 2: P(x + gap / 2, 300)]
        }
        XCTAssertEqual(steps(s), 0)
    }

    // R1: a finger landing after the chord locked voids it: nothing more turns, and letting go does nothing.
    func testR1_LateFingerVoidsTheChord() {
        var chord = Chord()
        let e = play(&chord, for: 0.8) { t in
            var f = self.pair(degrees: 60, at: t + 0.1)
            if t >= 0.15 { f[3] = P(200, 360) }
            return f
        }
        XCTAssertFalse(released(e))
        XCTAssertEqual(steps(e), 0)
    }

    // R1: the reading keeps where the turn began while the fingers go round, for whatever draws the dial.
    func testR1_ReadingKeepsItsStart() {
        var chord = Chord()
        var starts: [Double] = []
        for t in stride(from: 0, through: 0.6, by: 1.0 / 60) {
            _ = chord.update(pair(degrees: 90, at: t), at: t)
            if let r = chord.reading { starts.append(r.start) }
        }
        XCTAssertFalse(starts.isEmpty)
        XCTAssertLessThan(starts.max()! - starts.min()!, 1e-9)
        XCTAssertEqual(chord.reading?.steps, 4)
        XCTAssertEqual(chord.reading?.centre ?? .zero, P(160, 300))
    }

    // R1: lifting one finger mid-turn never counts as a step.
    func testR1_LiftingAFingerIsNotAStep() {
        var chord = Chord()
        let e = play(&chord, for: 0.6) { t in
            t < 0.3 ? [1: P(100, 300), 2: P(220, 120)] : [1: P(100, 300)]
        }
        XCTAssertEqual(steps(e), 0)
    }
}

import AudioToolbox
import UIKit

/// Draws the colony: one white ant per Claude Code session, each acting out its session's mood. The faces are still
/// the mood models (blinks, moods, dozing off), but only their ants are drawn.
final class FaceView: UIView {
    let face = Face(seed: UInt64(Date().timeIntervalSince1970), now: CACurrentMediaTime())
    private var link: CADisplayLink?
    /// The manager's notices, and what the screen shows of them.
    private var board = NoticeBoard()
    private(set) var screen = Screen()
    /// The text's springs, a layer for each line they show, and where each line rests (to hit-test options).
    let motion = TextMotion()
    private var texts: [String: CATextLayer] = [:]
    private(set) var placed: [Placed] = []
    /// The way the last swipe went (-1 left, 1 right), and the mode the text was last shown for.
    private var spoke: String?, swipeWay = 0.0, pageWay = 0.0, was = Screen.Mode.face
    /// An option picked: the line for the manager, and the session it goes to.
    var onChoose: ((String, String?) -> Void)?
    /// Answers the request showing with the labels picked for each of its questions; false if it's gone.
    var onAnswer: (([String: String]) -> Bool)?
    /// A tap on Allow or Deny answers the prompt up (true for once); false when none can be answered.
    /// A permission answered on the pad: "once", "session", "deny" or "stop", with any words said as the reason.
    var onDecide: ((_ how: String, _ words: String?) -> Bool)?
    /// A session's finished turn was looked at on the pad.
    var onLooked: ((String) -> Void)?
    /// A tap brought a session that needs you forward: its prompt is the one the next tap answers.
    var onFocus: ((String) -> Void)?
    var talk: Talk?
    /// One face per Claude Code session, when two or more report through the hooks; with one, the face above.
    let crowd = Crowd(seed: UInt64(Date().timeIntervalSince1970) &+ 1, now: CACurrentMediaTime())
    private(set) var names: [String: CATextLayer] = [:]
    /// An ant for each face: the crowd's, or the single face's.
    let colony = Colony(seed: UInt64(Date().timeIntervalSince1970) &+ 2, now: CACurrentMediaTime())
    private var antLayers: [String: [CAShapeLayer]] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
        for way in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped))
            swipe.direction = way
            addGestureRecognizer(swipe)
        }
        let down = UISwipeGestureRecognizer(target: self, action: #selector(swipedDown))
        down.direction = .down
        addGestureRecognizer(down)
        // With text up, a drag sideways carries it with the finger, and reading, so does a drag up or down, which
        // turns the page; a finger that moved at all is never a tap.
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged))
        drag.maximumNumberOfTouches = 1
        drag.delegate = self
        addGestureRecognizer(drag)
        tap.require(toFail: drag)
        isMultipleTouchEnabled = true
        talk = Talk(face: face, in: self)
        onChoose = { [weak self] in self?.talk?.say($0, to: $1) }
        talk?.onNote = { [weak self] in self?.screen.note = $0; self?.noteEnds = $1.map { end in (end, end - CACurrentMediaTime()) } }
        // Reading a reply, talking answers that session; otherwise the ant held.
        talk?.session = { [weak self] p in self.flatMap { $0.screen.mode == .reply ? $0.screen.asker : $0.session(at: p) } }
        // Holding to talk while a permission request is up denies it, with the words as the reason.
        talk?.refusing = { [weak self] in self?.screen.asking?.options.contains("Deny") == true }
        talk?.onRefuse = { [weak self] words in
            guard let self, self.onDecide?("deny", words) == true else { return }
            self.colony.answered(self.crowd.single ? "face" : self.crowd.front ?? "", allowed: false)
            self.screen.answered()
        }
        // The face hops as it says a question and gulps when its words come back.
        motion.onSay = { [weak self] in self?.speaker.say(at: CACurrentMediaTime()) }
        motion.onSwallow = { [weak self] in self?.speaker.swallow(at: CACurrentMediaTime()) }
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A turn event from the Claude app (any session); the manager's `jeta:` lines become notices.
    /// Returns the sessions whose notice this event added or changed.
    /// The permission request the pad can answer, shown with its buttons; nil when none is waiting.
    func ask(_ a: Asked?) {
        guard let a else { return screen.answered() }
        let was = screen.asking
        screen.ask(a)
        if screen.asking != was { askedAt = CACurrentMediaTime() }
    }

    func ask(_ p: Prompt?) {
        guard let p else { return screen.answered() }
        let parts = p.hint.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let (who, what) = parts.count == 2 ? (parts[0], parts[1]) : ("Claude", p.hint)
        let was = screen.asking
        screen.ask(session: who, what.isEmpty ? p.tool : "\(p.tool): \(what)")
        if screen.asking != was { askedAt = CACurrentMediaTime() }
    }

    /// When the request showing came up, and when the finger now on the glass landed: one that was already down
    /// can't have meant the request's buttons.
    private var askedAt = 0.0, downAt = 0.0

    func answered(by session: String) {
        board.answered(by: session)
        screen.update(board)
    }

    @discardableResult func take(_ event: Data) -> [String] {
        let old = board.pending
        board.take(event)
        screen.update(board)
        // A new question buzzes and the face looks up at you.
        if board.pending.count > old.count {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            face.set(.attention, at: CACurrentMediaTime())
        }
        return board.pending.filter { !old.contains($0) }.map(\.session)
    }

    // On the bare face a tap wakes it and draws its eyes to the finger; with text up it opens or closes the detail.
    @objc private func tapped(_ g: UITapGestureRecognizer) { tap(at: g.location(in: self), began: downAt) }

    /// A tap at `p` by a finger that landed at `began` (now, unless said), from the finger or from test/jeta-flows'
    /// driver.
    func tap(at p: CGPoint, began: Double = CACurrentMediaTime()) {
        // A tap right after talking stops the pending Enter; one on an option is that option, not a stop.
        if option(at: p) == nil, talk?.tapped() == true { return }
        // A tap puts the dial away.
        if dial.isOpen { dial.close(); return }
        // A folded question comes back on a tap on its ant (any tap, with one ant); a tap on no ant leaves it away.
        let under = colony.hit(SIMD2(Double(p.x), Double(p.y)))
        if crowd.single || under != nil, screen.unfold(session: crowd.single ? nil : under) { return }
        // A tap on an option sends it to the manager, like `server: 8443`; it pops and the face glances at it.
        // A permission request is answered only by its buttons: Allow or Deny, never a tap anywhere else.
        if screen.asking != nil, let (i, o) = option(at: p) {
            // The request came up under a finger already down: lifting it there answers nothing.
            guard began >= askedAt else { return }
            switch screen.pick(i) {
            case .decide(let allow):
                guard onDecide?(allow ? "once" : "deny", nil) == true else { return }
                colony.answered(crowd.single ? "face" : crowd.front ?? "", allowed: allow)
            case .allowSession:
                guard onDecide?("session", nil) == true else { return }
                colony.answered(crowd.single ? "face" : crowd.front ?? "", allowed: true)
            case .stop:
                guard onDecide?("stop", nil) == true else { return }
                colony.answered(crowd.single ? "face" : crowd.front ?? "", allowed: false)
            case .answer(let answers):
                guard onAnswer?(answers) == true else { return }
            case .more:
                AudioServicesPlaySystemSound(1104)
                return
            }
            motion.choose(o.key, at: CACurrentMediaTime())
            screen.answered()
            return
        }
        if let (i, o) = option(at: p), let line = screen.choose(i) {
            AudioServicesPlaySystemSound(1104)
            motion.choose(o.key, at: CACurrentMediaTime())
            poke(at: CGPoint(x: o.x + o.width / 2, y: o.y + o.height / 2))
            onChoose?(line, screen.asker)
            return
        }
        guard screen.mode == .face else { screen.tap(); return }
        // With a face per session, a touch on one shows its folder name for a moment. One that isn't forward is
        // also picked: one that needs you steps forward (its prompt is then the one answered), another opens its
        // question if it has one, else just looks at you. The lone ant is "face" to the colony, its session the only one.
        let t = CACurrentMediaTime()
        let hit = crowd.single ? under.flatMap { _ in crowd.session(at: .zero, t: t) } : under
        if let id = hit { crowd.touch(id, at: t) }
        if !crowd.single, let id = hit, id != crowd.front {
            if crowd.slots(at: t).first(where: { $0.id == id }).flatMap({ s in crowd.face(s.id)?.mood }) == .attention {
                crowd.focus(id, at: t)
                onFocus?(id)
            } else if let name = crowd.slots(at: t).first(where: { $0.id == id })?.name, screen.show(session: name) {
            } else if screen.read(session: id) {
            } else {
                crowd.face(id)?.poke(at: .zero, t: t)
            }
            return
        }
        // The bare face (or the one forward): a tap opens what it last said, if anything.
        if screen.read(session: crowd.single ? nil : crowd.front ?? hit) { return }
        poke(at: p)
    }

    /// The session a finger at `p` means: the ant under it, else the one forward, else the only one.
    private func session(at p: CGPoint) -> String? {
        crowd.single ? crowd.session(at: .zero, t: CACurrentMediaTime()) : colony.hit(SIMD2(Double(p.x), Double(p.y))) ?? crowd.front
    }

    private func poke(at p: CGPoint) {
        let u = Double(min(bounds.width, bounds.height))
        face.poke(at: SIMD2((Double(p.x) - Double(bounds.midX)) / u, (Double(p.y) - Double(bounds.midY)) / u), t: CACurrentMediaTime())
    }

    /// The option under a finger, and its index among the options.
    private func option(at p: CGPoint) -> (Int, Placed)? {
        let options = placed.filter { $0.style == .option || $0.style == .suggestion }
        guard let i = options.firstIndex(where: {
            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).insetBy(dx: -8, dy: -12).contains(p)
        }) else { return nil }
        return (i, options[i])
    }

    @objc private func swiped(_ g: UISwipeGestureRecognizer) {
        guard !carries else { return }
        swipe(left: g.direction == .left, at: g.location(in: self))
    }

    /// Text is up and a drag carries it: the swipe is the drag let go.
    var carries: Bool { screen.mode != .face && !dial.isOpen }

    func swipe(left: Bool, at p: CGPoint) {
        // On the bare faces, swiping one away hides it until its session's next event; nothing changes in Claude.
        let t = CACurrentMediaTime()
        if screen.mode == .face, !crowd.single, let id = colony.hit(SIMD2(Double(p.x), Double(p.y))) {
            crowd.hide(id, at: t)
            return
        }
        swipeWay = left ? -1 : 1
        screen.swipe()
    }

    // Holding anywhere is talking (Talk owns that gesture), so the session list opens with a swipe down on the bare face.
    @objc private func swipedDown(_ g: UISwipeGestureRecognizer) { swipeDown() }

    func swipeDown() {
        if screen.mode != .reply { screen.swipeDown() }
    }

    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        let d = g.translation(in: self)
        if g.state == .began { sideways = abs(d.x) > abs(d.y) }
        // Sideways the text goes between sessions; up and down, reading, between the pages of a reply or a request.
        guard sideways || screen.reads else { return }
        let pull = Double(sideways ? d.x : d.y)
        if g.state == .began || g.state == .changed { slide(by: pull, across: sideways); return }
        if g.state == .ended || g.state == .cancelled {
            let v = g.velocity(in: self)
            slid(by: g.state == .ended ? pull : 0, speed: g.state == .ended ? Double(sideways ? v.x : v.y) : 0,
                 at: g.location(in: self), across: sideways)
        }
    }

    /// Turns a reply's pages `n` forward (back when negative), as a drag up or down does.
    func page(by n: Int) {
        pageWay = n > 0 ? -1 : 1
        screen.scroll(by: n)
    }

    /// Which way the drag under way went first, and whether it carries the text (nil until it moves).
    private var sideways = false, sliding: Bool?

    /// Whether a drag `d` points along (sideways when `across`, else down) has somewhere to go: another session,
    /// or the page before or after.
    private func goes(_ d: Double, across: Bool) -> Bool {
        if across { return screen.turns }
        guard let p = screen.pages(width: Double(bounds.width), height: Double(bounds.height)) else { return false }
        return d < 0 ? p.page + 1 < p.of : p.page > 0
    }

    /// A finger `d` points from where it landed, sideways when `across` and else down: the text goes with it, 1:1
    /// where there's somewhere to go, and past the first or last page (or the only session) on iOS's rubber band.
    /// A slow drag first looks like a hold, so the hold it began is dropped; a finger that has been talking a while
    /// goes on talking instead.
    func slide(by d: Double, across: Bool = true) {
        if sliding == nil { sliding = talk?.drop() != false }
        guard sliding == true else { return }
        let pull = goes(d, across: across) ? d : TextMotion.rubber(d, over: Double(across ? bounds.width : bounds.height)).offset
        motion.hold(across ? SIMD2(pull, 0) : SIMD2(0, pull), speed: SIMD2<Double>(), at: CACurrentMediaTime())
    }

    /// The finger lifts: carried a fifth of the screen, or flicked that way, toward somewhere to go, it's a swipe
    /// (the text goes on off that side) or a page turned; short of that, or past an end, the text springs back.
    func slid(by d: Double, speed v: Double, at p: CGPoint, across: Bool = true) {
        defer { sliding = nil }
        guard sliding != false else { return }
        let size = Double(across ? bounds.width : bounds.height), goes = goes(d, across: across)
        let speed = goes ? v : v * TextMotion.rubber(d, over: size).slope
        motion.hold(nil, speed: across ? SIMD2(speed, 0) : SIMD2(0, speed), at: CACurrentMediaTime())
        guard goes, abs(d) > size * 0.2 || (abs(v) > 500 && v * d > 0) else { return }
        if across { swipe(left: d < 0, at: p) } else { page(by: d < 0 ? 1 : -1) }
    }

    /// What each session last said, for the reading screen.
    func show(replies: [Reply]) { screen.update(replies: replies) }

    // Two or more fingers are a chord: with a prompt up, two close fingers answer it; without, they page through
    // the questions. Two wide fingers pick an option.
    private(set) var chord = Chord()
    /// What two fingers turn through: a new session, the server, the tunnel and disk.
    var dial = Dial()
    /// The folders sessions ran in, for a new one; and what yata last said about the phone's parts.
    var folders: (() -> [String])?
    var server: [String: Any]?, serverAt = 0.0
    /// Marks under the two fingers turning the dial, which turn with them.
    let grip = CAShapeLayer()
    var gripShown = Spring(x: 0), gripAt = 0.0, gripLast: Chord.Reading?
    /// The crumbs working ants drop, a minute each, under the ants.
    fileprivate let crumbLayer = CAShapeLayer()
    /// The ant held to talk, from when the hold began.
    fileprivate var heldAnt: String?
    fileprivate var noteEnds: (at: Double, span: Double)?
    fileprivate let pie = CAShapeLayer(), dots = CAShapeLayer()
    fileprivate var dotAt = Spring(x: 0), dotsShown = Spring(x: 0), dotsAt = 0.0, dotCount = 0
    /// The backlight level from before the pad rested (nil while it's lit as the user set it), and how lit it is.
    fileprivate var userBrightness: CGFloat?, lit = Spring(x: 1)
    private var options: [Placed] { screen.asking == nil ? placed.filter { $0.style == .option || $0.style == .suggestion } : [] }
    private(set) var fingers: [Int: SIMD2<Double>] = [:]

    /// Fingers set by test/jeta-flows' driver, as if they were touching.
    func drive(fingers f: [Int: SIMD2<Double>]) {
        fingers = f
        feedChord(at: CACurrentMediaTime())
    }

    private func track(_ event: UIEvent?) {
        fingers = [:]
        for touch in event?.allTouches ?? [] where touch.phase != .ended && touch.phase != .cancelled {
            let p = touch.location(in: self)
            fingers[ObjectIdentifier(touch).hashValue] = SIMD2(Double(p.x), Double(p.y))
        }
        feedChord(at: CACurrentMediaTime())
    }
    // One finger down on an option squashes it until it lifts.
    override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) {
        screen.attend()
        track(e)
        downAt = CACurrentMediaTime()
        let down = e?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled } ?? []
        motion.press(down.count == 1 ? down.first.flatMap { option(at: $0.location(in: self)) }?.1.key : nil, at: CACurrentMediaTime())
    }
    override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent?) { track(e) }
    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) { track(e); motion.press(nil, at: CACurrentMediaTime()) }
    override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) { track(e); motion.press(nil, at: CACurrentMediaTime()) }

    private func feedChord(at t: Double) {
        for event in chord.update(fingers, at: t) {
            switch event {
            // Every step is a click you hear, since the SE has no Taptic Engine.
            case .began(2):
                AudioServicesPlaySystemSound(1104)
                dial.begin(at: t)
                askServer()
            case .began: break
            case .step(let n):
                AudioServicesPlaySystemSound(1104)
                dial.turn(n, at: t)
            case .released: letGo(at: t)
            case .ended: break
            }
        }
    }

    @objc private func tick(_ l: CADisplayLink) {
        let t = CACurrentMediaTime(), f = face.frame(at: t)
        // Fingers held still still settle into a chord.
        if !fingers.isEmpty { feedChord(at: t) }
        // Asleep only breathes, so 30 fps keeps it smooth for less power.
        l.preferredFramesPerSecond = colony.isActive ? 60 : 30
        let u = Double(min(bounds.width, bounds.height)), mid = SIMD2(Double(bounds.midX), Double(bounds.midY))
        // Let the face wander anywhere its eyes still fit, even when it steps up close.
        face.bounds = SIMD2(max(0, Double(bounds.width) / u / 2 - 0.27), 0.3)
        face.screen = SIMD2(Double(bounds.width) / u / 2, Double(bounds.height) / u / 2)
        let point = { (p: SIMD2<Double>) in CGPoint(x: mid.x + p.x * u, y: mid.y + p.y * u) }
        crowd.screen = face.screen
        crowd.solo = screen.mode == .face || screen.mode == .roster ? nil : screen.subject ?? crowd.front
        let slots = crowd.single ? [] : crowd.slots(at: t)
        // Text comes out of the face it's about: the one forward, else the single face.
        // Text that closes goes back into the ant it came from, even as that ant rejoins the others.
        if let s = crowd.solo { spoke = s }
        colony.screen = SIMD2(Double(bounds.width), Double(bounds.height))
        // While talking, the ant held steps out from under the finger and faces it; the others carry on. Which ant is
        // held is decided when the hold begins, so it stays the same as it walks away from the finger.
        colony.listenAt = face.mood == .listening
            ? (talk?.heldAt).map { SIMD2(Double($0.x), Double($0.y)) } ?? SIMD2(Double(bounds.midX), Double(bounds.height) - 120) : nil
        if colony.listenAt == nil { heldAnt = nil }
        else if heldAnt == nil { heldAnt = crowd.single ? "face" : colony.listenAt.flatMap(colony.hit) ?? crowd.front }
        colony.listener = heldAnt
        // The session whose text is open waits in the corner and the others walk off the screen until it closes.
        // The dial's words are nobody's, so every ant walks off while it's open.
        // A lone ant is "face", and it goes to the corner by its text like any other.
        colony.solo = dial.isOpen ? "dial" : crowd.solo.map { crowd.single ? "face" : $0 }
        // Its ant stands by the text's first line: above the middle of centred text (a question under it), else to
        // its left when there's room, else just above it.
        let shown = placed.filter(\.showing)
        if let top = shown.min(by: { $0.y < $1.y }), let left = shown.map(\.x).min() {
            colony.byText = !top.left ? SIMD2(top.x + top.width / 2, max(40, top.y - 34))
                : left >= 80 ? SIMD2(Double(left) - 40, Double(top.y + top.height / 2))
                : SIMD2(Double(left) + 30, max(40, Double(top.y) - 34))
        } else { colony.byText = nil }
        colony.families = Dictionary(crowd.sessions.compactMap { s in s.parent.map { (s.id, $0) } }) { a, _ in a }
        colony.working = Dictionary(crowd.sessions.compactMap { s in s.since.map { (s.id, $0) } }) { a, _ in a }
        colony.unseen = Set(crowd.sessions.filter(\.unseen).map(\.id))
        crowd.waiting = screen.waiting
        colony.asking = crowd.single ? (screen.waiting.isEmpty ? [] : ["face"]) : screen.waiting
        // A reply open on the pad is a finished turn you've now seen.
        if screen.mode == .reply, let id = screen.asker, crowd.sessions.contains(where: { $0.id == id && $0.unseen }) { onLooked?(id) }
        // With one session or none, a single ant plays the big face's mood; otherwise one per session not swiped away.
        // The big face dozes off by itself, but not while a question waits. While its session works, the ant shows what
        // the hooks say it's doing (thinking or running a tool), as each ant of many does.
        let mine = crowd.sessions.count == 1 ? crowd.face(crowd.sessions[0].id)?.mood : nil
        let lone = mine == .busy || mine == .focused ? mine! : face.mood == .sleep && !screen.waiting.isEmpty ? .idle : face.mood
        colony.update(crowd.single ? [("face", lone, true, crowd.sessions.first?.events)]
                      : crowd.sessions.map { s in (s.id, crowd.face(s.id)?.mood ?? .idle, s.id == crowd.front, s.events) }, at: t)
        let about = crowd.single ? "face" : slots.first(where: { $0.id == crowd.solo ?? spoke })?.id ?? crowd.front
        let anchor = about.flatMap(colony.position).map { ($0 - mid) / u } ?? f.centre
        face.aside(screen.mode == .detail || screen.mode == .roster || screen.mode == .reply, at: t)
        face.lift(screen.mode == .question, at: t)
        screen.now = t
        screen.sessions = crowd.sessions
        screen.idle()
        // The backlight dims only when nothing is happening: nobody touching, no session working or needing you.
        let happening = colony.needsYou || crowd.sessions.contains { if case .working = $0.state { true } else { $0.state == .needs || $0.state == .failed } }
        rest(screen.resting && !happening, dt: 1 / Double(max(1, l.preferredFramesPerSecond)))
        // While the dial is open its words take the screen; the rest goes back into the ants until it closes.
        dial.idle(at: t)
        if dial.isOpen { dial.root = dialRoot(); if t - serverAt > 3 { askServer() } }
        placed = dial.isOpen ? dial.place(width: Double(bounds.width), height: Double(bounds.height), turn: twist)
            : screen.place(width: Double(bounds.width), height: Double(bounds.height))
        motion.screen = SIMD2(Double(bounds.width), Double(bounds.height))
        motion.show(placed, from: SIMD2(Double(point(anchor).x), Double(point(anchor).y)), swipe: swipeWay, page: pageWay,
                    wait: Screen.wait(from: was, to: screen.mode), at: t)
        swipeWay = 0
        pageWay = 0
        was = screen.mode
        // The springs are the only motion: Core Animation's own fades and slides stay off.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drawText(motion.frame(at: t))
        drawAnts(colony.shapes(at: t))
        drawCrumbs(colony.crumbs(at: t))
        drawNames(crowd.single ? crowd.slots(at: t) : slots)
        drawGrip()
        CATransaction.commit()
    }
}

extension FaceView {
    /// The face the text comes from: the one in front when several sessions show, else the single face.
    var speaker: Face { crowd.single ? face : crowd.front.flatMap(crowd.face) ?? face }

    /// Each session's name under its ant while touched, with what it's doing while it works.
    func drawNames(_ slots: [Slot]) {
        let ids = Set(slots.map(\.id))
        for (id, n) in names where !ids.contains(id) { n.removeFromSuperlayer(); names[id] = nil }
        for s in slots {
            guard let at = colony.position(of: crowd.single ? "face" : s.id) else { continue }
            let name = names[s.id] ?? {
                let n = CATextLayer()
                n.contentsScale = UIScreen.main.scale
                n.fontSize = 11
                n.foregroundColor = UIColor(white: 0.96, alpha: 1).cgColor
                n.alignmentMode = .center
                layer.addSublayer(n)
                names[s.id] = n
                return n
            }()
            // Under the name, what it's doing, for how long and with how many subagents, while it works.
            let info = crowd.sessions.first { $0.id == s.id }
            name.string = info.map { i in
                let step = Screen.step(i, now: screen.now), agents = Screen.agents(i, now: screen.now, short: true)
                return i.since == nil ? s.name : s.name + "\n" + Screen.state(i, now: screen.now)
                    + (step.isEmpty ? "" : " · " + step) + (agents.isEmpty ? "" : " · " + agents) } ?? s.name
            name.isWrapped = true
            name.truncationMode = .end
            name.bounds = CGRect(x: 0, y: 0, width: 200, height: 30)
            name.position = CGPoint(x: min(max(at.x, 100), bounds.width - 100), y: at.y + 35)
            name.opacity = Float(s.named)
        }
    }

    func drawCrumbs(_ crumbs: [[SIMD2<Double>]]) {
        if crumbLayer.superlayer == nil {
            crumbLayer.fillColor = UIColor(white: 0.96, alpha: 1).cgColor
            crumbLayer.zPosition = -1
            layer.insertSublayer(crumbLayer, at: 0)
        }
        let path = CGMutablePath()
        for c in crumbs where c.count > 2 { path.addLines(between: c.map { CGPoint(x: $0.x, y: $0.y) }); path.closeSubpath() }
        crumbLayer.path = path
    }

    /// Each ant as layers: its body filled, then one stroked layer per width its strokes come in (thighs, shins and
    /// mandibles, antennae), so a new part draws without a layer of its own.
    func drawAnts(_ shapes: [AntShape]) {
        let ids = Set(shapes.map(\.id))
        for (id, ls) in antLayers where !ids.contains(id) { ls.forEach { $0.removeFromSuperlayer() }; antLayers[id] = nil }
        let white = UIColor(white: 0.96, alpha: 1).cgColor
        for a in shapes {
            var widths: [Double] = []
            for s in a.strokes where !widths.contains(s.width) { widths.append(s.width) }
            var ls = antLayers[a.id] ?? []
            while ls.count < widths.count + 1 {
                let l = CAShapeLayer(), fill = ls.isEmpty
                l.fillColor = fill ? white : nil
                l.strokeColor = fill ? nil : white
                l.lineCap = .round
                l.lineJoin = .round
                layer.insertSublayer(l, at: 0)
                ls.append(l)
            }
            antLayers[a.id] = ls
            let body = CGMutablePath()
            for f in a.fills { body.addLines(between: f.map { CGPoint(x: $0.x, y: $0.y) }); body.closeSubpath() }
            ls[0].path = body
            for (n, l) in ls.dropFirst().enumerated() {
                let p = CGMutablePath()
                if n < widths.count {
                    for s in a.strokes where s.width == widths[n] { p.addLines(between: s.points.map { CGPoint(x: $0.x, y: $0.y) }) }
                    l.lineWidth = CGFloat(widths[n])
                }
                l.path = p
            }
        }
    }

    /// White text on black, one layer per line, placed and scaled as its springs say this frame.
    func drawText(_ shown: [Shown]) {
        for s in shown {
            let l = s.line, t = texts[l.key] ?? {
                let t = CATextLayer()
                t.contentsScale = UIScreen.main.scale
                t.foregroundColor = UIColor(white: 0.96, alpha: 1).cgColor
                t.string = l.text
                layer.addSublayer(t)
                texts[l.key] = t
                return t
            }()
            let weight: UIFont.Weight = l.bold ? .bold : l.style == .title ? .medium : .regular
            if t.fontSize != CGFloat(l.size) {
                t.font = UIFont.systemFont(ofSize: CGFloat(l.size), weight: weight)
                t.fontSize = CGFloat(l.size)
            }
            if t.string as? String != l.text { t.string = l.text }
            t.alignmentMode = l.left ? .left : .center
            t.bounds = CGRect(x: 0, y: 0, width: l.width, height: l.height)
            t.position = CGPoint(x: s.cx, y: s.cy)
            t.opacity = Float(s.opacity)
            t.transform = CATransform3DMakeScale(CGFloat(s.sx), CGFloat(s.sy), 1)
            // Blurred only while it appears or goes; a settled line draws without the filter.
            if s.blur > 0.05 {
                if t.filters == nil, let b = FaceView.blur() { t.filters = [b] }
                t.setValue(s.blur, forKeyPath: "filters.blur.inputRadius")
            } else if t.filters != nil {
                t.filters = nil
            }
        }
        let keys = Set(shown.map(\.line.key))
        for (k, t) in texts where !keys.contains(k) { t.removeFromSuperlayer(); texts[k] = nil }
        drawCountdown(shown)
        drawPages()
    }

    /// A note that stops mattering soon (couldn't record, not sent) has a small pie beside it, emptying as its time
    /// runs out.
    /// Reading a long reply, a column of dots left of the text says where you are, like the Apple Watch's crown:
    /// the page showing is the bright one, and it slides along as the pages turn.
    private func drawPages() {
        if dots.superlayer == nil { layer.addSublayer(dots) }
        let p = screen.pages(width: Double(bounds.width), height: Double(bounds.height))
        let now = CACurrentMediaTime(), dt = min(0.05, now - dotsAt)
        dotsAt = now
        dotsShown.step(to: p.map { $0.of > 1 ? 1 : 0 } ?? 0, k: 120, damping: 1, dt: dt)
        if let p { dotAt.step(to: Double(p.page), k: 160, damping: 0.8, dt: dt); dotCount = p.of }
        dots.opacity = Float(max(0, min(1, dotsShown.x)))
        guard dotCount > 1, dotsShown.x > 0.01 else { return }
        let gap = 11.0, x = Double(bounds.width) * 0.3 - 18 + screen.drift.x
        let top = Double(bounds.height) * 0.5 - gap * Double(dotCount - 1) / 2 + screen.drift.y
        let path = CGMutablePath()
        for i in 0..<dotCount {
            let near = max(0, 1 - abs(Double(i) - dotAt.x)), r = 2 + 1.5 * near
            path.addEllipse(in: CGRect(x: x - r, y: top + gap * Double(i) - r, width: 2 * r, height: 2 * r))
        }
        dots.path = path
        dots.fillColor = UIColor(white: 0.96, alpha: 1).cgColor
    }

    /// Resting (nobody near, nothing needing you), the backlight fades down over a few seconds; anything that needs
    /// you or a touch brings it straight back to the level it was at.
    func rest(_ resting: Bool, dt: Double) {
        if resting && userBrightness == nil { userBrightness = UIScreen.main.brightness }
        guard let full = userBrightness else { return }
        lit.step(to: resting ? 0 : 1, k: resting ? 3 : 80, damping: 1, dt: dt)
        let dim = min(full, 0.08), level = dim + (full - dim) * CGFloat(max(0, min(1, lit.x)))
        if !resting && lit.x > 0.99 { UIScreen.main.brightness = full; userBrightness = nil; lit = Spring(x: 1); return }
        if abs(UIScreen.main.brightness - level) > 0.004 { UIScreen.main.brightness = level }
    }

    /// Leaving the app, the backlight goes back to where it was.
    func wake() {
        if let full = userBrightness { UIScreen.main.brightness = full }
        userBrightness = nil
        lit = Spring(x: 1)
    }

    private func drawCountdown(_ shown: [Shown]) {
        if pie.superlayer == nil { pie.fillColor = UIColor(white: 0.96, alpha: 1).cgColor; layer.addSublayer(pie) }
        guard let (end, span) = noteEnds, span > 0, let s = shown.first(where: { $0.line.key.hasPrefix("note:") }) else {
            pie.opacity = 0
            return
        }
        let left = max(0, min(1, (end - CACurrentMediaTime()) / span)), r = s.line.size * 0.4
        let width = (s.line.text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: CGFloat(s.line.size))]).width
        let c = CGPoint(x: s.cx - Double(width) * s.sx / 2 - r * 2, y: s.cy)
        let path = UIBezierPath()
        path.move(to: c)
        path.addArc(withCenter: c, radius: r, startAngle: -.pi / 2, endAngle: -.pi / 2 + 2 * .pi * left, clockwise: true)
        path.close()
        pie.path = path.cgPath
        pie.opacity = Float(s.opacity)
    }

    /// A Gaussian blur for a layer. iOS has no public layer blur, so this is Core Animation's own CAFilter, which
    /// is fine for an app installed with TrollStore; if it's ever missing, text just doesn't blur.
    static func blur() -> NSObject? {
        guard let type = NSClassFromString("CAFilter") as? NSObject.Type,
              let f = type.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?.takeUnretainedValue() as? NSObject
        else { return nil }
        f.setValue("blur", forKey: "name")
        return f
    }
}

final class FaceController: UIViewController {
    override func loadView() { view = FaceView() }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        app.isIdleTimerDisabled = true
        return true
    }
}

@objc(SceneDelegate)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    var buddy: BuddyLink?
    var drive: Drive?
    func sceneWillResignActive(_: UIScene) { (window?.rootViewController?.view as? FaceView)?.wake() }
    func scene(_ scene: UIScene, willConnectTo _: UISceneSession, options _: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: scene)
        let controller = FaceController()
        window?.rootViewController = controller
        buddy = BuddyLink(view: controller.view as! FaceView)
        #if targetEnvironment(simulator)
        drive = Drive(view: controller.view as! FaceView, args: CommandLine.arguments)
        #endif
        window?.makeKeyAndVisible()
        // To try the screens without the Buddy link: launch with `-jeta "jeta: server needs you · Which hostname?"`.
        let args = CommandLine.arguments
        for (i, a) in args.enumerated() where a == "-jeta" && i + 1 < args.count {
            let event: [String: Any] = ["evt": "turn", "role": "assistant", "content": [["type": "text", "text": args[i + 1]]]]
            if let data = try? JSONSerialization.data(withJSONObject: event) { (controller.view as? FaceView)?.take(data) }
        }
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))

extension FaceView: UIGestureRecognizerDelegate {
    // The drag is only for text, and it lets the swipes and the hold see the same touch.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        g is UIPanGestureRecognizer ? carries : super.gestureRecognizerShouldBegin(g)
    }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }
}

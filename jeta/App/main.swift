import AudioToolbox
import UIKit

/// Draws the colony: one white ant per Claude Code session, each acting out its session's mood. The faces are still
/// the mood models (blinks, moods, dozing off), but only their ants are drawn.
final class FaceView: UIView {
    let face = Face(seed: UInt64(Date().timeIntervalSince1970), now: CACurrentMediaTime())
    private var link: CADisplayLink?
    /// The manager's notices, and what the screen shows of them.
    private var board = NoticeBoard(), screen = Screen()
    /// The text's springs, a layer for each line they show, and where each line rests (to hit-test options).
    private let motion = TextMotion()
    private var texts: [String: CATextLayer] = [:], placed: [Placed] = []
    /// The way the last swipe went (-1 left, 1 right), and the mode the text was last shown for.
    private var swipeWay = 0.0, was = Screen.Mode.face
    /// An option picked: the line for the manager, and the session it goes to.
    var onChoose: ((String, String?) -> Void)?
    /// A chord's decision (true for once), and whether a prompt is up for one to answer.
    var onDecide: ((Bool) -> Bool)?, canDecide: (() -> Bool)?
    /// A tap brought a session that needs you forward: its prompt is the one the next tap answers.
    var onFocus: ((String) -> Void)?
    private var talk: Talk?
    /// One face per Claude Code session, when two or more report through the hooks; with one, the face above.
    let crowd = Crowd(seed: UInt64(Date().timeIntervalSince1970) &+ 1, now: CACurrentMediaTime())
    private var names: [String: CATextLayer] = [:]
    private let more = CATextLayer()
    /// An ant for each face: the crowd's, or the single face's.
    let colony = Colony(seed: UInt64(Date().timeIntervalSince1970) &+ 2, now: CACurrentMediaTime())
    private var antLayers: [String: [CAShapeLayer]] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        more.contentsScale = UIScreen.main.scale
        more.fontSize = 13
        more.foregroundColor = UIColor(white: 0.55, alpha: 1).cgColor
        more.alignmentMode = .center
        layer.addSublayer(more)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        for way in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped))
            swipe.direction = way
            addGestureRecognizer(swipe)
        }
        let down = UISwipeGestureRecognizer(target: self, action: #selector(swipedDown))
        down.direction = .down
        addGestureRecognizer(down)
        isMultipleTouchEnabled = true
        talk = Talk(face: face, in: self)
        onChoose = { [weak self] in self?.talk?.say($0, to: $1) }
        talk?.onNote = { [weak self] in self?.screen.note = $0 }
        talk?.session = { [weak self] p in self?.session(at: p) }
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
    func ask(_ p: Prompt?) {
        guard let p else { return screen.answered() }
        let parts = p.hint.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let (who, what) = parts.count == 2 ? (parts[0], parts[1]) : ("Claude", p.hint)
        screen.ask(session: who, what.isEmpty ? p.tool : "\(p.tool): \(what)")
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
    @objc private func tapped(_ g: UITapGestureRecognizer) {
        // A tap right after talking stops the pending Enter.
        if talk?.tapped() == true { return }
        // A tap on an option sends it to the manager, like `server: 8443`; it pops and the face glances at it.
        let p = g.location(in: self)
        // A permission request is answered only by its buttons: Allow or Deny, never a tap anywhere else.
        if screen.asking != nil, let (i, o) = option(at: p) {
            guard onDecide?(i == 0) == true else { return }
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
        // question if it has one, else just looks at you.
        let t = CACurrentMediaTime(), hit = crowd.single ? nil : colony.hit(SIMD2(Double(p.x), Double(p.y)))
        if let id = hit { crowd.touch(id, at: t) }
        if let id = hit, id != crowd.front {
            if crowd.slots(at: t).first(where: { $0.id == id }).flatMap({ s in crowd.face(s.id)?.mood }) == .attention {
                crowd.focus(id, at: t)
                onFocus?(id)
            } else if let name = crowd.slots(at: t).first(where: { $0.id == id })?.name, screen.show(session: name) {
            } else {
                crowd.face(id)?.poke(at: .zero, t: t)
            }
            return
        }
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
        // On the bare faces, swiping one away hides it until its session's next event; nothing changes in Claude.
        let t = CACurrentMediaTime()
        let p = g.location(in: self)
        if screen.mode == .face, !crowd.single, let id = colony.hit(SIMD2(Double(p.x), Double(p.y))) {
            crowd.hide(id, at: t)
            return
        }
        swipeWay = g.direction == .left ? -1 : 1
        screen.swipe()
    }

    // Holding anywhere is talking (Talk owns that gesture), so the session list opens with a swipe down on the bare face.
    @objc private func swipedDown(_ g: UISwipeGestureRecognizer) {
        screen.swipeDown()
    }

    // Two or more fingers are a chord; with a prompt up, two close fingers answer it.
    private var chord = Chord()
    private var fingers: [Int: SIMD2<Double>] = [:]

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
        track(e)
        let down = e?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled } ?? []
        motion.press(down.count == 1 ? down.first.flatMap { option(at: $0.location(in: self)) }?.1.key : nil, at: CACurrentMediaTime())
    }
    override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent?) { track(e) }
    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) { track(e); motion.press(nil, at: CACurrentMediaTime()) }
    override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) { track(e); motion.press(nil, at: CACurrentMediaTime()) }

    private func feedChord(at t: Double) {
        chord.prompt = canDecide?() ?? false
        let u = Double(min(bounds.width, bounds.height)), mid = SIMD2(Double(bounds.midX), Double(bounds.midY))
        let centre = fingers.isEmpty ? nil : (fingers.values.reduce(.zero, +) / Double(fingers.count) - mid) / u
        for event in chord.update(fingers, at: t) {
            switch event {
            // Every step is a click you hear and a snap of the eyes to the fingers: the SE has no Taptic Engine.
            case .began, .step:
                AudioServicesPlaySystemSound(1104)
                if let centre { face.poke(at: centre, t: t) }
            case .armed(.once): face.set(.proud, at: t)
            case .armed(.deny): face.set(.focused, at: t)
            case .armed(nil): face.set(.attention, at: t)
            case .decided(let d):
                if onDecide?(d == .once) == true { face.set(d == .once ? .celebrate : .idle, at: t) }
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
        let slots = crowd.single ? [] : crowd.slots(at: t)
        // Text comes out of the face it's about: the one forward, else the single face.
        var anchor = slots.first(where: \.front).map { $0.centre + crowd.face($0.id)!.frame(at: t).centre * $0.scale } ?? f.centre
        do {
            colony.screen = SIMD2(Double(bounds.width), Double(bounds.height))
            // While talking, every ant turns to the finger held down.
            colony.listenAt = face.mood == .listening
                ? (talk?.heldAt).map { SIMD2(Double($0.x), Double($0.y)) } ?? SIMD2(Double(bounds.midX), Double(bounds.height) - 120) : nil
            // With one session or none, a single ant plays the big face's mood.
            colony.update(slots.isEmpty ? [("face", face.mood, true, crowd.sessions.first?.events)]
                          : slots.map { s in (s.id, crowd.face(s.id)!.mood, s.front, crowd.sessions.first { $0.id == s.id }?.events) }, at: t)
            if let p = colony.position(of: slots.first(where: \.front)?.id ?? (slots.isEmpty ? "face" : "")) { anchor = (p - mid) / u }
        }
        face.aside(screen.mode == .detail || screen.mode == .roster, at: t)
        face.lift(screen.mode == .question, at: t)
        placed = screen.place(width: Double(bounds.width), height: Double(bounds.height))
        motion.screen = SIMD2(Double(bounds.width), Double(bounds.height))
        motion.show(placed, from: SIMD2(Double(point(anchor).x), Double(point(anchor).y)), swipe: swipeWay,
                    wait: Screen.wait(from: was, to: screen.mode), at: t)
        swipeWay = 0
        was = screen.mode
        // The springs are the only motion: Core Animation's own fades and slides stay off.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drawText(motion.frame(at: t))
        drawAnts(colony.shapes(at: t))
        drawNames(slots)
        CATransaction.commit()
    }
}

extension FaceView {
    /// The face the text comes from: the one in front when several sessions show, else the single face.
    var speaker: Face { crowd.single ? face : crowd.front.flatMap(crowd.face) ?? face }

    /// Each session's folder name under its ant in white while touched, and "+N" at the bottom for the ones folded away.
    func drawNames(_ slots: [Slot]) {
        let ids = Set(slots.map(\.id))
        for (id, n) in names where !ids.contains(id) { n.removeFromSuperlayer(); names[id] = nil }
        for s in slots {
            guard let at = colony.position(of: s.id) else { continue }
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
            name.string = s.name
            name.bounds = CGRect(x: 0, y: 0, width: 120, height: 16)
            name.position = CGPoint(x: at.x, y: at.y + 28)
            name.opacity = Float(s.named)
        }
        more.string = crowd.overflow > 0 && !slots.isEmpty ? "+\(crowd.overflow)" : ""
        more.bounds = CGRect(x: 0, y: 0, width: 40, height: 18)
        more.position = CGPoint(x: bounds.midX, y: bounds.height - 24)
    }

    /// Each ant as four layers: its body filled, then its thighs, shins and antennae stroked, each at its own width.
    func drawAnts(_ shapes: [AntShape]) {
        let ids = Set(shapes.map(\.id))
        for (id, ls) in antLayers where !ids.contains(id) { ls.forEach { $0.removeFromSuperlayer() }; antLayers[id] = nil }
        let white = UIColor(white: 0.96, alpha: 1).cgColor
        for a in shapes {
            let ls = antLayers[a.id] ?? (0..<4).map { i in
                let l = CAShapeLayer()
                l.fillColor = i == 0 ? white : nil
                l.strokeColor = i == 0 ? nil : white
                l.lineCap = .round
                l.lineJoin = .round
                layer.insertSublayer(l, at: 0)
                return l
            }
            antLayers[a.id] = ls
            let body = CGMutablePath()
            for f in a.fills { body.addLines(between: f.map { CGPoint(x: $0.x, y: $0.y) }); body.closeSubpath() }
            ls[0].path = body
            // Six thighs, six shins, two antennae.
            for (n, part) in [a.strokes.prefix(6), a.strokes.dropFirst(6).prefix(6), a.strokes.suffix(2)].enumerated() {
                let p = CGMutablePath()
                for s in part { p.addLines(between: s.points.map { CGPoint(x: $0.x, y: $0.y) }) }
                ls[n + 1].path = p
                ls[n + 1].lineWidth = CGFloat(part.first?.width ?? 1)
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
    func scene(_ scene: UIScene, willConnectTo _: UISceneSession, options _: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: scene)
        let controller = FaceController()
        window?.rootViewController = controller
        buddy = BuddyLink(view: controller.view as! FaceView)
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

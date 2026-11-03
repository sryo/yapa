import AudioToolbox
import UIKit

/// Draws a Face: each eye is one white oval, filled from the model's outline, with its trail when it moves fast.
final class FaceView: UIView {
    let face = Face(seed: UInt64(Date().timeIntervalSince1970), now: CACurrentMediaTime())
    private let eyes = [CAShapeLayer(), CAShapeLayer()]
    private var link: CADisplayLink?
    /// The manager's notices, and what the screen shows of them.
    private var board = NoticeBoard(), screen = Screen()
    /// The text's springs, a layer for each line they show, and where each line rests (to hit-test options).
    private let motion = TextMotion()
    private var texts: [String: CATextLayer] = [:], placed: [Placed] = []
    /// The way the last swipe went (-1 left, 1 right), and the mode the text was last shown for.
    private var swipeWay = 0.0, was = Screen.Mode.face
    var onChoose: ((String) -> Void)?
    /// Takes a tap first, to answer a waiting prompt; returns true when it used it.
    var onTap: ((CGPoint) -> Bool)?
    /// A tap brought a session that needs you forward: its prompt is the one the next tap answers.
    var onFocus: ((String) -> Void)?
    private var talk: Talk?
    /// One face per Claude Code session, when two or more report through the hooks; with one, the face above.
    let crowd = Crowd(seed: UInt64(Date().timeIntervalSince1970) &+ 1, now: CACurrentMediaTime())
    private var crowdEyes: [String: [CAShapeLayer]] = [:], crowdNames: [String: CATextLayer] = [:]
    private let more = CATextLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        for eye in eyes {
            eye.fillColor = UIColor(white: 0.96, alpha: 1).cgColor
            layer.addSublayer(eye)
        }
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
        onChoose = { [weak self] in self?.talk?.say($0) }
        talk?.onNote = { [weak self] in self?.screen.note = $0 }
        // The face hops as it says a question and gulps when its words come back.
        motion.onSay = { [weak self] in self?.speaker.say(at: CACurrentMediaTime()) }
        motion.onSwallow = { [weak self] in self?.speaker.swallow(at: CACurrentMediaTime()) }
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A turn event from the Claude app (any session); the manager's `jeta:` lines become notices.
    /// Returns the sessions whose notice this event added or changed.
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
        if let (i, o) = option(at: p), let line = screen.choose(i) {
            AudioServicesPlaySystemSound(1104)
            motion.choose(o.key, at: CACurrentMediaTime())
            poke(at: CGPoint(x: o.x + o.width / 2, y: o.y + o.height / 2))
            onChoose?(line)
            return
        }
        guard screen.mode == .face else { screen.tap(); return }
        // With a face per session, a tap on one that isn't forward picks it: one that needs you steps forward (its
        // prompt is then the one answered), another opens its question if it has one, else just looks at you.
        let t = CACurrentMediaTime()
        if !crowd.single, let id = crowd.hit(unit(p), at: t), id != crowd.front {
            if crowd.slots(at: t).first(where: { $0.id == id }).flatMap({ s in crowd.face(s.id)?.mood }) == .attention {
                crowd.focus(id, at: t)
                onFocus?(id)
            } else if let name = crowd.slots(at: t).first(where: { $0.id == id })?.name, screen.show(session: name) {
            } else {
                crowd.face(id)?.poke(at: .zero, t: t)
            }
            return
        }
        if onTap?(p) == true { return }
        poke(at: p)
    }

    /// A point on screen in fractions of the short side from the centre.
    private func unit(_ p: CGPoint) -> SIMD2<Double> {
        let u = Double(min(bounds.width, bounds.height))
        return SIMD2((Double(p.x) - Double(bounds.midX)) / u, (Double(p.y) - Double(bounds.midY)) / u)
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
        if screen.mode == .face, !crowd.single, let id = crowd.hit(unit(g.location(in: self)), at: t) {
            crowd.hide(id, at: t)
            return
        }
        swipeWay = g.direction == .left ? -1 : 1
        screen.swipe()
    }

    // Holding anywhere is talking (Talk owns that gesture), so the session list opens with a swipe down on the bare face.
    @objc private func swipedDown(_ g: UISwipeGestureRecognizer) {
        if screen.mode == .face { screen.longPress() }
    }

    // Two or more fingers are a chord. Until the Buddy link lands, the attention mood stands in for a prompt.
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
        chord.prompt = face.mood == .attention
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
            case .decided(let d): face.set(d == .once ? .celebrate : .idle, at: t)
            case .ended: break
            }
        }
    }

    @objc private func tick(_ l: CADisplayLink) {
        let t = CACurrentMediaTime(), f = face.frame(at: t)
        // Fingers held still still settle into a chord.
        if !fingers.isEmpty { feedChord(at: t) }
        // Asleep only breathes, so 30 fps keeps it smooth for less power.
        l.preferredFramesPerSecond = face.isActive(at: t) ? 60 : 30
        let u = Double(min(bounds.width, bounds.height)), mid = SIMD2(Double(bounds.midX), Double(bounds.midY))
        // Let the face wander anywhere its eyes still fit, even when it steps up close.
        face.bounds = SIMD2(max(0, Double(bounds.width) / u / 2 - 0.27), 0.3)
        face.screen = SIMD2(Double(bounds.width) / u / 2, Double(bounds.height) / u / 2)
        let point = { (p: SIMD2<Double>) in CGPoint(x: mid.x + p.x * u, y: mid.y + p.y * u) }
        crowd.screen = face.screen
        let slots = crowd.single ? [] : crowd.slots(at: t)
        // Text comes out of the face it's about: the one forward, else the single face.
        let anchor = slots.first(where: \.front).map { $0.centre + crowd.face($0.id)!.frame(at: t).centre * $0.scale } ?? f.centre
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
        for (eye, s) in zip(eyes, f.eyes) { eye.path = slots.isEmpty ? path(s, point) : nil }
        drawCrowd(slots, at: t, point: point, unit: u)
        CATransaction.commit()
    }
}

extension FaceView {
    /// The face the text comes from: the one in front when several sessions show, else the single face.
    var speaker: Face { crowd.single ? face : crowd.front.flatMap(crowd.face) ?? face }

    /// An eye's oval, with its trail, as a path on screen.
    func path(_ s: Stroke, _ point: (SIMD2<Double>) -> CGPoint) -> CGPath {
        let path = CGMutablePath()
        for shape in [s.outline()] + s.trailOutlines() {
            path.addLines(between: shape.map(point))
            path.closeSubpath()
        }
        return path
    }

    /// Each session's face where its slot is, its folder name under it in dim text, and "+N" for the ones folded away.
    func drawCrowd(_ slots: [Slot], at t: Double, point: (SIMD2<Double>) -> CGPoint, unit u: Double) {
        let ids = Set(slots.map(\.id))
        for id in Array(crowdEyes.keys) where !ids.contains(id) {
            crowdEyes[id]?.forEach { $0.removeFromSuperlayer() }; crowdEyes[id] = nil
            crowdNames[id]?.removeFromSuperlayer(); crowdNames[id] = nil
        }
        for s in slots {
            let layers = crowdEyes[s.id] ?? (0..<2).map { _ in
                let l = CAShapeLayer()
                l.fillColor = UIColor(white: 0.96, alpha: 1).cgColor
                layer.addSublayer(l)
                return l
            }
            crowdEyes[s.id] = layers
            let frame = crowd.face(s.id)!.frame(at: t)
            for (l, e) in zip(layers, frame.eyes) { l.path = path(e, { point(s.centre + $0 * s.scale) }) }
            let name = crowdNames[s.id] ?? {
                let n = CATextLayer()
                n.contentsScale = UIScreen.main.scale
                n.fontSize = 11
                n.foregroundColor = UIColor(white: 0.45, alpha: 1).cgColor
                n.alignmentMode = .center
                layer.addSublayer(n)
                crowdNames[s.id] = n
                return n
            }()
            name.string = s.name
            name.bounds = CGRect(x: 0, y: 0, width: 120, height: 16)
            name.position = point(s.centre + SIMD2(0, 0.17 * s.scale + 0.03))
            name.opacity = Float(min(1, s.scale / 0.2))
        }
        more.string = crowd.overflow > 0 && !slots.isEmpty ? "+\(crowd.overflow)" : ""
        if let last = slots.filter({ !$0.front }).max(by: { $0.centre.x < $1.centre.x }) {
            more.bounds = CGRect(x: 0, y: 0, width: 40, height: 18)
            more.position = point(last.centre + SIMD2(0.2 * last.scale + 0.05, 0))
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

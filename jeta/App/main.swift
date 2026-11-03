import AudioToolbox
import UIKit

/// Draws a Face: each eye is one white oval, filled from the model's outline, with its trail when it moves fast.
final class FaceView: UIView {
    let face = Face(seed: UInt64(Date().timeIntervalSince1970), now: CACurrentMediaTime())
    private let eyes = [CAShapeLayer(), CAShapeLayer()]
    private var link: CADisplayLink?
    /// The manager's notices, and what the screen shows of them.
    private var board = NoticeBoard(), screen = Screen()
    private var texts: [CATextLayer] = []
    /// Where each option button was drawn, to hit-test taps; and where a chosen line goes (che's text path).
    private var optionFrames: [CGRect] = [], boxes: [CALayer] = []
    var onChoose: ((String) -> Void)?
    /// Takes a tap first, to answer a waiting prompt; returns true when it used it.
    var onTap: ((CGPoint) -> Bool)?
    private var talk: Talk?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        for eye in eyes {
            eye.fillColor = UIColor(white: 0.96, alpha: 1).cgColor
            layer.addSublayer(eye)
        }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped))
        swipe.direction = [.left, .right]
        addGestureRecognizer(swipe)
        let down = UISwipeGestureRecognizer(target: self, action: #selector(swipedDown))
        down.direction = .down
        addGestureRecognizer(down)
        isMultipleTouchEnabled = true
        talk = Talk(face: face, in: self)
        onChoose = { [weak self] in self?.talk?.say($0) }
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
        // A tap on an option sends it to the manager, like `server: 8443`.
        if let i = optionFrames.firstIndex(where: { $0.insetBy(dx: -8, dy: -8).contains(g.location(in: self)) }),
           let line = screen.choose(i) {
            AudioServicesPlaySystemSound(1104)
            onChoose?(line)
            return
        }
        guard screen.mode == .face else { screen.tap(); return }
        let p = g.location(in: self)
        if onTap?(p) == true { return }
        let u = Double(min(bounds.width, bounds.height))
        face.poke(at: SIMD2((Double(p.x) - Double(bounds.midX)) / u, (Double(p.y) - Double(bounds.midY)) / u), t: CACurrentMediaTime())
    }

    @objc private func swiped(_ g: UISwipeGestureRecognizer) { screen.swipe() }

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
    override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) { track(e) }
    override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent?) { track(e) }
    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) { track(e) }
    override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) { track(e) }

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
        face.aside(screen.mode == .detail || screen.mode == .roster, at: t)
        drawText(u: CGFloat(u))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (eye, s) in zip(eyes, f.eyes) {
            let path = CGMutablePath()
            for shape in [s.outline()] + s.trailOutlines() {
                path.addLines(between: shape.map(point))
                path.closeSubpath()
            }
            eye.path = path
        }
        CATransaction.commit()
    }
}

extension FaceView {
    /// White text on black: a title, the body a little dimmer, hints dimmer still. A question sits under the face;
    /// the detail and the session list take the right of the screen while the face waits in the corner.
    func drawText(u: CGFloat) {
        let open = screen.mode == .detail || screen.mode == .roster
        let size = u * 0.055, left = open ? bounds.width * 0.3 : bounds.width * 0.12
        let width = Int((bounds.width - left - bounds.width * 0.08) / (size * 0.52))
        let lines = screen.lines(width: max(12, width))
        while texts.count < lines.count {
            let t = CATextLayer()
            t.contentsScale = UIScreen.main.scale
            t.foregroundColor = UIColor(white: 0.96, alpha: 1).cgColor
            layer.addSublayer(t)
            texts.append(t)
        }
        var y = open ? bounds.height * 0.14 : bounds.height * (lines.contains { $0.style == .option } ? 0.6 : 0.66)
        optionFrames = []
        // Options sit side by side as outlined buttons, on one row.
        let options = lines.filter { $0.style == .option }
        let optionWidth = options.isEmpty ? 0 : min(bounds.width * 0.22, (bounds.width - (open ? left : bounds.width * 0.12) * 2) / CGFloat(options.count) - 10)
        var optionX = open ? left : (bounds.width - (optionWidth + 10) * CGFloat(options.count) + 10) / 2
        for (i, t) in texts.enumerated() {
            guard i < lines.count else { t.string = nil; continue }
            let l = lines[i]
            if l.style == .option {
                t.string = l.text
                t.font = UIFont.systemFont(ofSize: size, weight: .medium)
                t.fontSize = size
                t.opacity = 1
                t.alignmentMode = .center
                // The outline is its own layer, so the label can sit centred inside it.
                let box = CGRect(x: optionX, y: y, width: optionWidth, height: size * 1.9)
                t.frame = CGRect(x: box.minX, y: box.midY - size * 0.62, width: box.width, height: size * 1.4)
                if boxes.count <= optionFrames.count {
                    let b = CALayer()
                    b.borderColor = UIColor(white: 0.96, alpha: 0.6).cgColor
                    b.borderWidth = 1
                    layer.addSublayer(b)
                    boxes.append(b)
                }
                boxes[optionFrames.count].frame = box
                boxes[optionFrames.count].cornerRadius = box.height / 2
                boxes[optionFrames.count].isHidden = false
                optionFrames.append(box)
                optionX += optionWidth + 10
                if i + 1 < lines.count, lines[i + 1].style != .option { y += size * 2.5 }
                continue
            }
            let s = l.style == .title ? size * 1.1 : l.style == .body ? size : size * 0.85
            t.string = l.text
            t.font = UIFont.systemFont(ofSize: s, weight: l.style == .title ? .medium : .regular)
            t.fontSize = s
            t.opacity = l.style == .title ? 1 : l.style == .body ? 0.65 : 0.4
            t.alignmentMode = open ? .left : .center
            t.frame = CGRect(x: open ? left : 0, y: y, width: open ? bounds.width - left : bounds.width, height: s * 1.4)
            y += s * (l.style == .hint && i > 0 && lines[i - 1].style != .hint ? 2.0 : 1.5)
        }
        for b in boxes.dropFirst(optionFrames.count) { b.isHidden = true }
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

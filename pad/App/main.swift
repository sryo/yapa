import AudioToolbox
import UIKit

/// Draws a Face: each eye is one white oval, filled from the model's outline, with its trail when it moves fast.
final class FaceView: UIView {
    let face = Face(seed: UInt64(Date().timeIntervalSince1970), now: CACurrentMediaTime())
    private let eyes = [CAShapeLayer(), CAShapeLayer()]
    private var link: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        for eye in eyes {
            eye.fillColor = UIColor(white: 0.96, alpha: 1).cgColor
            layer.addSublayer(eye)
        }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(poke)))
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(nextMood)))
        isMultipleTouchEnabled = true
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError() }

    // A tap wakes the face and draws its eyes to the finger.
    @objc private func poke(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self), u = Double(min(bounds.width, bounds.height))
        face.poke(at: SIMD2((Double(p.x) - Double(bounds.midX)) / u, (Double(p.y) - Double(bounds.midY)) / u), t: CACurrentMediaTime())
    }

    // A long press shows the next mood, to try them out.
    @objc private func nextMood(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let all = Mood.allCases, i = all.firstIndex(of: face.mood)!
        face.set(all[(i + 1) % all.count], at: CACurrentMediaTime())
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
    func scene(_ scene: UIScene, willConnectTo _: UISceneSession, options _: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: scene)
        window?.rootViewController = FaceController()
        window?.makeKeyAndVisible()
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))

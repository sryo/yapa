import UIKit

/// Draws a Face: each eye is one white, round-capped stroke straight from the model.
final class FaceView: UIView {
    let face = Face(seed: UInt64(Date().timeIntervalSince1970), now: CACurrentMediaTime())
    private let eyes = [CAShapeLayer(), CAShapeLayer()]
    private var link: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        for eye in eyes {
            eye.fillColor = nil
            eye.strokeColor = UIColor(white: 0.96, alpha: 1).cgColor
            eye.lineCap = .round
            layer.addSublayer(eye)
        }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(nextMood)))
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Until the Hardware Buddy link drives it, a tap shows the next mood.
    @objc private func nextMood() {
        let all = Mood.allCases, i = all.firstIndex(of: face.mood)!
        face.set(all[(i + 1) % all.count], at: CACurrentMediaTime())
    }

    @objc private func tick(_ l: CADisplayLink) {
        let t = CACurrentMediaTime(), f = face.frame(at: t)
        // Asleep only breathes, so 30 fps keeps it smooth for less power.
        l.preferredFramesPerSecond = face.isActive(at: t) ? 60 : 30
        let u = Double(min(bounds.width, bounds.height)), mid = SIMD2(Double(bounds.midX), Double(bounds.midY))
        let point = { (p: SIMD2<Double>) in CGPoint(x: mid.x + p.x * u, y: mid.y + p.y * u) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (eye, s) in zip(eyes, f.eyes) {
            let path = CGMutablePath()
            path.move(to: point(s.p0))
            path.addQuadCurve(to: point(s.p1 + SIMD2(1e-4, 0)), control: point(s.c))
            eye.path = path
            eye.lineWidth = CGFloat(s.width * u)
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

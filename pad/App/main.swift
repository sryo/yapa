import UIKit

/// Draws a Face: each eye is one shape layer whose path is the model's outline, glowing in its own colour.
final class FaceView: UIView {
    let face = Face(seed: UInt64(Date().timeIntervalSince1970), now: CACurrentMediaTime())
    private let eyes = [CAShapeLayer(), CAShapeLayer()]
    private var link: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        for eye in eyes {
            eye.shadowOffset = .zero
            eye.shadowOpacity = 0.85
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
        let t = CACurrentMediaTime(), f = face.frame(at: t), p = f.pose
        l.preferredFramesPerSecond = face.isActive(at: t) ? 60 : 15
        // Everything is in units of the short side, so the face fills the same band in either orientation.
        let u = min(bounds.width, bounds.height), mid = CGPoint(x: bounds.midX, y: bounds.midY)
        let hue = p.hue - floor(p.hue)
        let color = UIColor(hue: CGFloat(hue), saturation: CGFloat(p.sat), brightness: CGFloat(p.light), alpha: 1).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, (eye, pose)) in zip(eyes, [p.left, p.right]).enumerated() {
            let side = i == 0 ? -1.0 : 1.0
            let points = Face.outline(pose, inner: -side, gaze: f.gaze, blink: (f.blinkHeight, f.blinkWidth), squash: f.squash)
            let path = CGMutablePath()
            path.addLines(between: points.map { CGPoint(x: $0.x * Double(u), y: $0.y * Double(u)) })
            path.closeSubpath()
            eye.path = path
            eye.shadowPath = path
            eye.fillColor = color
            eye.shadowColor = color
            eye.shadowRadius = u * 0.045
            eye.position = CGPoint(x: mid.x + CGFloat(side * 0.235 + f.gaze.x * 0.3) * u,
                                   y: mid.y + CGFloat(pose.y + f.gaze.y * 0.3) * u)
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

import UIKit

/// Draws a Face with two shape layers per eye: the eye itself, and a mask that the lids cut into.
final class FaceView: UIView {
    let face = Face(seed: UInt64(Date().timeIntervalSince1970), now: CACurrentMediaTime())
    private let eyes = [CAShapeLayer(), CAShapeLayer()]
    private let lids = [CAShapeLayer(), CAShapeLayer()]
    private var link: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        for (eye, lid) in zip(eyes, lids) {
            lid.fillRule = .evenOdd
            eye.mask = lid
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
        l.preferredFramesPerSecond = face.isActive(at: t) ? 60 : 15
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let w = bounds.width, mid = CGPoint(x: bounds.midX, y: bounds.midY)
        let color = UIColor(hue: CGFloat(f.pose.hue), saturation: 0.75, brightness: face.mood == .sleep ? 0.45 : 1, alpha: 1).cgColor
        for (i, (eye, pose)) in zip(eyes, [f.pose.left, f.pose.right]).enumerated() {
            let side: CGFloat = i == 0 ? -1 : 1
            let ew = CGFloat(pose.width) * w, eh = CGFloat(pose.height * f.squash) * w
            let open = CGFloat(max(0, min(1, pose.open)) * f.blink)
            let smile = CGFloat(max(0, min(1, pose.smile)))
            // The top lid pushes down; a smile bites an arc out of the bottom, leaving a ^ shape.
            let top = eh * (1 - max(0, min(1, open)))
            let h = max(2, eh - top)
            let r = min(CGFloat(pose.radius) * w, h / 2, ew / 2)
            eye.path = UIBezierPath(roundedRect: CGRect(x: -ew / 2, y: -eh / 2 + top, width: ew, height: h), cornerRadius: r).cgPath
            let lid = UIBezierPath(rect: CGRect(x: -ew, y: -eh, width: ew * 2, height: eh * 2))
            if smile > 0.01 { lid.append(UIBezierPath(ovalIn: CGRect(x: -ew * 0.7, y: eh / 2 - smile * eh * 0.9, width: ew * 1.4, height: eh * 1.2))) }
            lids[i].path = lid.cgPath
            eye.fillColor = color
            eye.position = CGPoint(x: mid.x + side * w * 0.19 + CGFloat(f.gaze.x) * w * 0.25,
                                   y: mid.y + CGFloat(pose.y + f.gaze.y * 0.5) * w)
            eye.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(pose.tilt)))
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

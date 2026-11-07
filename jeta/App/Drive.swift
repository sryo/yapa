import Network
import UIKit

/// test/jeta-flows' hands and eyes: launched with `-drive <port>` (the Simulator only), the pad takes taps, swipes,
/// holds and two-finger twists over HTTP on this Mac, through the same code the gestures reach, and says what's on
/// the screen. `-che host:port` and `-yata <url>` point it at stand-ins, so nothing is typed into a real session.
final class Drive {
    private let view: FaceView, listener: NWListener

    init?(view: FaceView, args: [String]) {
        func arg(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let p = arg("-drive"), let port = NWEndpoint.Port(p), let l = try? NWListener(using: .tcp, on: port) else { return nil }
        self.view = view; listener = l
        if let che = arg("-che"), let i = che.lastIndex(of: ":"), let cp = UInt16(che[che.index(after: i)...]) {
            view.talk?.macHost = String(che[..<i]); view.talk?.macPort = cp; view.talk?.pinned = true
        }
        if let y = arg("-yata").flatMap(URL.init(string:)) { FaceView.yata = y }
        l.newConnectionHandler = { [weak self] c in
            guard case .hostPort(let host, _) = c.endpoint, "\(host)".hasPrefix("127.0.0.1") || "\(host)".hasPrefix("::1") else { return c.cancel() }
            c.start(queue: .main)
            self?.read(c)
        }
        l.start(queue: .main)
    }

    private func read(_ c: NWConnection, _ got: Data = Data()) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            let all = got + (data ?? Data())
            if let r = HTTPRequest(all) { return self?.handle(c, r) ?? () }
            if done || error != nil { return c.cancel() }
            self?.read(c, all)
        }
    }

    private func handle(_ c: NWConnection, _ r: HTTPRequest) {
        let o = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
        let at = CGPoint(x: o["x"] as? Double ?? Double(view.bounds.midX), y: o["y"] as? Double ?? Double(view.bounds.midY))
        let done = { [weak self] in guard let self else { return }; self.send(c, self.state()) }
        switch r.path {
        case "/tap": view.tap(at: at); after(0.05, done)
        case "/swipe":
            let left = o["way"] as? String == "left"
            if o["way"] as? String == "down" { view.swipeDown() }
            // With text up a swipe is a quick drag, as a finger makes it.
            else if view.carries { return drag(left ? -200 : 200, release: true, speed: nil, at: at, done) }
            else { view.swipe(left: left, at: at) }
            after(0.05, done)
        case "/drag": drag(o["dx"] as? Double ?? 0, release: o["release"] as? Bool ?? true, speed: o["speed"] as? Double, at: at, done)
        case "/hold":
            view.talk?.hold(at: at)
            after(o["for"] as? Double ?? 1) { [weak self] in self?.view.talk?.letGo(); after(0.05, done) }
        case "/twist": twist(o["steps"] as? Int ?? 1, release: o["release"] as? Bool ?? true, done)
        case "/scroll": view.page(by: o["by"] as? Int ?? 1); after(0.05, done)
        case "/record": record(o["secs"] as? Double ?? 5, fps: o["fps"] as? Double ?? 12) { [weak self] in self?.send(c, $0) }
        default: done()
        }
    }

    /// How far the finger dragging the text has carried it, while it's down.
    private var carried: Double?

    /// The finger carries the text on to `dx` points from where it landed, a little each frame, then lifts (unless
    /// `release` is false) at `speed`, or at the speed it moved.
    private func drag(_ dx: Double, release: Bool, speed: Double?, at p: CGPoint, _ done: @escaping () -> Void) {
        let from = carried ?? 0, frames = 8
        carried = dx
        for k in 1...frames {
            after(Double(k) * 0.02) { [weak self] in self?.view.slide(by: from + (dx - from) * Double(k) / Double(frames)) }
        }
        after(Double(frames) * 0.02 + 0.01) { [weak self] in
            guard let self else { return }
            if release { self.carried = nil; self.view.slid(by: dx, speed: speed ?? (dx - from) / (Double(frames) * 0.02), at: p) }
            after(0.05, done)
        }
    }

    /// Where the two fingers are turned to, while they're down (nil once lifted).
    private var angle: Double?

    /// Two fingers land 120 pt apart about the middle (unless they're down already) and turn `steps` sixteenths of a
    /// turn, a little at a time as a hand would, then lift (unless `release` is false).
    private func twist(_ steps: Int, release: Bool, _ done: @escaping () -> Void) {
        let mid = SIMD2(Double(view.bounds.midX), Double(view.bounds.midY)), r = 60.0
        func at(_ a: Double) -> [Int: SIMD2<Double>] { [1: mid + SIMD2(cos(a), sin(a)) * r, 2: mid - SIMD2(cos(a), sin(a)) * r] }
        let from = angle ?? 0, wait = angle == nil ? 0.15 : 0.0, frames = max(1, abs(steps)) * 8
        angle = from + Double(steps) * .pi / 8
        view.drive(fingers: at(from))
        for k in 0...frames {
            after(wait + Double(k) * 0.03) { [weak self] in self?.view.drive(fingers: at(from + Double(steps) * .pi / 8 * Double(k) / Double(frames))) }
        }
        after(wait + Double(frames) * 0.03 + 0.3) { [weak self] in
            if release { self?.angle = nil; self?.view.drive(fingers: [:]) }
            after(0.1, done)
        }
    }

    /// What the screen draws, `fps` times a second for `secs`, as vectors (bench/pad-svg makes the README's pictures
    /// of it): every shape layer's path, fill, stroke and width, and every text layer's words, font and frame.
    private func record(_ secs: Double, fps: Double, _ done: @escaping ([String: Any]) -> Void) {
        recorder = Recorder(secs: secs, fps: fps, take: { [weak self] in self?.snapshot() ?? [] }) { [weak self] frames in
            guard let self else { return }
            self.recorder = nil
            done(["w": Double(self.view.bounds.width), "h": Double(self.view.bounds.height), "fps": fps, "frames": frames])
        }
    }

    private var recorder: Recorder?

    private func snapshot() -> [[String: Any]] {
        var out: [[String: Any]] = []
        func white(_ c: CGColor?) -> Double? { c.flatMap { $0.alpha > 0 ? Double($0.components?.first ?? 1) : nil } }
        for l in view.layer.sublayers ?? [] where !l.isHidden && l.opacity > 0.01 {
            let m = l.transform, at = l.position, b = l.bounds
            // The same layer from frame to frame (an ant's, a line's), so the SVG can move one element along.
            var o: [String: Any] = ["o": Double(l.opacity), "id": ObjectIdentifier(l).hashValue]
            if let sl = l as? CAShapeLayer, let p = sl.path, !p.isEmpty {
                o["d"] = svg(p, offset: CGPoint(x: at.x - b.width * l.anchorPoint.x, y: at.y - b.height * l.anchorPoint.y))
                if let f = white(sl.fillColor) { o["fill"] = f }
                if let st = white(sl.strokeColor) { o["stroke"] = st; o["lw"] = Double(sl.lineWidth) }
            } else if let t = l as? CATextLayer, let words = t.string as? String, !words.isEmpty {
                let name = (t.font as? UIFont)?.fontName ?? ""
                o["text"] = words; o["size"] = Double(t.fontSize); o["x"] = Double(at.x); o["y"] = Double(at.y)
                o["w"] = Double(b.width); o["h"] = Double(b.height); o["sx"] = Double(m.m11); o["sy"] = Double(m.m22)
                o["left"] = t.alignmentMode == .left
                o["weight"] = name.contains("Bold") ? 700 : name.contains("Semibold") ? 600 : name.contains("Medium") ? 500 : 400
            } else { continue }
            out.append(o)
        }
        return out
    }

    private func svg(_ p: CGPath, offset d: CGPoint) -> String {
        var s = ""
        func n(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)).replacingOccurrences(of: ".0", with: "") }
        func pt(_ q: CGPoint) -> String { n(q.x + d.x) + " " + n(q.y + d.y) }
        p.applyWithBlock { e in
            let a = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint: s += "M" + pt(a[0])
            case .addLineToPoint: s += "L" + pt(a[0])
            case .addQuadCurveToPoint: s += "Q" + pt(a[0]) + " " + pt(a[1])
            case .addCurveToPoint: s += "C" + pt(a[0]) + " " + pt(a[1]) + " " + pt(a[2])
            case .closeSubpath: s += "Z"
            @unknown default: break
            }
        }
        return s
    }

    private func state() -> [String: Any] {
        let v = view, s = v.screen
        let ids = v.crowd.single ? ["face"] : v.crowd.sessions.map(\.id)
        var ants: [String: Any] = [:]
        for id in ids {
            guard let p = v.colony.position(of: id) else { continue }
            ants[id] = ["x": p.x, "y": p.y, "act": v.colony.acting(id) ?? ""]
        }
        return [
            "mode": "\(s.mode)", "note": s.note, "asking": s.asking != nil, "asker": s.asker ?? NSNull(),
            "front": v.crowd.front ?? NSNull(), "single": v.crowd.single,
            "placed": v.placed.map { ["text": $0.text, "style": "\($0.style)", "x": $0.x, "y": $0.y, "w": $0.width, "h": $0.height] },
            "shown": v.motion.frame(at: CACurrentMediaTime()).map { ["text": $0.line.text, "cx": $0.cx, "home": $0.line.x + $0.line.width / 2] },
            "dial": ["open": v.dial.isOpen, "current": v.dial.current?.title ?? "", "path": v.dial.path, "note": v.dial.note],
            "sessions": v.crowd.sessions.map { ["id": $0.id, "name": $0.name, "state": "\($0.state)"] },
            "ants": ants,
        ]
    }

    private func send(_ c: NWConnection, _ o: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// Takes a frame on the display's own tick, at most `fps` a second, so frames come when the screen draws.
private final class Recorder: NSObject {
    let secs: Double, gap: Double, take: () -> [[String: Any]], done: ([[String: Any]]) -> Void
    var frames: [[String: Any]] = [], start = 0.0, last = -1.0, link: CADisplayLink?

    init(secs: Double, fps: Double, take: @escaping () -> [[String: Any]], done: @escaping ([[String: Any]]) -> Void) {
        self.secs = secs; gap = 1 / fps; self.take = take; self.done = done
        super.init()
        start = CACurrentMediaTime()
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    @objc func tick() {
        let t = CACurrentMediaTime() - start
        if t >= secs { link?.invalidate(); link = nil; return done(frames) }
        if t - last >= gap * 0.95 { last = t; frames.append(["t": t, "layers": take()]) }
    }
}

private func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }

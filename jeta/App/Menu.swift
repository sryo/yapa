import AudioToolbox
import UIKit

/// What the dial turns through, built from what the pad knows now: the folders sessions ran in, for a new one, and
/// what yata says about the phone (every part, up or down and on or off, the tunnel, the disk). Its acts are run
/// here: a new session through che on the Mac, a part through yata's /parts, which only the phone itself may change.
extension FaceView {
    static let yata = URL(string: "http://127.0.0.1:8077/parts")!

    func dialRoot() -> [Dial.Item] {
        // A Mac folder under its user's home reads from ~, as the Mac's own shell would say it.
        let folders = (folders?() ?? []).map { f -> Dial.Item in
            let bits = f.split(separator: "/")
            let shown = f.hasPrefix("/Users/") && bits.count > 2 ? "~/" + bits.dropFirst(2).joined(separator: "/") : f
            return Dial.Item((f as NSString).lastPathComponent, shown, act: "new:" + f)
        }
        var parts: [Dial.Item] = [], tunnel: [Dial.Item] = []
        if let list = server?["parts"] as? [[String: Any]] {
            for p in list {
                let name = p["name"] as? String ?? "", kind = p["kind"] as? String ?? "", on = p["on"] as? Bool ?? false
                let up = p["up"] as? Bool ?? false, watched = p["watched"] as? Bool ?? false
                let state = !on ? "off" : !watched ? "on" : up ? "up" : "down"
                let address = (p["address"] as? String).map { " · \($0)" } ?? ""
                var acts: [Dial.Item] = []
                if kind != "core" { acts.append(Dial.Item(on ? "turn off" : "turn on", act: "part:\(name):\(on ? "off" : "on")")) }
                if name != "yata" && on { acts.append(Dial.Item("restart", act: "part:\(name):restart")) }
                let item = Dial.Item(name, state + address, children: acts.isEmpty ? nil : acts)
                if name == "cloudflared" { tunnel.append(Dial.Item("tunnel", up ? "connected" : "not connected", children: item.children)) }
                else { parts.append(item) }
            }
            let free = Double(server?["disk_free_mb"] as? Int ?? 0) / 1024, logs = server?["logs_mb"] as? Int ?? 0
            tunnel.append(Dial.Item("disk", String(format: "%.1f GB free", free)))
            tunnel.append(Dial.Item("logs", "\(logs) MB"))
        } else {
            let why = Dial.Item("no answer", "yata isn't answering on the phone")
            parts = [why]; tunnel = [why]
        }
        return [
            Dial.Item("new session", "in a folder you've used", children: folders.isEmpty
                      ? [Dial.Item("no folders yet", "they come from your sessions' hooks")] : folders),
            Dial.Item("server", parts.isEmpty ? "" : "\(parts.filter { $0.detail.hasPrefix("up") }.count) up", children: parts),
            Dial.Item("tunnel and disk", tunnel.first?.detail ?? "", children: tunnel),
        ]
    }

    func askServer() {
        serverAt = CACurrentMediaTime()
        URLSession.shared.dataTask(with: FaceView.yata) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { self.server = json }
        }.resume()
    }

    /// Two fingers let go: open what's under the word, go back, or do it.
    func letGo(at t: Double) {
        dial.root = dialRoot()
        switch dial.release(at: t) {
        case .opened, .back: AudioServicesPlaySystemSound(1104)
        case .nothing: break
        case .act(let a):
            AudioServicesPlaySystemSound(1105)
            if a.hasPrefix("new:") {
                dial.note = "starting…"
                talk?.newSession(in: String(a.dropFirst(4))) { [weak self] said in self?.dial.note = said }
            } else if a.hasPrefix("part:") {
                let bits = a.split(separator: ":").map(String.init)
                dial.note = bits[2] == "restart" ? "restarting…" : "turning \(bits[2])…"
                var r = URLRequest(url: FaceView.yata.appendingPathComponent(bits[1]).appendingPathComponent(bits[2]))
                r.httpMethod = "POST"
                URLSession.shared.dataTask(with: r) { data, response, _ in
                    let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    let ok = (response as? HTTPURLResponse)?.statusCode == 200
                    DispatchQueue.main.async {
                        if ok { self.server = json }
                        self.dial.note = ok ? (bits[2] == "restart" ? "restarted" : "\(bits[1]) is \(bits[2])")
                            : json?["error"] as? String ?? "yata didn't answer"
                    }
                }.resume()
            }
        }
    }

    /// How far two fingers have twisted past the dial's last whole step, in steps; 0 when none are turning it.
    var twist: Double {
        guard fingers.count == 2, let r = chord.reading else { return 0 }
        return (r.angle - r.start) / Chord.stepAngle - Double(r.steps)
    }

    /// Two faint marks just outside the fingers, on the circle through them, each a dot and a short arc, turning
    /// as they twist: what's under the fingers is a dial. They fade in when the chord locks and out when it lets go.
    func drawGrip() {
        if grip.superlayer == nil {
            grip.strokeColor = UIColor(white: 0.96, alpha: 0.45).cgColor
            grip.fillColor = UIColor(white: 0.96, alpha: 0.6).cgColor
            grip.lineWidth = 2
            grip.lineCap = .round
            grip.zPosition = 50
            layer.addSublayer(grip)
        }
        let now = CACurrentMediaTime(), dt = min(0.05, now - gripAt)
        gripAt = now
        let turning = dial.isOpen && fingers.count == 2 && chord.reading != nil
        if turning { gripLast = chord.reading }
        gripShown.step(to: turning ? 1 : 0, k: 300, damping: 1, dt: dt)
        grip.opacity = Float(max(0, min(1, gripShown.x)))
        guard grip.opacity > 0.01, let r = gripLast else { return }
        let path = CGMutablePath(), ring = r.radius + 30, c = CGPoint(x: r.centre.x, y: r.centre.y)
        for side in [0.0, Double.pi] {
            let a = r.angle + side
            path.move(to: CGPoint(x: c.x + cos(a - 0.45) * ring, y: c.y + sin(a - 0.45) * ring))
            path.addArc(center: c, radius: ring, startAngle: a - 0.45, endAngle: a + 0.45, clockwise: false)
            let dot = CGPoint(x: c.x + cos(a) * ring, y: c.y + sin(a) * ring)
            path.move(to: CGPoint(x: dot.x + 3.5, y: dot.y))
            path.addEllipse(in: CGRect(x: dot.x - 3.5, y: dot.y - 3.5, width: 7, height: 7))
        }
        grip.path = path
    }
}


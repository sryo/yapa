import Network
import UIKit

/// Takes Claude Code's hooks from the Mac on port 8079, from the home network only (`jeta/hooks on` points them
/// here), and keeps every session's state in a Desk. A permission hook waits on its connection until a tap answers it.
final class HookListener {
    let desk = Desk()
    /// After every event, and every 10 s so the Buddy core keeps counting the link as alive.
    var onChange: (() -> Void)?
    private var waiting: [String: NWConnection] = [:]
    private let listener = try? NWListener(using: .tcp, on: 8079)
    private var timer: Timer?

    init() {
        listener?.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener?.start(queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.settle(self.desk.expire(at: CACurrentMediaTime()))
            self.onChange?()
        }
    }

    /// Answers the waiting hook with the core's `{"cmd":"permission"}` line; false if it isn't one the hooks hold.
    func decide(_ line: String) -> Bool {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              o["cmd"] as? String == "permission", let s = desk.decide(o) else { return false }
        settle([s])
        onChange?()
        return true
    }

    private func accept(_ c: NWConnection) {
        guard case .hostPort(let host, _) = c.endpoint, homeNetwork("\(host)".components(separatedBy: "%")[0]) else { return c.cancel() }
        c.start(queue: .main)
        read(c)
    }

    private func read(_ c: NWConnection, _ got: Data = Data()) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            let all = got + (data ?? Data())
            if let r = HTTPRequest(all) { return self?.handle(c, r) ?? () }
            if done || error != nil || all.count > 1 << 20 { return c.cancel() }
            self?.read(c, all)
        }
    }

    private func handle(_ c: NWConnection, _ r: HTTPRequest) {
        guard r.method == "POST", r.path == "/hook", let e = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] else {
            return send(c, Data(#"{"error":"POST /hook takes a Claude Code hook event"}"#.utf8), status: "404 Not Found")
        }
        let got = desk.take(e, at: CACurrentMediaTime())
        settle(got.settled)
        if let id = got.hold { waiting[id] = c } else { send(c, Data()) }
        onChange?()
    }

    /// Lets go of held hooks: with a decision, or with nothing so the terminal's own dialog decides.
    private func settle(_ done: [Settle]) {
        for s in done { if let c = waiting.removeValue(forKey: s.id) { send(c, s.body) } }
    }

    private func send(_ c: NWConnection, _ body: Data, status: String = "200 OK") {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
}

import AppKit
import Network
import TalkKit

// che: the pad posts a clip to /talk on release; this hears it and types the text into Claude.
// /say takes the text itself (an option picked on the pad). ?dry on either types nothing (for the benches).
// /cancel stops the Enter that follows the text.
// Only this Mac and the hosts in CHE_FROM (the pad's address, comma-separated) may post.
let env = ProcessInfo.processInfo.environment
let port = NWEndpoint.Port(env["CHE_PORT"] ?? "8078")!
let enterDelay = Double(env["CHE_ENTER"] ?? "2") ?? 2
let from = (env["CHE_FROM"] ?? "").split(separator: ",").map(String.init)
let transcriber = Transcriber((env["CHE_LANGS"] ?? "en_US,es_ES").split(separator: ",").map(String.init))

func log(_ s: String) { FileHandle.standardError.write(Data("che: \(s)\n".utf8)) }

var target: Route = .clipboard
let enter = PendingEnter(after: enterDelay) { key(36, to: target) }

func post(_ e: CGEvent?, to r: Route) {
    if case .sendTo(let pid) = r { e?.postToPid(pid) } else { e?.post(tap: .cghidEventTap) }
}

func key(_ code: CGKeyCode, to r: Route) {
    for down in [true, false] { post(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down), to: r) }
}

func type(_ text: String, to r: Route) {
    // A keyboard event carries at most 20 UTF-16 units of text.
    let units = Array(text.utf16)
    for i in stride(from: 0, to: units.count, by: 20) {
        let chunk = Array(units[i..<min(i + 20, units.count)])
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            post(e, to: r)
        }
    }
}

/// Puts the text where route() says; Enter follows after enterDelay unless the pad cancels it.
func deliver(_ text: String) -> Route {
    var r = route(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                  claude: NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundle).first?.processIdentifier)
    if r != .clipboard && !AXIsProcessTrusted() {
        log("can't type: allow \(CommandLine.arguments[0]) in System Settings > Privacy & Security > Accessibility; text is on the clipboard")
        r = .clipboard
    }
    if r == .clipboard {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return r
    }
    type(text, to: r)
    target = r
    if enterDelay > 0 { enter.arm() }
    return r
}

func reply(_ c: NWConnection, _ status: String, _ json: [String: Any]) {
    let body = try! JSONSerialization.data(withJSONObject: json)
    let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
}

/// Delivers the text unless dry, and answers what /talk and /say both answer.
func answer(_ c: NWConnection, _ text: String, lang: String, ms: Double, dry: Bool) {
    let to = dry ? "none" : "\(deliver(text))"
    log("\(Int(ms)) ms \(lang) -> \(to): \(text)")
    reply(c, "200 OK", ["text": text, "lang": lang, "ms": ms, "enter_in": dry || to == "clipboard" ? 0 : enterDelay])
}

func handle(_ c: NWConnection, _ r: Request) {
    switch (r.method, r.path) {
    case ("POST", "/cancel"):
        reply(c, "200 OK", ["cancelled": enter.cancel()])
    case ("POST", let p) where p.hasPrefix("/say"):
        guard let text = said(r.body) else { return reply(c, "400 Bad Request", ["error": "POST /say with UTF-8 text"]) }
        answer(c, text, lang: "text", ms: 0, dry: p.hasSuffix("?dry"))
    case ("POST", let p) where p.hasPrefix("/talk"):
        let start = DispatchTime.now()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("che-\(UUID()).wav")
        Task { @MainActor in
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                try r.body.write(to: url)
                let heard = pick(try await transcriber.hear(url))
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
                guard let h = heard else { return reply(c, "200 OK", ["text": "", "ms": ms]) }
                answer(c, h.text, lang: h.lang, ms: ms, dry: p.hasSuffix("?dry"))
            } catch {
                log("\(error)")
                reply(c, "500 Internal Server Error", ["error": "\(error)"])
            }
        }
    default:
        reply(c, "404 Not Found", ["error": "POST /talk with a WAV body, /say with UTF-8 text, or /cancel"])
    }
}

func receive(_ c: NWConnection, _ got: Data = Data()) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
        let all = got + (data ?? Data())
        if let r = Request(all) { return handle(c, r) }
        if done || error != nil { return c.cancel() }
        receive(c, all)
    }
}

_ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
Task {
    do { try await transcriber.prepare() } catch { log("\(error)"); exit(1) }
    let params = NWParameters.tcp
    (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
    let listener = try! NWListener(using: params, on: port)
    listener.service = NWListener.Service(name: Host.current().localizedName ?? "yapa", type: "_che._tcp")
    listener.newConnectionHandler = { c in
        guard case .hostPort(let host, _) = c.endpoint, allowed("\(host)".components(separatedBy: "%")[0], from: from) else {
            log("refused \(c.endpoint): add its address to CHE_FROM to let it talk")
            return c.cancel()
        }
        c.start(queue: .main)
        receive(c)
    }
    listener.start(queue: .main)
    log("listening on \(port) for \(["this Mac"] + from), Enter after \(enterDelay) s")
}
dispatchMain()

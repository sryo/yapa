import AppKit
import Network
import TalkKit

// che: the pad posts a clip to /talk on release; this hears it and types the text into Claude.
// /say takes the text itself (an option picked on the pad). ?dry on either types nothing (for the benches).
// ?session=<id> names the Claude Code session a face on the pad stands for: when it's one of the Claude app's, the
// app is brought forward on that session first, so the words land there and not in whatever was in front.
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

let sessions = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")

let appLog = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Claude/main.log")

/// The end of the Claude app's log, where it says which session it focused.
/// The session the Claude app has focused, from its log. It says so only when the focus changes, so the line can be
/// far back: che reads the whole log once, then only what's new.
var logRead: UInt64 = 0, appFocused: String?
func focusedNow() -> String? {
    guard let h = try? FileHandle(forReadingFrom: appLog) else { return appFocused }
    defer { try? h.close() }
    let end = (try? h.seekToEnd()) ?? 0
    // A log cut or started again is read from the top.
    if end < logRead { logRead = 0 }
    try? h.seek(toOffset: logRead)
    let new = h.readDataToEndOfFile()
    logRead += UInt64(new.count)
    if let f = focusedSession(log: String(decoding: new, as: UTF8.self)) { appFocused = f }
    return appFocused
}

/// Opens the Claude app on a session: nil when the app doesn't have it (it runs in a terminal), false when the app
/// never said it focused it within 3 s, true once it's in front on that session.
func open(session cli: String) async -> Bool? {
    guard let id = desktopSession(cli: cli, in: sessions),
          let url = URL(string: "claude://code/continue?session=\(id)&source=desktop_action") else {
        log("session \(cli) isn't one of the Claude app's")
        return nil
    }
    NSWorkspace.shared.open(url)
    NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundle).first?.activate()
    for _ in 0..<60 {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundle, focusedNow() == id {
            // The box takes the focus a moment after the session shows.
            try? await Task.sleep(nanoseconds: 300_000_000)
            return true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    log("the Claude app didn't focus \(id) within 3 s")
    return false
}

/// Puts the text where route() says, or on the clipboard when it mustn't go anywhere but a session that didn't open;
/// Enter follows after enterDelay unless the pad cancels it.
func deliver(_ text: String, clipboard: Bool = false) -> Route {
    var r = clipboard ? .clipboard : route(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
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

/// Delivers the text unless dry, in the session the pad named if the Claude app has it, and answers what /talk and
/// /say both answer.
@MainActor func answer(_ c: NWConnection, _ text: String, lang: String, ms: Double, path: String) async {
    let q = query(path), dry = q["dry"] != nil
    // Words for a session go there or nowhere: one the app doesn't have (a terminal's) or didn't open leaves them on
    // the clipboard, since anywhere else would be the wrong place.
    var opened: Bool?
    if !dry, let s = q["session"] { opened = await open(session: s) == true }
    let to = dry ? "none" : "\(deliver(text, clipboard: opened == false))" + (opened == true ? " in \(q["session"]!)" : "")
    log("\(Int(ms)) ms \(lang) -> \(to): \(text)")
    reply(c, "200 OK", ["text": text, "lang": lang, "ms": ms, "enter_in": dry || to == "clipboard" ? 0 : enterDelay])
}

func handle(_ c: NWConnection, _ r: Request) {
    switch (r.method, r.path) {
    // The pad's names for the sessions its hooks report: GET /sessions?ids=a,b.
    case ("GET", let p) where p.hasPrefix("/sessions"):
        let ids = Set((query(p)["ids"] ?? "").split(separator: ",").map(String.init))
        let list = named(ids, in: sessions).mapValues { n -> [String: Any] in
            var o: [String: Any] = ["name": n.name, "title": n.title]
            if let p = n.parent { o["parent"] = p }
            if let f = n.focused { o["focused"] = f }
            return o
        }
        reply(c, "200 OK", ["sessions": list])
    case ("POST", "/cancel"):
        reply(c, "200 OK", ["cancelled": enter.cancel()])
    // The pad's dial starts a session in a folder: the Claude app opens it behind whatever is in front.
    case ("POST", let p) where p.hasPrefix("/new"):
        guard let folder = said(r.body), let url = newSession(in: folder) else {
            return reply(c, "400 Bad Request", ["error": "POST /new with the path of a folder on this Mac"])
        }
        if query(p)["dry"] == nil {
            let open = NSWorkspace.OpenConfiguration()
            open.activates = false
            NSWorkspace.shared.open(url, configuration: open)
        }
        log("new session in \(folder)")
        reply(c, "200 OK", ["folder": folder, "url": url.absoluteString])
    case ("POST", let p) where p.hasPrefix("/say"):
        guard let text = said(r.body) else { return reply(c, "400 Bad Request", ["error": "POST /say with UTF-8 text"]) }
        Task { @MainActor in await answer(c, text, lang: "text", ms: 0, path: p) }
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
                await answer(c, h.text, lang: h.lang, ms: ms, path: p)
            } catch {
                log("\(error)")
                reply(c, "500 Internal Server Error", ["error": "\(error)"])
            }
        }
    default:
        reply(c, "404 Not Found", ["error": "POST /talk with a WAV body, /say with UTF-8 text, /new or /cancel, or GET /sessions?ids="])
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
// The main run loop, not dispatchMain: NSWorkspace learns which app is in front from run loop notifications, so
// without one frontmostApplication stays whatever was in front when che started.
_ = focusedNow()
RunLoop.main.run()

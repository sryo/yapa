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
let focusWait = Double(env["CHE_WAIT"] ?? "3") ?? 3
let from = (env["CHE_FROM"] ?? "").split(separator: ",").map(String.init)
let transcriber = Transcriber((env["CHE_LANGS"] ?? "en_US,es_ES").split(separator: ",").map(String.init))

func log(_ s: String) { FileHandle.standardError.write(Data("che: \(s)\n".utf8)) }

var target: Route = .clipboard
/// Run once the pending Enter is pressed (not when it's cancelled): checks the text reached its session.
var afterEnter: (() -> Void)?
let enter = PendingEnter(after: enterDelay) { key(36, to: target); afterEnter?(); afterEnter = nil }

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

let appLog = env["CHE_APPLOG"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Claude/main.log")

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

/// The app that was in front before the Claude app's session link raised it (the link raises it even when opened in
/// the background), to get the front back once the text is sent: the app takes keys only while it's in front.
var handBack: NSRunningApplication?

func giveBack() {
    if let a = handBack, a.bundleIdentifier != claudeBundle { a.activate() }
    handBack = nil
}

/// Turns the Claude app to a session: nil when the app doesn't have it (it runs in a terminal), false when the app never said it focused
/// it within focusWait s, true once it shows that session.
func open(session cli: String) async -> Bool? {
    guard let id = desktopSession(cli: cli, in: sessions),
          let url = URL(string: "claude://code/continue?session=\(id)&source=desktop_action") else {
        log("session \(cli) isn't one of the Claude app's")
        return nil
    }
    handBack = NSWorkspace.shared.frontmostApplication
    let behind = NSWorkspace.OpenConfiguration()
    behind.activates = false
    _ = try? await NSWorkspace.shared.open(url, configuration: behind)
    for _ in 0..<Int(focusWait * 20) {
        if focusedNow() == id {
            // The box takes the focus a moment after the session shows.
            try? await Task.sleep(nanoseconds: 300_000_000)
            return true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    giveBack()
    log("the Claude app didn't focus \(id) within \(focusWait) s: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nothing") in front, its log last focused \(focusedNow() ?? "nothing")")
    return false
}

/// What became of each delivery into a Claude app session, by the id /say and /talk answered with: true once the app
/// says it sent the text, false when it didn't within 4 s of the Enter (the text is then on the clipboard).
var sent: [Int: Bool] = [:], deliveries = 0

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Waits for the Claude app's log to say it sent a message to session `local`, from what the log holds now on.
/// Keystrokes can land before a session's box takes them, and then nothing is sent though che typed it all.
func confirm(_ id: Int, session local: String, text: String) {
    let from = (try? FileManager.default.attributesOfItem(atPath: appLog.path)[.size] as? UInt64) ?? 0
    Task { @MainActor in
        for _ in 0..<80 {
            if let h = try? FileHandle(forReadingFrom: appLog) {
                try? h.seek(toOffset: from)
                let new = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
                try? h.close()
                if wasSent(log: new, session: local) { sent[id] = true; giveBack(); return }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        log("the Claude app didn't send the text to \(local) within 4 s; it's on the clipboard")
        copy(text)
        sent[id] = false
        giveBack()
    }
}

/// Puts the text where route() says (into the Claude app's process when it's for a session the app opened), or on
/// the clipboard when it mustn't go anywhere but a session that didn't open; Enter follows after enterDelay unless
/// the pad cancels it.
func deliver(_ text: String, clipboard: Bool = false, app: Bool = false) -> Route {
    let claude = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundle).first?.processIdentifier
    var r = clipboard ? .clipboard : app ? claude.map { .sendTo($0) } ?? .clipboard
        : route(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, claude: claude)
    if r != .clipboard && !AXIsProcessTrusted() {
        log("can't type: allow \(CommandLine.arguments[0]) in System Settings > Privacy & Security > Accessibility; text is on the clipboard")
        r = .clipboard
    }
    if r == .clipboard {
        copy(text)
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
    let to = dry ? "none" : "\(deliver(text, clipboard: opened == false, app: opened == true))" + (opened == true ? " in \(q["session"]!)" : "")
    log("\(Int(ms)) ms \(lang) -> \(to): \(text)")
    var out: [String: Any] = ["text": text, "lang": lang, "ms": ms, "enter_in": dry || to == "clipboard" ? 0 : enterDelay]
    // Typed into one of the app's sessions with an Enter to follow: the pad asks /sent?id= once it's pressed.
    if opened == true, to != "clipboard", enterDelay > 0, let s = q["session"], let local = desktopSession(cli: s, in: sessions) {
        deliveries += 1
        let id = deliveries
        afterEnter = { confirm(id, session: local, text: text) }
        out["id"] = id
    } else { giveBack() }
    reply(c, "200 OK", out)
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
        afterEnter = nil
        giveBack()
        reply(c, "200 OK", ["cancelled": enter.cancel()])
    // Whether delivery `id` reached its session: answered once known, or null after 6 s.
    case ("GET", let p) where p.hasPrefix("/sent"):
        let id = Int(query(p)["id"] ?? "") ?? 0
        Task { @MainActor in
            for _ in 0..<120 where sent[id] == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
            reply(c, "200 OK", ["sent": sent[id].map { $0 as Any } ?? NSNull()])
        }
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
        reply(c, "404 Not Found", ["error": "POST /talk with a WAV body, /say with UTF-8 text, /new or /cancel, or GET /sessions?ids= or /sent?id="])
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

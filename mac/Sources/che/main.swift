import AppKit
import Network
import TalkKit

// che: the pad posts a clip to /talk on release; this hears it and types the text into Claude.
// /say takes the text itself (an option picked on the pad). ?dry on either types nothing (for the benches).
// ?session=<id> names the Claude Code session a face on the pad stands for: when it's one of the Claude app's, the
// app is brought forward on that session first, so the words land there and not in whatever was in front; when it
// runs in a Terminal tab, that tab is.
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
/// Asked just before the pending Enter: false when what was typed is no longer in front to take it, and then the
/// Enter isn't pressed.
var stillThere: () async -> Bool = { true }
/// Run once the pending Enter is due (not when it's cancelled), told whether it was pressed: checks the text reached
/// its session.
var afterEnter: ((Bool) -> Void)?
/// The box's one delivery at a time, and the turn of the one now in it: text that comes while another is on its way
/// in goes to the clipboard, never into the box with it.
let box = OneAtATime()
var inBox: Int?
/// Ends the turn of the delivery in the box, once its Enter is in and it's done with the front, or it was given up.
func done() {
    giveBack()
    if let t = inBox { box.release(t) }
    inBox = nil
}
let enter = PendingEnter(after: enterDelay) {
    let check = stillThere, after = afterEnter, turn = inBox
    stillThere = { true }
    afterEnter = nil
    Task { @MainActor in
        let there = await check()
        if there { key(36, to: target) }
        // A delivery che follows ends its turn once it's seen arriving or given up; one it doesn't, now.
        if let after { after(there) } else if let turn, inBox == turn { done() }
    }
}

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

/// What became of each delivery into a session, by the id /say and /talk answered with.
var sent: [Int: Delivery] = [:], deliveries = 0

let claudeHome = env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
let terminalBundle = "com.apple.Terminal"

/// Runs AppleScript against Terminal in osascript, given 3 s; nil when it fails. In che's own process the script's
/// reply never came back, and nothing che waits on may hold up the pad's other requests.
func terminal(_ script: String) async -> String? {
    let p = Process(), out = Pipe(), err = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "tell application id \"\(terminalBundle)\"\n\(script)\nend tell"]
    p.standardOutput = out
    p.standardError = err
    let done = AsyncStream<Void> { c in p.terminationHandler = { _ in c.yield(); c.finish() } }
    guard (try? p.run()) != nil else { return nil }
    let timer = DispatchWorkItem { p.terminate() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timer)
    for await _ in done {}
    timer.cancel()
    guard p.terminationStatus == 0 else {
        log("Terminal: \(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        return nil
    }
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .newlines)
}

/// Whether che may control Terminal, asked without waiting on the user: the first time, macOS asks them (off the
/// main thread, so che keeps answering) and this delivery goes to the clipboard.
func mayControlTerminal() -> Bool {
    let target = NSAppleEventDescriptor(bundleIdentifier: terminalBundle)
    let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
    if status == noErr { return true }
    if status == OSStatus(errAEEventWouldRequireUserConsent) {
        log("asking to control Terminal: allow it, then picks reach Terminal sessions")
        DispatchQueue.global().async { _ = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true) }
    } else {
        log("can't control Terminal (\(status)): allow che in System Settings > Privacy & Security > Automation")
    }
    return false
}

/// Whether Terminal is in front showing the tab on `tty`, so keys sent to it land in that tab and nowhere else.
func showing(_ tty: String) async -> Bool {
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == terminalBundle else { return false }
    // A closed session's tab keeps its tty, which a new one can be given: only a tab running something counts.
    return await terminal("if (count windows) > 0 then return {tty, busy} of selected tab of front window") == "\(tty), true"
}

/// Brings Terminal forward on the tab where session `cli` runs: its tty once that tab is in front; nil when no
/// Terminal tab runs it (it isn't running, runs in another terminal, or with no terminal at all) or the tab didn't
/// come forward within focusWait s.
func open(terminal cli: String) async -> String? {
    guard let s = liveSession(cli: cli, in: claudeHome.appendingPathComponent("sessions"), started: processStart),
          let tty = controllingTTY(s.pid) else {
        log("session \(cli) isn't running in a terminal on this Mac")
        return nil
    }
    guard s.takesText else {
        log("session \(cli) is \(s.status ?? "in an unknown state"), not at its prompt: typing there would answer or run something else")
        return nil
    }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: terminalBundle).first else {
        log("session \(cli) runs on \(tty), and Terminal isn't running")
        return nil
    }
    guard mayControlTerminal() else { return nil }
    guard await terminal("""
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" and busy of t then
                        set selected of t to true
                        set index of w to 1
                        return "found"
                    end if
                end repeat
            end repeat
            """) == "found" else {
        log("session \(cli) runs on \(tty), which is no Terminal tab")
        return nil
    }
    handBack = NSWorkspace.shared.frontmostApplication
    app.activate()
    for _ in 0..<Int(focusWait * 10) {
        if await showing(tty) {
            // Keys sent the moment Terminal says it's in front are lost: its window takes them a moment later.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if await showing(tty) { return tty }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    giveBack()
    log("Terminal didn't show \(tty) within \(focusWait) s")
    return nil
}

/// Watches session `cli`'s transcript, from `offset` on, for the text as a prompt of the user's (taken, or queued
/// while the session is busy). The front goes back after 4 s either way; past that the delivery stays pending, since
/// the text is in its session's box, for up to 2 minutes.
func confirm(_ id: Int, transcript cli: String, from offset: UInt64, text: String) {
    Task { @MainActor in
        var file = transcript(cli: cli, in: claudeHome.appendingPathComponent("projects"))
        // Only what's new is read each time; a line still being written waits in `part` for the rest.
        var at = offset, part = Data()
        for i in 0..<(80 + 232) {
            file = file ?? transcript(cli: cli, in: claudeHome.appendingPathComponent("projects"))
            if let f = file, let h = try? FileHandle(forReadingFrom: f) {
                try? h.seek(toOffset: at)
                let new = h.readDataToEndOfFile()
                try? h.close()
                at += UInt64(new.count)
                part += new
                let nl = part.lastIndex(of: 10)
                let lines = nl.map { String(decoding: part[...$0], as: UTF8.self) } ?? ""
                if let nl { part = Data(part[(nl + 1)...]) }
                if prompted(transcript: lines, text: text) {
                    sent[id] = .sent
                    if i < 80 { done() }
                    return
                }
            }
            if i == 80 { done(); log("session \(cli) hasn't taken the text yet; still watching") }
            try? await Task.sleep(nanoseconds: i < 80 ? 50_000_000 : 500_000_000)
        }
        log("session \(cli) never showed the text in its transcript")
    }
}

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
                if wasSent(log: new, session: local) { sent[id] = .sent; done(); return }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        log("the Claude app didn't send the text to \(local) within 4 s; it's on the clipboard")
        copy(text)
        sent[id] = .copied
        done()
    }
}

/// Puts the text where route() says (into the Claude app's process when it's for a session the app opened, into the
/// front when that's a session's Terminal tab), or on the clipboard when it mustn't go anywhere but a session that
/// didn't open; Enter follows after enterDelay unless the pad cancels it.
func deliver(_ text: String, clipboard: Bool = false, app: Bool = false, front: Bool = false) -> Route {
    let claude = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundle).first?.processIdentifier
    let terminalPid = NSRunningApplication.runningApplications(withBundleIdentifier: terminalBundle).first?.processIdentifier
    var r = clipboard ? .clipboard : front ? terminalPid.map { .sendTo($0) } ?? .clipboard : app ? claude.map { .sendTo($0) } ?? .clipboard
        : route(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, claude: claude)
    // Keys posted to Terminal go to its key window, so it must still be in front, as it was showing the tab a moment ago.
    if front && NSWorkspace.shared.frontmostApplication?.bundleIdentifier != terminalBundle {
        log("Terminal lost the front before the text was typed; it's on the clipboard")
        r = .clipboard
    }
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

/// What each pick the pad named with a key was answered.
var answered: [String: [String: Any]] = [:]

/// Delivers the text unless dry, in the session the pad named if the Claude app has it, and answers what /talk and
/// /say both answer.
@MainActor func answer(_ c: NWConnection, _ text: String, lang: String, ms: Double, path: String) async {
    let q = query(path), dry = q["dry"] != nil
    var out: [String: Any] = ["text": text, "lang": lang, "ms": ms, "enter_in": 0]
    // The pad sends a pick again, under the same key, when no answer reached it: it was taken the first time, so it's
    // answered with what became of it then (its id for /sent, or whether it was typed) and nothing is typed twice.
    if let k = q["key"] {
        if var first = answered[k] {
            first["typed"] = (first["enter_in"] as? Double ?? 0) > 0
            first["again"] = true
            first["enter_in"] = 0
            return reply(c, "200 OK", first)
        }
        answered[k] = out
    }
    let reply = { (c: NWConnection, status: String, o: [String: Any]) in
        if let k = q["key"] { answered[k] = o }
        reply(c, status, o)
    }
    if !dry {
        guard let turn = box.take() else {
            // Another delivery is on its way into its session, its Enter not in yet: typing now would add these words
            // to that prompt, and taking the front would cost it its Enter. The front stays as it is.
            log("\(Int(ms)) ms \(lang) -> clipboard, another delivery not yet entered: \(text)")
            copy(text)
            if q["session"] != nil {
                deliveries += 1
                sent[deliveries] = .copied
                out["id"] = deliveries
            }
            return reply(c, "200 OK", out)
        }
        inBox = turn
    }
    // Words for a session go there or nowhere: one in neither the app nor a Terminal tab, or that didn't come
    // forward, leaves them on the clipboard, since anywhere else would be the wrong place.
    var opened: Bool?, tab: String?
    if !dry, let s = q["session"] {
        switch await open(session: s) {
        case true?: opened = true
        case false?: opened = false
        case nil: tab = await open(terminal: s); opened = tab != nil
        }
    }
    let offset = q["session"].flatMap { transcript(cli: $0, in: claudeHome.appendingPathComponent("projects")) }
        .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? UInt64 } ?? 0
    let r = dry ? nil : deliver(text, clipboard: opened == false, app: opened == true && tab == nil, front: tab != nil)
    let to = r.map { "\($0)" + (opened == true ? " in \(q["session"]!)" : "") } ?? "none"
    log("\(Int(ms)) ms \(lang) -> \(to): \(text)")
    out["enter_in"] = r == nil || r == .clipboard ? 0 : enterDelay
    // Typed into a session with an Enter to follow: the pad asks /sent?id= once it's pressed.
    if opened == true, r != .clipboard, enterDelay > 0, let s = q["session"] {
        deliveries += 1
        let id = deliveries
        sent[id] = .pending
        if let tab {
            // The tab must still be in front for the Enter: one pressed elsewhere would send something else.
            stillThere = { await showing(tab) }
            afterEnter = { pressed in
                guard pressed else {
                    log("Terminal no longer showed \(tab) for the Enter; the text is on the clipboard")
                    copy(text)
                    sent[id] = .copied
                    return done()
                }
                confirm(id, transcript: s, from: offset, text: text)
            }
            out["id"] = id
        } else if let local = desktopSession(cli: s, in: sessions) {
            afterEnter = { _ in confirm(id, session: local, text: text) }
            out["id"] = id
        } else { sent[id] = nil; giveBack() }
    } else if dry {
        // Typed nothing and took nothing, so the front and the box are left to whatever else is on its way in.
    } else if r == .clipboard || enterDelay == 0 { done() } else { giveBack() }
    reply(c, "200 OK", out)
}

func handle(_ c: NWConnection, _ r: Request) {
    // A web page open on this Mac reaches 127.0.0.1 like the pad does; che types for neither it nor its scripts.
    guard !r.browser else {
        log("refused a request from a web page: \(r.method) \(r.path.prefix(40))")
        return reply(c, "403 Forbidden", ["error": "che doesn't answer web pages"])
    }
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
        stillThere = { true }
        let cancelled = enter.cancel()
        // Text still on its way in keeps its turn; once its Enter won't come, the box is free.
        if cancelled { done() } else { giveBack() }
        reply(c, "200 OK", ["cancelled": cancelled])
    // Whether delivery `id` reached its session: answered once sent or copied, or as it stands after 6 s.
    case ("GET", let p) where p.hasPrefix("/sent"):
        let id = Int(query(p)["id"] ?? "") ?? 0
        Task { @MainActor in
            for _ in 0..<120 where sent[id] == nil || sent[id] == .pending { try? await Task.sleep(nanoseconds: 50_000_000) }
            reply(c, "200 OK", sentReply(sent[id]))
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

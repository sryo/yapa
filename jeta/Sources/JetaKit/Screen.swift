import Foundation

/// A held permission request as the pad shows it: what the tool would do, in full, or the questions it asks
/// (AskUserQuestion), each with its options and whether more than one may be picked.
public struct Asked: Equatable {
    public struct Question: Equatable {
        public var question, header: String, options: [String], multi: Bool
        public init(question: String, header: String, options: [String], multi: Bool) {
            self.question = question; self.header = header; self.options = options; self.multi = multi
        }
    }
    public var id, session, tool, text: String, questions: [Question]
    /// Whether it can be allowed for the rest of the session (the request came with rules to add).
    public var forSession: Bool
    public init(id: String, session: String, tool: String, text: String, questions: [Question] = [], forSession: Bool = false) {
        self.id = id; self.session = session; self.tool = tool; self.text = text; self.questions = questions
        self.forSession = forSession
    }
}

/// What a tap on a request's option does.
public enum Pick: Equatable {
    /// A permission decided: allow or deny.
    case decide(Bool)
    /// Allowed for the rest of the session, as its own suggestions say; or denied and the session stopped.
    case allowSession, stop
    /// Every question answered: each question's text to the labels picked, joined by ", ".
    case answer([String: String])
    /// A box ticked, or on to the next question.
    case more
}

/// What a session last said: the text its turn stopped on.
public struct Reply: Equatable {
    public var id, session, text: String, at: Double
    public init(id: String, session: String, text: String, at: Double) { self.id = id; self.session = session; self.text = text; self.at = at }
}

/// What jeta shows besides the face, and what each gesture does. The bare face is the default; a session's question
/// takes over (who and what); a tap opens the detail and another closes it; a swipe moves between waiting sessions; a
/// swipe down on the bare face opens the session list. A session's reply (what it stopped on) opens to read when it
/// arrives or when its face is tapped; swipes up and down scroll it, sideways moves to another session's, a tap
/// closes it. Holding is always for talking (che), so it isn't here.
public struct Screen {
    public enum Mode: Equatable { case face, question, detail, roster, reply }
    public enum Style: Equatable { case title, body, hint, option, suggestion }
    public struct Line: Equatable {
        public var text: String, style: Style
        /// A reply's line: which line of the whole reply it is, and how many lines it sits below the first one
        /// showing (negative above it, past the page's last below it), so the pages around stay where a drag
        /// brings them.
        public var row: (index: Int, offset: Int)? = nil
        public static func == (a: Line, b: Line) -> Bool {
            a.text == b.text && a.style == b.style && a.row?.index == b.row?.index && a.row?.offset == b.row?.offset
        }
    }

    public private(set) var mode = Mode.face
    /// What talking is doing (listening, sending, what che typed); it takes the hint's place while it's up.
    public var note = ""
    /// The clock replies are stamped with, so an open one can say how long ago it came in.
    public var now = 0.0
    /// The sessions the hooks report, for the session list: what each is doing and for how long.
    public var sessions: [SessionInfo] = []
    private var board = NoticeBoard(), page = 0
    private var replies: [Reply] = [], reading: String?, scroll = 0, newest = -Double.infinity
    /// How many lines of a reply show at once.
    static let readLines = 7
    /// How long text stays up with nobody touching the pad before it goes back into its ant, and the pad rests.
    static let unattended = 180.0
    private var touched = 0.0, shownAt = 0.0, seen = "", folded = false

    public init() {}

    /// A permission request waiting on the pad, shown before any question with Allow and Deny to tap.
    public private(set) var asking: Notice?

    var current: Notice? { asking ?? (board.pending.isEmpty ? nil : board.pending[page % board.pending.count]) }

    public mutating func update(_ b: NoticeBoard) {
        if b.pending.contains(where: { !board.pending.contains($0) }) { folded = false }
        board = b
        if page >= board.pending.count { page = 0 }
        settle()
    }

    /// A session asks to use a tool (`what` is the tool and the part of its call worth a glance); nil once answered.
    public mutating func ask(session: String, _ what: String) {
        let n = Notice(session: session, text: what, options: ["Allow", "Deny"])
        guard asking != n else { return }
        asking = n
        folded = false
        if mode == .face || mode == .roster { mode = .question }
    }

    private var asked: Asked?, step = 0, ticked: [Set<Int>] = []

    /// A held request with its real content; its questions are answered here one at a time.
    public mutating func ask(_ a: Asked) {
        if asked?.id != a.id { asked = a; step = 0; ticked = a.questions.map { _ in [] } }
        let n = askedNotice
        guard asking != n else { return }
        asking = n
        folded = false
        if mode == .face || mode == .roster || mode == .reply { mode = .question }
    }

    private var askedNotice: Notice {
        guard let a = asked else { return Notice(session: "", text: "") }
        guard step < a.questions.count else {
            return Notice(session: a.session, text: a.text, options: ["Allow"] + (a.forSession ? ["This session"] : []) + ["Deny", "Stop"])
        }
        let q = a.questions[step]
        let marks = q.options.enumerated().map { q.multi ? (ticked[step].contains($0) ? "✓ " : "○ ") + $1 : $1 }
        let head = a.questions.count > 1 ? "\(q.header) \(step + 1)/\(a.questions.count)" : q.header
        return Notice(session: a.session, text: (head.isEmpty ? "" : head + " · ") + q.question, options: marks + (q.multi ? ["Done"] : []) + ["At the Mac"])
    }

    /// A tap on option `i` of the request showing.
    public mutating func pick(_ i: Int) -> Pick {
        guard let a = asked, step < a.questions.count else {
            // Allow, This session (when it can), Deny, Stop.
            let o = i - (asked?.forSession == true ? 1 : 0)
            return i == 0 ? .decide(true) : asked?.forSession == true && i == 1 ? .allowSession : o == 1 ? .decide(false) : .stop
        }
        let q = a.questions[step]
        // The last option leaves the questions to the Mac's own dialog.
        if i == q.options.count + (q.multi ? 1 : 0) { return .decide(false) }
        if q.multi && i < q.options.count {
            if ticked[step].contains(i) { ticked[step].remove(i) } else { ticked[step].insert(i) }
        } else {
            if !q.multi { ticked[step] = [i] }
            step += 1
        }
        if step == a.questions.count {
            var out: [String: String] = [:]
            for (k, q) in a.questions.enumerated() { out[q.question] = ticked[k].sorted().map { q.options[$0] }.joined(separator: ", ") }
            return .answer(out)
        }
        asking = askedNotice
        return .more
    }

    public mutating func answered() {
        guard asking != nil else { return }
        asking = nil
        asked = nil
        settle()
    }

    private mutating func settle() {
        let any = asking != nil || !board.pending.isEmpty
        switch mode {
        case .face: if any && !folded { mode = .question }
        case .question, .detail: if !any { mode = .face }
        case .roster, .reply: break
        }
    }

    /// Where all the text is nudged to now, so no line sits on the same pixels for long (the SE's LCD keeps a ghost
    /// of what stays put for hours): two very slow waves (15 and 11 minutes, 8 and 6 pt) and a 3 pt circle every 2
    /// minutes, always faster than they are, so it creeps at 0.09 to 0.23 pt a second and never stops.
    public var drift: SIMD2<Double> {
        let w = 2 * Double.pi
        return SIMD2(8 * sin(w * now / 900) + 3 * cos(w * now / 120), 6 * sin(w * now / 660) + 3 * sin(w * now / 120))
    }

    /// Nobody has touched the pad for a while, no text is up and nothing needs you: the backlight can dim.
    public var resting: Bool { mode == .face && asking == nil && board.pending.isEmpty && now - touched >= Screen.unattended }

    /// A finger on the pad: whatever is up stays up a while longer.
    public mutating func attend() { touched = now }

    /// A tap on its ant brings back a question folded away (any tap, with `session` nil: the only ant); true if there
    /// was one. A tap elsewhere leaves it folded, so the other ants and replies stay in reach.
    public mutating func unfold(session id: String? = nil) -> Bool {
        attend()
        guard folded else { return false }
        if let id {
            guard let i = board.pending.firstIndex(where: { $0.from == id }) else { return false }
            page = i
        }
        folded = false
        settle()
        return mode != .face
    }

    /// Every frame: text left up untouched goes back into its ant, and a question folds until a new one comes or a
    /// tap brings it back. A permission request stays, since only its buttons answer it.
    public mutating func idle() {
        let key = "\(mode) \(current?.text ?? "") \(reading ?? "")"
        if key != seen { seen = key; shownAt = now }
        guard mode != .face, asking == nil, now - max(touched, shownAt) >= Screen.unattended else { return }
        folded = true
        mode = .face
    }

    public mutating func tap() {
        switch mode {
        case .question: mode = .detail
        // Read to the end, a tap puts the question away into its ant, where a tap on it brings it back; a permission
        // request stays, since only its buttons answer it.
        case .detail: if asking != nil { mode = .question } else { mode = .face; folded = true }
        case .roster, .reply: mode = (board.pending.isEmpty || folded) && asking == nil ? .face : .question
        case .face: break
        }
    }

    /// Opens a session's question (its face was tapped); false when it has none.
    @discardableResult public mutating func show(session: String) -> Bool {
        guard let i = board.pending.firstIndex(where: { $0.session == session }) else { return false }
        page = i
        mode = .question
        return true
    }

    /// Moves `by` questions along, wrapping; from the bare face it opens the first.
    public mutating func swipe(by n: Int = 1) {
        if mode == .reply, let i = replies.firstIndex(where: { $0.id == reading }) {
            let c = replies.count
            reading = replies[((i + n) % c + c) % c].id
            scroll = 0
            return
        }
        guard asking == nil, !board.pending.isEmpty else { return }
        if mode == .face || mode == .roster { mode = .question; return }
        let c = board.pending.count
        page = ((page + n) % c + c) % c
    }

    /// Whether a swipe sideways goes anywhere: to another reply, or another question.
    public var turns: Bool {
        if mode == .reply { return replies.count > 1 }
        guard asking == nil, !board.pending.isEmpty else { return false }
        return mode == .roster || board.pending.count > 1
    }

    /// The session the question showing came from, where its answer goes.
    public var asker: String? { mode == .reply ? reading : asking == nil ? current?.from : nil }

    /// The sessions (ids from the hooks) with a manager question waiting, shown or folded away.
    public var waiting: Set<String> { Set(board.pending.compactMap(\.from)) }

    /// The session the open text is about (its id from the hooks), if it's known.
    public var subject: String? { mode == .reply ? reading : mode == .question || mode == .detail ? current?.from : nil }

    /// What each session last said. Text comes out of an ant only when its session needs you, so a reply opens by
    /// itself only when it ends on a question to you; any other waits for a tap on its ant.
    public mutating func update(replies r: [Reply]) {
        replies = r
        if let n = r.first, n.at > newest {
            if newest > -.infinity, mode == .face, Screen.asks(n.text) { reading = n.id; scroll = 0; mode = .reply }
            newest = n.at
        }
        if mode == .reply, !r.contains(where: { $0.id == reading }) { mode = .face }
    }

    /// Whether a reply ends on a question: its last sentence, past any `jeta:` lines, ends in a question mark.
    static func asks(_ text: String) -> Bool {
        let last = plain(text).last?.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "*_`)")))
        return last?.hasSuffix("?") == true
    }

    /// Opens a session's last reply (its face was tapped); false when it has none.
    @discardableResult public mutating func read(session id: String?) -> Bool {
        guard let id = id ?? replies.first?.id, replies.contains(where: { $0.id == id }) else { return false }
        reading = id
        scroll = 0
        mode = .reply
        return true
    }

    /// Scrolls the reply `by` pages of lines, forward positive.
    public mutating func scroll(by n: Int) {
        guard mode == .reply else { return }
        let count = shownReply.map { Screen.plain($0.text).reduce(0) { $0 + $1.count / 30 + 1 } } ?? 0
        scroll = max(0, min(scroll + n * (Screen.readLines - 1), max(0, count)))
    }
    /// How long ago, coarse: it changes at most once a minute.
    /// How a session is, for the list: in whole minutes, so a line changes at most once a minute.
    static func state(_ s: SessionInfo, now: Double) -> String {
        switch s.state {
        case .needs: return "needs you"
        case .working: return s.since.map { now - $0 < 60 ? "just started" : "working \(Screen.took(now - $0))" } ?? "working"
        case .finished(let at): return "done " + ago(now - at) + (s.unseen ? ", not seen" : "")
        case .stale(let since): return "no news \(Screen.took(now - since))"
        case .failed: return "stopped on an error"
        case .quiet: return "quiet"
        }
    }

    /// A length of time in minutes, or hours and minutes.
    static func took(_ s: Double) -> String {
        let m = Int(s / 60)
        return m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    static func ago(_ s: Double) -> String {
        switch s {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(s / 60)) min ago"
        case ..<86400: return "\(Int(s / 3600)) h ago"
        default: return Int(s / 86400) == 1 ? "1 day ago" : "\(Int(s / 86400)) days ago"
        }
    }
    private var shownReply: Reply? { replies.first { $0.id == reading } }

    /// The reply's lines showing, which page that is and how many there are; `around` adds a page's worth of
    /// lines on each side, past the ones showing.
    func window(width: Int, around: Bool = false) -> (lines: [Line], page: Int, pages: Int)? {
        guard let r = shownReply else { return nil }
        let all = Screen.plain(r.text).flatMap { Screen.wrap($0, .body, width: width) }, step = Screen.readLines - 1
        let from = min(scroll, max(0, all.count - Screen.readLines)), to = min(all.count, from + Screen.readLines)
        let row = { (i: Int) -> Line in var l = all[i]; l.row = (i, i - from); return l }
        let lines = (from..<to).map(row) + (around ? (max(0, from - step)..<from).map(row) + (to..<min(all.count, to + step)).map(row) : [])
        return (lines, (from + step - 1) / step, max(1, (all.count - 2) / step + 1))
    }

    /// Reading a reply: the page showing and how many, for the dots beside it.
    public func pages(width w: Double, height h: Double) -> (page: Int, of: Int)? {
        guard mode == .reply, let p = window(width: Screen.columns(width: w, height: h, open: true)) else { return nil }
        return (p.page, p.pages)
    }

    /// A reply as plain sentences: Markdown's marks go, paragraphs and list items stay lines of their own.
    static func plain(_ s: String) -> [String] {
        s.split(separator: "\n").map { line in
            var l = String(line).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            while l.hasPrefix("#") { l.removeFirst() }
            return l.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty && !$0.hasPrefix("jeta:") && !$0.hasPrefix("|-") && !$0.hasPrefix("|:") }
    }

    /// Tapping option `i` of the question showing: the line to send the manager, like `server: 8443`.
    public func choose(_ i: Int) -> String? {
        guard let n = current, mode == .question || mode == .detail, n.options.indices.contains(i) else { return nil }
        // A session asking for itself (its next-step box) gets the answer alone; the manager, asking for another,
        // gets who it's for.
        let plain = { (s: String) in s.replacingOccurrences(of: "\u{00A0}", with: " ") }
        if n.own { return n.options[i] }
        if let f = n.from, let me = sessions.first(where: { $0.id == f }), plain(me.name) == plain(n.session) { return n.options[i] }
        return "\(n.session): \(n.options[i])"
    }

    /// A swipe down: on the bare face it opens the session list.
    public mutating func swipeDown() {
        if mode == .face { mode = .roster }
    }

    /// A question's options; the first is the suggested one.
    static func options(_ n: Notice) -> [Line] {
        // With boxes to tick, the ticked ones are the bold ones.
        let boxes = n.options.contains { $0.hasPrefix("○ ") || $0.hasPrefix("✓ ") }
        return n.options.enumerated().map { Line(text: $1, style: (boxes ? $1.hasPrefix("✓ ") : $0 == 0) ? .suggestion : .option) }
    }

    /// The text to draw, wrapped to `width` characters.
    public func lines(width: Int) -> [Line] {
        let all = text(width: width)
        guard !note.isEmpty else { return all }
        return all.filter { $0.style != .hint } + Screen.wrap(note, .hint, width: width, max: 2)
    }

    static func wrap(_ s: String, _ style: Style, width: Int, max: Int = .max) -> [Line] {
        var out: [String] = [], line = ""
        for word in s.split(separator: " ") {
            if line.isEmpty { line = String(word) }
            else if line.count + 1 + word.count <= width { line += " " + word }
            else { out.append(line); line = String(word) }
        }
        if !line.isEmpty { out.append(line) }
        out = out.map { $0.count > width ? String($0.prefix(width - 1)) + "…" : $0 }
        if out.count > max { out = Array(out.prefix(max)); out[max - 1] = String(out[max - 1].prefix(width - 1)) + "…" }
        return out.map { Line(text: $0, style: style) }
    }

    private func text(width: Int) -> [Line] {
        func wrap(_ s: String, _ style: Style, max: Int = .max) -> [Line] { Screen.wrap(s, style, width: width, max: max) }
        switch mode {
        case .face: return []
        case .question:
            guard let n = current else { return [] }
            let options = Screen.options(n)
            if asking != nil {
                return wrap("\(n.session) asks", .title) + wrap(n.text, .body, max: 3) + options
                    + wrap(n.options.contains("Deny") ? "tap more · hold: deny, saying why" : "tap more", .hint)
            }
            return wrap("\(n.session) needs you", .title) + wrap(n.text, .body, max: 1) + options
                + wrap(options.isEmpty ? "tap more · hold: answer" : "tap one, or hold to answer", .hint)
        case .detail:
            guard let n = current else { return [] }
            var out = wrap("\(n.session) · \(asking == nil ? "waiting on you" : "asks")", .title) + wrap(n.text, .body, max: asking == nil ? 5 : 9)
            out += Screen.options(n)
            out += wrap(asking == nil ? "hold: answer · swipe: next · tap: close" : "tap: close", .hint)
            if asking == nil, board.pending.count > 1 { out.append(Line(text: "\(page + 1) / \(board.pending.count)", style: .hint)) }
            return out
        case .roster:
            let rows = sessions.isEmpty ? board.roster.prefix(5).flatMap { wrap("\($0.session) · \($0.state)", .body, max: 1) }
                // Every session, with what it's doing under it; more than four, one line each so they all fit.
                : sessions.count > 4 ? sessions.flatMap { s in
                    wrap("\(s.name) · \(Screen.state(s, now: now))" + (s.doing.isEmpty ? "" : " · \(s.doing)"), .body, max: 1)
                } : sessions.flatMap { s in
                    wrap("\(s.name) · \(Screen.state(s, now: now))", .body, max: 1) + (s.doing.isEmpty ? [] : wrap(s.doing, .hint, max: 1))
                }
            return (rows.isEmpty ? wrap("no sessions yet", .body) : rows) + wrap("tap: close · hold: ask the manager", .hint)
        case .reply:
            guard let r = shownReply, let w = window(width: width, around: true) else { return [] }
            return wrap("\(r.session) · \(Screen.ago(now - r.at))", .title) + w.lines
                + wrap((w.page + 1 < w.pages ? "swipe up: more · " : "") + "hold: answer · tap: close", .hint)
        }
    }
}

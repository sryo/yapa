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
    public init(id: String, session: String, tool: String, text: String, questions: [Question] = []) {
        self.id = id; self.session = session; self.tool = tool; self.text = text; self.questions = questions
    }
}

/// What a tap on a request's option does.
public enum Pick: Equatable {
    /// A permission decided: allow or deny.
    case decide(Bool)
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
    public struct Line: Equatable { public var text: String, style: Style }

    public private(set) var mode = Mode.face
    /// What talking is doing (listening, sending, what che typed); it takes the hint's place while it's up.
    public var note = ""
    /// The clock replies are stamped with, so an open one can say how long ago it came in.
    public var now = 0.0
    private var board = NoticeBoard(), page = 0
    private var replies: [Reply] = [], reading: String?, scroll = 0, newest = -Double.infinity
    /// How many lines of a reply show at once.
    static let readLines = 7

    public init() {}

    /// A permission request waiting on the pad, shown before any question with Allow and Deny to tap.
    public private(set) var asking: Notice?

    var current: Notice? { asking ?? (board.pending.isEmpty ? nil : board.pending[page % board.pending.count]) }

    public mutating func update(_ b: NoticeBoard) {
        board = b
        if page >= board.pending.count { page = 0 }
        settle()
    }

    /// A session asks to use a tool (`what` is the tool and the part of its call worth a glance); nil once answered.
    public mutating func ask(session: String, _ what: String) {
        let n = Notice(session: session, text: what, options: ["Allow", "Deny"])
        guard asking != n else { return }
        asking = n
        if mode == .face || mode == .roster { mode = .question }
    }

    private var asked: Asked?, step = 0, ticked: [Set<Int>] = []

    /// A held request with its real content; its questions are answered here one at a time.
    public mutating func ask(_ a: Asked) {
        if asked?.id != a.id { asked = a; step = 0; ticked = a.questions.map { _ in [] } }
        let n = askedNotice
        guard asking != n else { return }
        asking = n
        if mode == .face || mode == .roster || mode == .reply { mode = .question }
    }

    private var askedNotice: Notice {
        guard let a = asked else { return Notice(session: "", text: "") }
        guard step < a.questions.count else { return Notice(session: a.session, text: a.text, options: ["Allow", "Deny"]) }
        let q = a.questions[step]
        let marks = q.options.enumerated().map { q.multi ? (ticked[step].contains($0) ? "✓ " : "○ ") + $1 : $1 }
        let head = a.questions.count > 1 ? "\(q.header) \(step + 1)/\(a.questions.count)" : q.header
        return Notice(session: a.session, text: (head.isEmpty ? "" : head + " · ") + q.question, options: marks + (q.multi ? ["Done"] : []) + ["At the Mac"])
    }

    /// A tap on option `i` of the request showing.
    public mutating func pick(_ i: Int) -> Pick {
        guard let a = asked, step < a.questions.count else { return .decide(i == 0) }
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
        case .face: if any { mode = .question }
        case .question, .detail: if !any { mode = .face }
        case .roster, .reply: break
        }
    }

    public mutating func tap() {
        switch mode {
        case .question: mode = .detail
        case .detail: mode = .question
        case .roster, .reply: mode = board.pending.isEmpty && asking == nil ? .face : .question
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

    /// The session the question showing came from, where its answer goes.
    public var asker: String? { mode == .reply ? reading : asking == nil ? current?.from : nil }

    /// The session the open text is about (its id from the hooks), if it's known.
    public var subject: String? { mode == .reply ? reading : mode == .question || mode == .detail ? current?.from : nil }

    /// What each session last said. A new one opens to read, unless something else is up.
    public mutating func update(replies r: [Reply]) {
        replies = r
        if let n = r.first, n.at > newest {
            if newest > -.infinity, mode == .face { reading = n.id; scroll = 0; mode = .reply }
            newest = n.at
        }
        if mode == .reply, !r.contains(where: { $0.id == reading }) { mode = .face }
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
    static func ago(_ s: Double) -> String {
        switch s {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(s / 60)) min ago"
        case ..<86400: return "\(Int(s / 3600)) h ago"
        default: return Int(s / 86400) == 1 ? "1 day ago" : "\(Int(s / 86400)) days ago"
        }
    }
    private var shownReply: Reply? { replies.first { $0.id == reading } }

    /// The reply's lines showing, which page that is and how many there are.
    func window(width: Int) -> (lines: [Line], page: Int, pages: Int)? {
        guard let r = shownReply else { return nil }
        let all = Screen.plain(r.text).flatMap { Screen.wrap($0, .body, width: width) }, step = Screen.readLines - 1
        let from = min(scroll, max(0, all.count - Screen.readLines))
        return (Array(all[from..<min(all.count, from + Screen.readLines)]), (from + step - 1) / step, max(1, (all.count - 2) / step + 1))
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
            if asking != nil { return wrap("\(n.session) asks", .title) + wrap(n.text, .body, max: 3) + options + wrap("tap more", .hint) }
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
            let rows = board.roster.prefix(5).flatMap { wrap("\($0.session) · \($0.state)", .body, max: 1) }
            return (rows.isEmpty ? wrap("no sessions yet", .body) : rows) + wrap("tap: close · hold: ask the manager", .hint)
        case .reply:
            guard let r = shownReply, let w = window(width: width) else { return [] }
            return wrap("\(r.session) · \(Screen.ago(now - r.at))", .title) + w.lines
                + wrap((w.page + 1 < w.pages ? "swipe up: more · " : "") + "hold: answer · tap: close", .hint)
        }
    }
}

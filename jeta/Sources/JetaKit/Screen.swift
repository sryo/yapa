import Foundation

/// What jeta shows besides the face, and what each gesture does. The bare face is the default; a session's question
/// takes over (who and what); a tap opens the detail and another closes it; a swipe moves between waiting sessions; a
/// long press on the bare face opens the session list. With anything open, holding is for talking (che), not a list.
public struct Screen {
    public enum Mode: Equatable { case face, question, detail, roster }
    /// What a long press means right now.
    public enum Hold: Equatable { case roster, talk(to: String?) }
    public enum Style: Equatable { case title, body, hint, option, suggestion }
    public struct Line: Equatable { public var text: String, style: Style }

    public private(set) var mode = Mode.face
    private var board = NoticeBoard(), page = 0

    public init() {}

    var current: Notice? { board.pending.isEmpty ? nil : board.pending[page % board.pending.count] }

    public mutating func update(_ b: NoticeBoard) {
        board = b
        if page >= board.pending.count { page = 0 }
        switch mode {
        case .face: if !board.pending.isEmpty { mode = .question }
        case .question, .detail: if board.pending.isEmpty { mode = .face }
        case .roster: break
        }
    }

    public mutating func tap() {
        switch mode {
        case .question: mode = .detail
        case .detail: mode = .question
        case .roster: mode = board.pending.isEmpty ? .face : .question
        case .face: break
        }
    }

    public mutating func swipe() {
        guard !board.pending.isEmpty, mode == .question || mode == .detail else { return }
        page = (page + 1) % board.pending.count
    }

    /// Tapping option `i` of the question showing: the line to send the manager, like `server: 8443`.
    public func choose(_ i: Int) -> String? {
        guard let n = current, mode == .question || mode == .detail, n.options.indices.contains(i) else { return nil }
        return "\(n.session): \(n.options[i])"
    }

    @discardableResult public mutating func longPress() -> Hold {
        switch mode {
        case .face: mode = .roster; return .roster
        case .question, .detail: return .talk(to: current?.session)
        case .roster: return .talk(to: nil)
        }
    }

    /// A question's options; the first is the suggested one.
    static func options(_ n: Notice) -> [Line] {
        n.options.enumerated().map { Line(text: $1, style: $0 == 0 ? .suggestion : .option) }
    }

    /// The text to draw, wrapped to `width` characters.
    public func lines(width: Int) -> [Line] {
        func wrap(_ s: String, _ style: Style, max: Int = .max) -> [Line] {
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
        switch mode {
        case .face: return []
        case .question:
            guard let n = current else { return [] }
            let options = Screen.options(n)
            return wrap("\(n.session) needs you", .title) + wrap(n.text, .body, max: 1) + options
                + wrap(options.isEmpty ? "tap more · hold to answer" : "tap an option · hold to answer", .hint)
        case .detail:
            guard let n = current else { return [] }
            var out = wrap("\(n.session) · waiting on you", .title) + wrap(n.text, .body, max: 5)
            out += Screen.options(n)
            out += wrap("hold: answer · swipe: next · tap: close", .hint)
            if board.pending.count > 1 { out.append(Line(text: "\(page + 1) / \(board.pending.count)", style: .hint)) }
            return out
        case .roster:
            let rows = board.roster.prefix(5).flatMap { wrap("\($0.session) · \($0.state)", .body, max: 1) }
            return (rows.isEmpty ? wrap("no sessions yet", .body) : rows) + wrap("tap: close · hold: ask the manager", .hint)
        }
    }
}

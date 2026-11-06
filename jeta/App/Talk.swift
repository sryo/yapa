import AVFoundation
import Network
import UIKit

/// Push-to-talk: hold the face to record, release to send the clip to che on the Mac (found over
/// Bonjour), which types the words into Claude and presses Enter a moment later. A tap in that moment stops it.
final class Talk: NSObject {
    private let face: Face
    /// What it's doing, for the screen to show in the hint's place ("" when there's nothing to say), and when it
    /// stops mattering (nil while it's still true).
    var onNote: ((String, Double?) -> Void)?
    /// The Claude Code session a hold at a point is for, so che types into that session, not whatever is in front.
    var session: ((CGPoint) -> String?)?
    /// While a permission request is up, what's said is the reason it's denied, not words to type: `refusing` says
    /// whether one is up, and `onRefuse` gets the words.
    var refusing: (() -> Bool)?, onRefuse: ((String) -> Void)?
    private var to: String?
    private let browser = NWBrowser(for: .bonjour(type: "_che._tcp", domain: nil), using: .tcp)
    private var mac: NWEndpoint?, recorder: AVAudioRecorder?, began = 0.0, enterBy = 0.0, shown = 0
    private var before = Mood.idle
    /// The Mac's address on the home network, from the hooks it sends: che is reached there first, since Bonjour can
    /// hand back a link-local address che doesn't know the pad by, and refuses.
    var macHost: String?
    /// che's port: 8078, unless test/jeta-flows points the pad at its stand-in.
    var macPort: UInt16 = 8078, pinned = false
    /// What went wrong the last time che didn't answer, to say in its place.
    private(set) var trouble = "the Mac didn't answer: is che running?"
    private let press: UILongPressGestureRecognizer
    private let clip = FileManager.default.temporaryDirectory.appendingPathComponent("talk.wav")

    init(face: Face, in view: UIView) {
        self.face = face
        press = UILongPressGestureRecognizer(target: nil, action: nil)
        super.init()
        press.addTarget(self, action: #selector(held))
        press.minimumPressDuration = 0.15
        view.addGestureRecognizer(press)
        browser.browseResultsChangedHandler = { [weak self] found, _ in self?.mac = found.first?.endpoint }
        browser.start(queue: .main)
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }
    }

    /// A tap while Enter is pending stops it; true when the tap was used up that way.
    func tapped() -> Bool {
        guard CACurrentMediaTime() < enterBy else { return false }
        enterBy = 0
        post("/cancel", Data()) { _ in }
        show("Not sent", for: 3)
        return true
    }

    /// Where the finger is while it's held down to talk.
    private(set) var heldAt: CGPoint?

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { hold(at: g.location(in: g.view)) }
        else if [.ended, .cancelled, .failed].contains(g.state) { letGo() } else { heldAt = g.location(in: g.view) }
    }

    /// A finger held down at `p` to talk, and lifted: from the hold, or from test/jeta-flows' driver.
    func hold(at p: CGPoint) { heldAt = p; to = session?(p); record() }
    func letGo() { heldAt = nil; send() }

    /// The finger held is dragging the text instead: what it recorded in the first moment is dropped, unsent. Past
    /// that moment it's talking, and stays so (false).
    func drop() -> Bool {
        guard let r = recorder else { return true }
        guard CACurrentMediaTime() - began < 0.6 else { return false }
        r.stop()
        recorder = nil
        heldAt = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        face.set(before, at: CACurrentMediaTime())
        show("")
        press.isEnabled = false
        press.isEnabled = true
        return true
    }

    private func record() {
        let session = AVAudioSession.sharedInstance()
        guard session.recordPermission == .granted else { return show("Allow the microphone in Settings > miga", for: 5) }
        do {
            try session.setCategory(.record)
            try session.setActive(true)
            let r = try AVAudioRecorder(url: clip, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                                               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
            guard r.record() else { return show("Can't record: the microphone is busy", for: 4) }
            recorder = r
        } catch {
            return show("Can't record: \(error.localizedDescription)", for: 4)
        }
        began = CACurrentMediaTime()
        before = face.mood
        face.set(.listening, at: CACurrentMediaTime())
        show(mac == nil ? "Listening… (no Mac found yet: is che running?)" : "Listening…")
    }

    private func send() {
        guard let r = recorder else { return }
        r.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        face.set(before, at: CACurrentMediaTime())
        guard CACurrentMediaTime() - began > 0.3, let wav = try? Data(contentsOf: clip) else { return show("") }
        if refusing?() == true {
            show("Sending…")
            // Heard on the Mac but typed nowhere (dry): the words go back to the pad as the reason.
            return post("/talk?dry", wav) { [weak self] json in
                guard let self else { return }
                guard let text = json?["text"] as? String else { return self.show(self.trouble, for: 4) }
                if text.isEmpty { return self.show("Didn't catch that", for: 3) }
                self.show("Denied: \(text)", for: 3)
                self.onRefuse?(text)
            }
        }
        deliver("/talk", wav, to: to)
    }

    /// Types the text on the Mac as if it had been spoken (an option picked on the screen), with the same notes.
    func say(_ text: String, to session: String?) {
        deliver("/say", Data(text.utf8), to: session)
    }

    /// Starts a Claude Code session on the Mac in `folder`, in the Claude app; `done` says how it went, in a few words.
    func newSession(in folder: String, done: @escaping (String) -> Void) {
        post("/new", Data(folder.utf8)) { json in
            done(json == nil ? self.trouble : json?["url"] != nil ? "opening in the Claude app" : "the Mac has no such folder")
        }
    }

    /// The Claude app's names for the sessions `ids`, each with the session that started it; nil when the Mac didn't
    /// answer.
    func names(_ ids: [String], done: @escaping ([String: (name: String, parent: String?, focused: Double?)]?) -> Void) {
        let list = ids.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(["-", ","])) ?? ""
        post("/sessions?ids=" + list, Data(), method: "GET") { json in
            guard let all = json?["sessions"] as? [String: [String: Any]] else { return done(nil) }
            done(all.compactMapValues { o in (o["name"] as? String).map { ($0, o["parent"] as? String, o["focused"] as? Double) } })
        }
    }

    private func deliver(_ path: String, _ body: Data, to session: String?) {
        show("Sending…")
        let query = session.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(["-"])) }
        post(path + (query.map { "?session=\($0)" } ?? ""), body) { [weak self] json in
            guard let self, let json else { return self?.show(self?.trouble ?? "", for: 4) ?? () }
            let text = json["text"] as? String ?? "", wait = json["enter_in"] as? Double ?? 0
            if text.isEmpty { return self.show("Didn't catch that", for: 3) }
            self.show(wait > 0 ? "\(text)  ·  tap to stop" : "Copied: \(text)", for: max(wait, 2))
            self.enterBy = CACurrentMediaTime() + wait
        }
    }

    /// A note given `for` seconds goes by itself then, unless another took its place.
    private func show(_ text: String, for seconds: Double? = nil) {
        shown += 1
        let id = shown
        onNote?(text, seconds.map { CACurrentMediaTime() + $0 })
        guard let seconds else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.shown == id { self?.onNote?("", nil) }
        }
    }

    /// One HTTP/1.1 request over a raw connection, since URLSession can't dial a Bonjour service; nil on failure.
    private func post(_ path: String, _ body: Data, method: String = "POST", done: @escaping ([String: Any]?) -> Void) {
        let to = macHost.map { NWEndpoint.hostPort(host: NWEndpoint.Host($0), port: NWEndpoint.Port(rawValue: macPort)!) } ?? mac
        guard let to else { trouble = "no Mac found yet: is che running?"; return done(nil) }
        trouble = "the Mac didn't answer: is che running?"
        let c = NWConnection(to: to, using: .tcp)
        var got = Data(), finished = false
        let finish = { (json: [String: Any]?) in
            guard !finished else { return }
            finished = true
            c.cancel()
            done(json)
        }
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, end, error in
                got += data ?? Data()
                guard end || error != nil else { return read() }
                // Closed before a word came back: che turned the pad away.
                self.trouble = got.isEmpty && error == nil ? "che refused the pad: add its address to CHE_FROM"
                    : "the Mac didn't answer: is che running?"
                finish(got.range(of: Data("\r\n\r\n".utf8)).flatMap {
                    try? JSONSerialization.jsonObject(with: got[$0.upperBound...]) as? [String: Any]
                })
            }
        }
        c.start(queue: .main)
        let head = "\(method) \(path) HTTP/1.1\r\nHost: yapa\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in })
        read()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish(nil) }
    }
}

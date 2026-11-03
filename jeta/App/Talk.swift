import AVFoundation
import Network
import UIKit

/// Push-to-talk: hold the face to record, release to send the clip to che on the Mac (found over
/// Bonjour), which types the words into Claude and presses Enter a moment later. A tap in that moment stops it.
final class Talk: NSObject {
    private let face: Face
    /// What it's doing, for the screen to show in the hint's place ("" when there's nothing to say).
    var onNote: ((String) -> Void)?
    private let browser = NWBrowser(for: .bonjour(type: "_che._tcp", domain: nil), using: .tcp)
    private var mac: NWEndpoint?, recorder: AVAudioRecorder?, began = 0.0, enterBy = 0.0, turn = 0
    private var before = Mood.idle
    private let clip = FileManager.default.temporaryDirectory.appendingPathComponent("talk.wav")

    init(face: Face, in view: UIView) {
        self.face = face
        super.init()
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held))
        hold.minimumPressDuration = 0.15
        view.addGestureRecognizer(hold)
        browser.browseResultsChangedHandler = { [weak self] found, _ in self?.mac = found.first?.endpoint }
        browser.start(queue: .main)
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }
    }

    /// A tap while Enter is pending stops it; true when the tap was used up that way.
    func tapped() -> Bool {
        guard CACurrentMediaTime() < enterBy else { return false }
        enterBy = 0
        post("/cancel", Data()) { _ in }
        show("Not sent")
        return true
    }

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { record() }
        if [.ended, .cancelled, .failed].contains(g.state) { send() }
    }

    private func record() {
        let session = AVAudioSession.sharedInstance()
        guard session.recordPermission == .granted else { return show("Allow the microphone in Settings > jeta") }
        do {
            try session.setCategory(.record)
            try session.setActive(true)
            let r = try AVAudioRecorder(url: clip, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                                               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
            guard r.record() else { return show("Can't record: the microphone is busy") }
            recorder = r
        } catch {
            return show("Can't record: \(error.localizedDescription)")
        }
        began = CACurrentMediaTime()
        turn += 1
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
        deliver("/talk", wav)
    }

    /// Types the text on the Mac as if it had been spoken (an option picked on the screen), with the same notes.
    func say(_ text: String) {
        turn += 1
        deliver("/say", Data(text.utf8))
    }

    private func deliver(_ path: String, _ body: Data) {
        show("Sending…")
        let turn = turn
        post(path, body) { [weak self] json in
            guard let self, let json else { return self?.show("Mac didn't answer: is che running?") ?? () }
            let text = json["text"] as? String ?? "", wait = json["enter_in"] as? Double ?? 0
            if text.isEmpty { return self.show("Didn't catch that") }
            self.show(wait > 0 ? "\(text)  ·  tap to stop" : "Copied: \(text)")
            self.enterBy = CACurrentMediaTime() + wait
            DispatchQueue.main.asyncAfter(deadline: .now() + max(wait, 2)) {
                if self.turn == turn { self.show("") }
            }
        }
    }

    private func show(_ text: String) { onNote?(text) }

    /// One HTTP/1.1 POST over a raw connection, since URLSession can't dial a Bonjour service; nil on failure.
    private func post(_ path: String, _ body: Data, done: @escaping ([String: Any]?) -> Void) {
        guard let mac else { return done(nil) }
        let c = NWConnection(to: mac, using: .tcp)
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
                finish(got.range(of: Data("\r\n\r\n".utf8)).flatMap {
                    try? JSONSerialization.jsonObject(with: got[$0.upperBound...]) as? [String: Any]
                })
            }
        }
        c.start(queue: .main)
        let head = "POST \(path) HTTP/1.1\r\nHost: yapa\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in })
        read()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish(nil) }
    }
}

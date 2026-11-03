import AVFoundation
import Network
import UIKit

/// Push-to-talk: hold the face to record, release to send the clip to yapa-talk on the Mac (found over
/// Bonjour), which types the words into Claude and presses Enter a moment later. A tap in that moment stops it.
final class Talk: NSObject {
    private let face: Face, note = UILabel()
    private let browser = NWBrowser(for: .bonjour(type: "_yapa-talk._tcp", domain: nil), using: .tcp)
    private var mac: NWEndpoint?, recorder: AVAudioRecorder?, began = 0.0, enterBy = 0.0, turn = 0
    private let clip = FileManager.default.temporaryDirectory.appendingPathComponent("talk.wav")

    init(face: Face, in view: UIView) {
        self.face = face
        super.init()
        note.textColor = UIColor(white: 0.6, alpha: 1)
        note.font = .systemFont(ofSize: 13)
        note.textAlignment = .center
        note.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(note)
        NSLayoutConstraint.activate([note.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     note.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -32),
                                     note.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)])
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
        show(.idle, "Not sent")
        return true
    }

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { record() }
        if [.ended, .cancelled, .failed].contains(g.state) { send() }
    }

    private func record() {
        let session = AVAudioSession.sharedInstance()
        guard session.recordPermission == .granted else { return show(.dizzy, "Allow the microphone in Settings > yapa") }
        do {
            try session.setCategory(.record)
            try session.setActive(true)
            let r = try AVAudioRecorder(url: clip, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                                               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
            guard r.record() else { return show(.dizzy, "Can't record: the microphone is busy") }
            recorder = r
        } catch {
            return show(.dizzy, "Can't record: \(error.localizedDescription)")
        }
        began = CACurrentMediaTime()
        turn += 1
        show(.attention, mac == nil ? "Listening… (no Mac found yet: is yapa-talk running?)" : "Listening…")
    }

    private func send() {
        guard let r = recorder else { return }
        r.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        guard CACurrentMediaTime() - began > 0.3, let wav = try? Data(contentsOf: clip) else { return show(.idle, "") }
        show(.curious, "Sending…")
        let turn = turn
        post("/talk", wav) { [weak self] json in
            guard let self, let json else { return self?.show(.dizzy, "Mac didn't answer: is yapa-talk running?") ?? () }
            let text = json["text"] as? String ?? "", wait = json["enter_in"] as? Double ?? 0
            if text.isEmpty { return self.show(.bored, "Didn't catch that") }
            self.show(wait > 0 ? .impatient : .proud, wait > 0 ? "\(text)  ·  tap to stop" : "Copied: \(text)")
            self.enterBy = CACurrentMediaTime() + wait
            DispatchQueue.main.asyncAfter(deadline: .now() + max(wait, 2)) {
                if self.turn == turn { self.show(.idle, "") }
            }
        }
    }

    private func show(_ mood: Mood, _ text: String) {
        face.set(mood, at: CACurrentMediaTime())
        note.text = text
    }

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

import AVFoundation
import Speech

/// Transcribes a clip on this Mac with Apple's on-device SpeechTranscriber, in every language at once.
public final class Transcriber {
    let locales: [Locale]
    public init(_ ids: [String]) { locales = ids.map(Locale.init(identifier:)) }

    func module(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.transcriptionConfidence])
    }

    /// Downloads any missing language model; the first run needs the internet, later ones don't.
    public func prepare() async throws {
        for l in locales {
            guard let have = await SpeechTranscriber.supportedLocale(equivalentTo: l) else {
                throw NSError(domain: "yapa-talk", code: 1, userInfo: [NSLocalizedDescriptionKey: "no on-device speech model for \(l.identifier)"])
            }
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [module(have)]) {
                try await req.downloadAndInstall()
            }
        }
    }

    public func hear(_ url: URL) async throws -> [Heard] {
        try await withThrowingTaskGroup(of: Heard.self) { group in
            for l in locales { group.addTask { try await self.hear(url, l) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
    }

    func hear(_ url: URL, _ locale: Locale) async throws -> Heard {
        let t = module(locale), analyzer = SpeechAnalyzer(modules: [t])
        let file = try AVAudioFile(forReading: url)
        let collect = Task { try await t.results.reduce(into: AttributedString()) { $0 += $1.text } }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let text = try await collect.value
        // Confidence of the whole clip: each run's confidence, weighted by how much text it covers.
        var sum = 0.0, n = 0.0
        for run in text.runs {
            let k = Double(text[run.range].characters.count)
            sum += (run.transcriptionConfidence ?? 0) * k; n += k
        }
        return Heard(lang: locale.identifier, text: String(text.characters).trimmingCharacters(in: .whitespaces),
                     confidence: n > 0 ? sum / n : 0)
    }
}

import Foundation
import TalkKit

// Posts every clip in a folder to a running yapa-talk (/talk?dry, so nothing is typed) and prints
// "<ms> <wer> <clip>" per clip: ms from the last byte sent (release) to the text back.
let args = CommandLine.arguments
let url = URL(string: "\(args[1])/talk?dry")!, dir = URL(fileURLWithPath: args[2])
let clips = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".wav") }.sorted()
for name in clips {
    let wav = try Data(contentsOf: dir.appendingPathComponent(name))
    let ref = try String(contentsOf: dir.appendingPathComponent(name.replacingOccurrences(of: ".wav", with: ".txt")), encoding: .utf8)
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    let start = Date()
    let (data, _) = try await URLSession.shared.upload(for: req, from: wav)
    let ms = Date().timeIntervalSince(start) * 1000
    let text = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"] as? String ?? ""
    print(String(format: "%.0f %.3f %@ %@", ms, wordErrorRate(reference: ref, hypothesis: text), name, text))
}

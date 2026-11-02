import FaceKit
import Foundation

// Prints µs of CPU per face frame, one sample per simulated 10 s at 60 fps, as a JSON array.
var samples: [Double] = []
let face = Face(seed: 1, now: 0)
var t = 0.0
var sink = 0.0
for batch in 0..<30 {
    if batch % 5 == 0 { face.set(Mood.allCases[batch / 5 % Mood.allCases.count], at: t) }
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<600 {
        t += 1.0 / 60
        sink += face.frame(at: t).eyes[0].width
    }
    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 600 / 1000)
}
print(samples.map { String(format: "%.3f", $0) }.joined(separator: ", "), sink > 0 ? "" : " ")

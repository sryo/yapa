// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mac",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "TalkKit"),
        .executableTarget(name: "yapa-talk", dependencies: ["TalkKit"]),
        .executableTarget(name: "pttbench", dependencies: ["TalkKit"]),
        .testTarget(name: "TalkKitTests", dependencies: ["TalkKit"]),
    ]
)

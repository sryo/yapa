// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "jeta",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [.library(name: "JetaKit", targets: ["JetaKit"]), .library(name: "BuddyKit", targets: ["BuddyKit"])],
    targets: [
        .target(name: "JetaKit"),
        .executableTarget(name: "facebench", dependencies: ["JetaKit"]),
        .executableTarget(name: "chordbench", dependencies: ["JetaKit"]),
        .executableTarget(name: "noticebench", dependencies: ["JetaKit"]),
        .executableTarget(name: "textbench", dependencies: ["JetaKit"]),
        .executableTarget(name: "crowdbench", dependencies: ["JetaKit"]),
        .testTarget(name: "JetaKitTests", dependencies: ["JetaKit"]),
        .target(name: "BuddyKit", dependencies: ["JetaKit"]),
        .target(name: "BuddySpec", dependencies: ["BuddyKit"]),
        .executableTarget(name: "padbench", dependencies: ["BuddySpec"]),
        .testTarget(name: "BuddyKitTests", dependencies: ["BuddySpec"]),
    ]
)

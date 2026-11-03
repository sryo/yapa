// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "jeta",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [.library(name: "JetaKit", targets: ["JetaKit"])],
    targets: [
        .target(name: "JetaKit"),
        .executableTarget(name: "facebench", dependencies: ["JetaKit"]),
        .executableTarget(name: "chordbench", dependencies: ["JetaKit"]),
        .testTarget(name: "JetaKitTests", dependencies: ["JetaKit"]),
    ]
)

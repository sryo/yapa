// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "pad",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [.library(name: "FaceKit", targets: ["FaceKit"])],
    targets: [
        .target(name: "FaceKit"),
        .executableTarget(name: "facebench", dependencies: ["FaceKit"]),
        .testTarget(name: "FaceKitTests", dependencies: ["FaceKit"]),
    ]
)

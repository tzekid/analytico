// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AnalyticoKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "AnalyticoKit", targets: ["AnalyticoKit"])],
    targets: [
        .target(name: "AnalyticoKit"),
        .testTarget(name: "AnalyticoKitTests", dependencies: ["AnalyticoKit"]),
    ]
)

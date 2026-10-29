// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PipePlot",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "PipePlotCore", targets: ["PipePlotCore"]),
        .library(name: "PipePlotTransport", targets: ["PipePlotTransport"]),
        .executable(name: "PipePlotApp", targets: ["PipePlotApp"]),
        .executable(name: "pp", targets: ["pp"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "PipePlotCore", dependencies: ["CSQLite"], path: "Sources/PipePlotCore"),
        .target(name: "PipePlotTransport", path: "Sources/PipePlotTransport"),
        .executableTarget(name: "PipePlotApp", dependencies: ["PipePlotCore", "PipePlotTransport"], path: "Sources/PipePlotApp"),
        .executableTarget(name: "pp", dependencies: ["PipePlotCore", "PipePlotTransport"], path: "Sources/pp"),
        .testTarget(name: "PipePlotCoreTests", dependencies: ["PipePlotCore"], path: "Tests/PipePlotCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)

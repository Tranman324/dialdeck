// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DialDeck",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DialDeckCore", targets: ["DialDeckCore"]),
        .executable(name: "DialDeckApp", targets: ["DialDeckApp"]),
    ],
    targets: [
        .target(name: "DialDeckUSB", publicHeadersPath: "include"),
        .target(name: "DialDeckCore", dependencies: ["DialDeckUSB"]),
        .executableTarget(name: "DialDeckApp", dependencies: ["DialDeckCore"]),
        .testTarget(name: "DialDeckCoreTests", dependencies: ["DialDeckCore"]),
    ]
)

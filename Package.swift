// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ImageAgent",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ImageAgentCore", targets: ["ImageAgentCore"]),
        .executable(name: "ImageAgent", targets: ["ImageAgent"]),
        .executable(name: "ImageAgentDiagnostics", targets: ["ImageAgentDiagnostics"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "ImageAgentCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "ImageAgent", dependencies: ["ImageAgentCore"]),
        .executableTarget(name: "ImageAgentDiagnostics", dependencies: ["ImageAgentCore"]),
        .testTarget(name: "ImageAgentCoreTests", dependencies: ["ImageAgentCore"]),
        .testTarget(name: "ImageAgentAppTests", dependencies: ["ImageAgent", "ImageAgentCore"])
    ],
    swiftLanguageVersions: [.v5]
)

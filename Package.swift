// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VibeView",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VibeView", targets: ["VibeViewApp"]),
        .executable(name: "vibeview-check", targets: ["MolChecks"]),
        .library(name: "MolCore", targets: ["MolCore"]),
        .library(name: "MolIO", targets: ["MolIO"]),
    ],
    targets: [
        .target(name: "MolCore"),
        .target(name: "MolIO", dependencies: ["MolCore"]),
        .target(name: "MolBuild", dependencies: ["MolCore"]),
        .target(name: "MolAnalysis", dependencies: ["MolCore", "MolIO"]),
        .target(name: "MolRender", dependencies: ["MolCore", "MolAnalysis"]),
        .target(name: "MolCompute", dependencies: ["MolCore", "MolIO", "MolBuild"]),
        .executableTarget(
            name: "VibeViewApp",
            dependencies: ["MolCore", "MolIO", "MolBuild", "MolAnalysis", "MolRender", "MolCompute"]
        ),
        // XCTest/Swift Testing are unavailable without full Xcode; checks run as an executable:
        //   swift run vibeview-check [filter]
        .executableTarget(
            name: "MolChecks",
            dependencies: ["MolCore", "MolIO", "MolBuild", "MolAnalysis", "MolRender", "MolCompute"],
            resources: [.copy("TestData")]
        ),
    ],
    swiftLanguageModes: [.v5]
)

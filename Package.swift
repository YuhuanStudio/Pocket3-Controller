// swift-tools-version: 6.2
import PackageDescription

let evaluationFrameworks = (Context.environment["DEVELOPER_DIR"] ?? "/Applications/Xcode-beta.app/Contents/Developer") + "/Platforms/MacOSX.platform/Developer/Library/Frameworks"

let package = Package(
    name: "Pocket3Bridge",
    defaultLocalization: "en",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "Pocket3MCP", targets: ["Pocket3BridgeApp"]),
        .executable(name: "pocket3", targets: ["pocket3"]),
        .library(name: "Pocket3Core", targets: ["Pocket3Core"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", revision: "e3d4a20e9e20e7b8ab39aded7bbfad4ae22c9438"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .target(name: "YunDesign"),
        .target(name: "CoreAIShared", swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]),
        .target(name: "CoreAIObjectDetector", dependencies: ["CoreAIShared"], swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]),
        .target(name: "Pocket3UVC", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fno-objc-arc"])], linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("Foundation")]),
        .target(name: "Pocket3Core", dependencies: ["Pocket3UVC"]),
        .target(name: "Pocket3Intelligence", dependencies: ["Pocket3Core", "CoreAIObjectDetector", .product(name: "MLXVLM", package: "mlx-swift-lm"), .product(name: "MLXLMCommon", package: "mlx-swift-lm"), .product(name: "MLXFoundationModels", package: "mlx-swift-lm"), .product(name: "MLXHuggingFace", package: "mlx-swift-lm"), .product(name: "HuggingFace", package: "swift-huggingface"), .product(name: "Tokenizers", package: "swift-transformers")]),
        .executableTarget(name: "Pocket3BridgeApp", dependencies: ["Pocket3Core", "Pocket3Intelligence", "YunDesign", .product(name: "Sparkle", package: "Sparkle")], resources: [.process("Resources")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "pocket3", dependencies: ["Pocket3Core", .product(name: "MCP", package: "swift-sdk")]),
        .testTarget(name: "Pocket3CoreTests", dependencies: ["Pocket3Core"]),
        .testTarget(name: "Pocket3EvaluationTests", dependencies: ["Pocket3Core", "Pocket3Intelligence"], swiftSettings: [.unsafeFlags(["-F", evaluationFrameworks])], linkerSettings: [.linkedFramework("Evaluations"), .unsafeFlags(["-F", evaluationFrameworks, "-Xlinker", "-rpath", "-Xlinker", evaluationFrameworks])]),
        .testTarget(name: "Pocket3IntelligenceTests", dependencies: ["Pocket3Intelligence", "Pocket3Core"]),
        .testTarget(name: "Pocket3AppTests", dependencies: ["Pocket3BridgeApp"], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])])
    ]
)

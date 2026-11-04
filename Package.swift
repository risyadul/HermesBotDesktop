// swift-tools-version: 6.0
import PackageDescription

// M0 spike + M1 (Bots + Bot Chat 1:1) + M2 (Group Chat): thin native client for `hermes serve` (JSON-RPC over /api/ws, groups.*).
// HermesGatewayKit holds everything reusable; the two executables are thin front ends.
let package = Package(
    name: "HermesBotApp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HermesGatewayKit", targets: ["HermesGatewayKit"]),
        .executable(name: "HermesBotApp", targets: ["HermesBotApp"]),
        .executable(name: "spike-harness", targets: ["SpikeHarness"]),
        .executable(name: "bot-chat-harness", targets: ["BotChatHarness"]),
        .executable(name: "group-chat-harness", targets: ["GroupChatHarness"]),
    ],
    targets: [
        .target(name: "HermesGatewayKit"),
        .executableTarget(name: "HermesBotApp", dependencies: ["HermesGatewayKit"]),
        .executableTarget(name: "SpikeHarness", dependencies: ["HermesGatewayKit"]),
        .executableTarget(name: "BotChatHarness", dependencies: ["HermesGatewayKit"]),
        .executableTarget(name: "GroupChatHarness", dependencies: ["HermesGatewayKit"]),
        .testTarget(name: "HermesGatewayKitTests", dependencies: ["HermesGatewayKit"]),
        // App-level regressions (connect retry, motion gate, rendered avatar contrast): @testable import of
        // the executable target, no gateway needed.
        .testTarget(name: "HermesBotAppTests", dependencies: ["HermesBotApp"]),
    ]
)

// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentMeong",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentMeongCore", targets: ["AgentMeongCore"]),
        .executable(name: "AgentMeong", targets: ["AgentMeongApp"]),
        .executable(
            name: "AgentMeongCodexForwarder",
            targets: ["AgentMeongCodexForwarder"]
        ),
        .executable(name: "AgentMeongCoreChecks", targets: ["AgentMeongCoreChecks"]),
    ],
    targets: [
        .target(name: "AgentMeongCore"),
        .executableTarget(
            name: "AgentMeongApp",
            dependencies: ["AgentMeongCore"]
        ),
        .executableTarget(
            name: "AgentMeongCoreChecks",
            dependencies: ["AgentMeongCore"]
        ),
        .executableTarget(name: "AgentMeongCodexForwarder"),
    ]
)

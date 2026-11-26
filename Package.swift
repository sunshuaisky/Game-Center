// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GameCenter",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GameCenter", targets: ["GameCenter"]),
        .executable(name: "GameCenterCoreHelper", targets: ["GameCenterCoreHelper"]),
        .executable(name: "S2ArmStandaloneLauncher", targets: ["S2ArmStandaloneLauncher"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CRetroHost",
            path: "Sources/CRetroHost",
            publicHeadersPath: "include",
            cSettings: [.define("GL_SILENCE_DEPRECATION")],
            linkerSettings: [.linkedFramework("OpenGL")]
        ),
        .target(
            name: "CoreHostIPC",
            dependencies: ["CRetroHost"],
            path: "Sources/CoreHostIPC",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "GameCenterCoreHelper",
            dependencies: ["CRetroHost", "CoreHostIPC"],
            path: "Sources/GameCenterCoreHelper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "GameCenterSaveSupport", path: "Sources/GameCenterSaveSupport"),
        .executableTarget(
            name: "GameCenter",
            dependencies: ["GameCenterSaveSupport", "CoreHostIPC"],
            path: "Sources/GameCenter",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "S2ArmStandaloneLauncher",
            dependencies: ["GameCenterSaveSupport"],
            path: "Sources/S2ArmStandaloneLauncher",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

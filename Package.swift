// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Charkle",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "CharkleCore",
            targets: ["CharkleCore"]
        ),
        .library(
            name: "CharkleCanvas",
            targets: ["CharkleCanvas"]
        ),
        .executable(
            name: "Charkle",
            targets: ["CharkleApp"]
        ),
        .executable(
            name: "charkle-cli",
            targets: ["CharkleCLI"]
        )
    ],
    targets: [
        .target(
            name: "CharkleCore",
            path: "Sources/CharkleCore",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "CharkleCanvas",
            dependencies: ["CharkleCore"],
            path: "Sources/CharkleCanvas",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances")
            ]
        ),
        .executableTarget(
            name: "CharkleApp",
            dependencies: ["CharkleCore", "CharkleCanvas"],
            path: "Sources/CharkleApp",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances")
            ]
        ),
        .executableTarget(
            name: "CharkleCLI",
            dependencies: ["CharkleCore"],
            path: "Sources/CharkleCLI",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances")
            ]
        ),
        .testTarget(
            name: "CharkleTests",
            dependencies: ["CharkleCore", "CharkleCanvas"],
            path: "Tests/CharkleTests",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances")
            ]
        )
    ]
)

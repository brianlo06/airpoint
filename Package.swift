// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirPoint",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        // Shared, platform-agnostic core. Consumed by airpointd today and by the
        // native iOS controller in Phase 6 — this is why the project is Swift.
        .library(name: "RemoteKit", targets: ["RemoteKit"]),
        // The transport, pairing and session machinery, with no idea what the events mean.
        // Published as a library so other projects can be built on it — the game in the
        // sibling repo consumes exactly this.
        .library(name: "RemoteServer", targets: ["RemoteServer"]),
        .executable(name: "airpointd", targets: ["airpointd"]),
    ],
    targets: [
        .target(
            name: "RemoteKit",
            path: "Sources/RemoteKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "RemoteServer",
            dependencies: ["RemoteKit"],
            path: "Sources/RemoteServer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "airpointd",
            dependencies: ["RemoteKit", "RemoteServer"],
            path: "Sources/airpointd",
            resources: [.copy("Resources/web")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RemoteKitTests",
            dependencies: ["RemoteKit"],
            path: "Tests/RemoteKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

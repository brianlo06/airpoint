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
        .library(name: "AirPointCore", targets: ["AirPointCore"]),
        .executable(name: "airpointd", targets: ["airpointd"]),
        // The menu-bar app: same daemon, with a UI instead of a terminal.
        .executable(name: "AirPointApp", targets: ["AirPointApp"]),
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
            // Controller primitives every host needs: the motion pipeline with its
            // gyroscope axis resolver, and the live-typing diff. Shipping them with the
            // library means a second project reuses the subtle code instead of copying it.
            resources: [.copy("Resources/shared")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The cursor remote itself: CGEvent, focus detection, and the controller assets.
        // A library so the CLI and the menu-bar app are the same program with two faces.
        .target(
            name: "AirPointCore",
            dependencies: ["RemoteKit", "RemoteServer"],
            path: "Sources/AirPointCore",
            resources: [.copy("Resources/web")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "airpointd",
            dependencies: ["RemoteKit", "RemoteServer", "AirPointCore"],
            path: "Sources/airpointd",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AirPointApp",
            dependencies: ["RemoteKit", "RemoteServer", "AirPointCore"],
            path: "Sources/AirPointApp",
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

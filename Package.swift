// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirPoint",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        // Shared, platform-agnostic core. Consumed by airpointd today and by the
        // native iOS controller in Phase 6 — this is why the project is Swift.
        .library(name: "RemoteKit", targets: ["RemoteKit"]),
        .executable(name: "airpointd", targets: ["airpointd"]),
    ],
    targets: [
        .target(
            name: "RemoteKit",
            path: "Sources/RemoteKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "airpointd",
            dependencies: ["RemoteKit"],
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

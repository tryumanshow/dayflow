// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DayflowApp",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DayflowApp",
            path: "Sources/DayflowApp",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "DayflowAppTests",
            dependencies: ["DayflowApp"],
            path: "Tests/DayflowAppTests",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)

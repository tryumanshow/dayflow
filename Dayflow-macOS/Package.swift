// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DayflowApp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DayflowApp",
            path: "Sources/DayflowApp",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)

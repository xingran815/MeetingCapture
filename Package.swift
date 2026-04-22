// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingCaptureCLI",
    platforms: [
        .macOS(.v13)   // macOS 13+ for stable SCStream audio capture
    ],
    targets: [
        .executableTarget(
            name: "MeetingCaptureCLI",
            path: "Sources/MeetingCaptureCLI",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        )
    ]
)

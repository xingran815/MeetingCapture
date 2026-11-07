// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingCaptureCLI",
    platforms: [
        .macOS(.v14)  // WhisperKit requires macOS 14+
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.4")
    ],
    targets: [
        .target(
            name: "MeetingCaptureCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SpeakerKit", package: "WhisperKit"),
            ],
            path: "Sources/MeetingCaptureCore"
        ),
        .executableTarget(
            name: "MeetingCaptureCLI",
            dependencies: ["MeetingCaptureCore"],
            path: "Sources/MeetingCaptureCLI"
        ),
        .testTarget(
            name: "MeetingCaptureCoreTests",
            dependencies: ["MeetingCaptureCore"],
            path: "Tests/MeetingCaptureCoreTests"
        ),
    ]
)

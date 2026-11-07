// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeetingCaptureCLI",
    platforms: [
        .macOS(.v26)  // D-92: macOS 26, the only version anything has run on
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
        // The desktop app (M5). SwiftUI over the same core; `scripts/build-app.sh` wraps
        // it in MeetingCapture.app with its Info.plist, so permissions belong to the app.
        .executableTarget(
            name: "MeetingCaptureDesktop",
            dependencies: ["MeetingCaptureCore"],
            path: "Sources/MeetingCaptureDesktop"
        ),
        .testTarget(
            name: "MeetingCaptureCoreTests",
            dependencies: ["MeetingCaptureCore"],
            path: "Tests/MeetingCaptureCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)

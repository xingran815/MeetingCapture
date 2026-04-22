// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingCaptureCLI",
    platforms: [
        .macOS(.v14)   // WhisperKit requires macOS 14+
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.4")
    ],
    targets: [
        .executableTarget(
            name: "MeetingCaptureCLI",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/MeetingCaptureCLI"
        )
    ]
)

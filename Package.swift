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
        .target(
            name: "Speexdsp",
            path: "Sources/Speexdsp",
            exclude: ["UPSTREAM.md", "LICENSE"],
            sources: [
                "mdf.c",
                "preprocess.c",
                "fftwrap.c",
                "kiss_fft.c",
                "kiss_fftr.c",
                "filterbank.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .define("FLOATING_POINT"),
                .define("USE_KISS_FFT"),
                .define("EXPORT", to: ""),
            ]
        ),
        .executableTarget(
            name: "MeetingCaptureCLI",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                "Speexdsp",
            ],
            path: "Sources/MeetingCaptureCLI"
        )
    ]
)

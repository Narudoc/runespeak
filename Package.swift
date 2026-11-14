// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Runespeak",
    defaultLocalization: "ko",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic, no AppKit: models, glossary, chat parsing, translation clients.
        .target(name: "RunespeakCore", path: "Sources/RunespeakCore"),
        // The menu-bar/overlay app: capture, OCR, windows, hotkeys.
        .executableTarget(
            name: "Runespeak",
            dependencies: ["RunespeakCore"],
            path: "Sources/Runespeak"
        ),
        .testTarget(name: "RunespeakCoreTests", dependencies: ["RunespeakCore"], path: "Tests/RunespeakCoreTests"),
    ]
)

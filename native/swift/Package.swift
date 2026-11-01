// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenWisper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenWisper", targets: ["OpenWisper"]),
        .library(name: "WisperCore", targets: ["WisperCore"]),
        .library(name: "WisperPlatform", targets: ["WisperPlatform"])
    ],
    targets: [
        .target(name: "CWisperAudio", publicHeadersPath: "include"),
        .target(name: "WisperCore"),
        .target(name: "WisperPlatform", dependencies: ["WisperCore", "CWisperAudio"]),
        .executableTarget(name: "OpenWisper", dependencies: ["WisperCore", "WisperPlatform"]),
        .testTarget(name: "WisperCoreTests", dependencies: ["WisperCore"]),
        .testTarget(name: "WisperPlatformTests", dependencies: ["WisperPlatform", "CWisperAudio"])
    ]
)

// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MeetTranscript",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MeetTranscript", targets: ["MeetTranscript"])
    ],
    targets: [
        .executableTarget(
            name: "MeetTranscript",
            path: "Sources"
        )
    ],
    swiftLanguageModes: [
        .v5
    ]
)

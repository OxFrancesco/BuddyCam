// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhoneRecorder",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "PhoneRecorder"),
        .testTarget(name: "PhoneRecorderTests", dependencies: ["PhoneRecorder"]),
    ],
    swiftLanguageModes: [.v5]
)

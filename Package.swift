// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FocusBlur",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FocusBlur",
            path: "Sources"
        )
    ]
)

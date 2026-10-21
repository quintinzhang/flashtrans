// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlashTrans",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FlashTrans",
            path: "Sources/FlashTrans",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)

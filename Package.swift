// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "meet",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "MeetKit",
            dependencies: [.product(name: "TOMLKit", package: "TOMLKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "meet",
            dependencies: [
                "MeetKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MeetKitTests",
            dependencies: ["MeetKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

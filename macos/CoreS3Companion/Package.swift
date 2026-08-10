// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CoreS3Companion",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CoreS3CompanionCore", targets: ["CoreS3CompanionCore"])
    ],
    targets: [
        .target(
            name: "CoreS3CompanionCore",
            path: ".",
            exclude: [
                "App",
                "Views",
                "Tests",
                "CoreS3Companion.xcodeproj",
                "Models/README.md",
                "Protocol/README.md",
                "Services/README.md",
                "Transport/README.md"
            ],
            sources: ["Models", "Protocol", "Services", "Transport"]
        ),
        .testTarget(
            name: "CoreS3CompanionTests",
            dependencies: ["CoreS3CompanionCore"],
            path: "Tests"
        )
    ],
    swiftLanguageModes: [.v5]
)


// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoDuplicateCleaner",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PhotoDuplicateCleaner", targets: ["PhotoDuplicateCleaner"])
    ],
    targets: [
        .executableTarget(
            name: "PhotoDuplicateCleaner",
            path: "Sources/PhotoDuplicateCleaner",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PhotoDuplicateCleanerTests",
            dependencies: ["PhotoDuplicateCleaner"],
            path: "Tests/PhotoDuplicateCleanerTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

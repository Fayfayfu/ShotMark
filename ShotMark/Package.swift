// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShotMark",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "ShotMark", targets: ["ShotMark"])
    ],
    targets: [
        .executableTarget(
            name: "ShotMark",
            path: "Sources/ShotMark",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "ShotMarkTests",
            dependencies: ["ShotMark"],
            path: "Tests/ShotMarkTests",
            swiftSettings: [
                .unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"]),
                .unsafeFlags(["-Xfrontend", "-disable-cross-import-overlays"])
            ],
            linkerSettings: [
                .unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"]),
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                ]),
                .linkedFramework("Testing")
            ]
        )
    ]
)

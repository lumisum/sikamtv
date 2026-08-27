// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MTVMusicVideo",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MTVMusicVideo", targets: ["MTVMusicVideo"])
    ],
    targets: [
        .executableTarget(
            name: "MTVMusicVideo",
            path: "Sources/MTVMusicVideo"
        ),
        .testTarget(
            name: "MTVMusicVideoTests",
            dependencies: ["MTVMusicVideo"],
            path: "Tests/MTVMusicVideoTests"
        )
    ]
)

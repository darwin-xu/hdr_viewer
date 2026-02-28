// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "hdr_viewer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "HDRViewer", targets: ["HDRViewer"])
    ],
    targets: [
        .executableTarget(
            name: "HDRViewer",
            path: "Sources/HDRViewer",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "HDRViewerTests",
            dependencies: ["HDRViewer"],
            path: "Tests/HDRViewerTests"
        )
    ]
)

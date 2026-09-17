// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WispSciencePreview",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WispSciencePreview", targets: ["WispSciencePreview"]),
        .library(name: "WispProjectBrowser", targets: ["WispProjectBrowser"]),
    ],
    targets: [
        .target(name: "WispProjectBrowser"),
        .executableTarget(name: "WispSciencePreview", dependencies: ["WispProjectBrowser"]),
        .testTarget(name: "WispProjectBrowserTests", dependencies: ["WispProjectBrowser"]),
    ]
)

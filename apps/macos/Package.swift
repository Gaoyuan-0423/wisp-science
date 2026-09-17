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
        .target(name: "WispProjectBrowserUI", dependencies: ["WispProjectBrowser"], resources: [.process("Resources")]),
        .executableTarget(name: "WispSciencePreview", dependencies: ["WispProjectBrowserUI"]),
        .testTarget(name: "WispProjectBrowserTests", dependencies: ["WispProjectBrowser"]),
        .testTarget(name: "WispProjectBrowserUITests", dependencies: ["WispProjectBrowserUI"]),
    ]
)

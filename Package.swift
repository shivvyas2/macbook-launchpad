// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Launchpad",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "MultitouchBridge"),
        .executableTarget(
            name: "Launchpad",
            dependencies: ["MultitouchBridge"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("ServiceManagement")]
        ),
    ]
)

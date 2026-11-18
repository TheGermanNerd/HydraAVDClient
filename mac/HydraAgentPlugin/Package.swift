// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HydraAgentPlugin",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "HydraAgentCore", targets: ["HydraAgentCore"])
    ],
    targets: [
        .target(
            name: "HydraAgentCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("CoreLocation"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "HydraAgentCoreTests",
            dependencies: ["HydraAgentCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

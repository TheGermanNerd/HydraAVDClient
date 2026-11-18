// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HydraRdp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "HydraRdp", targets: ["HydraRdp"])
    ],
    dependencies: [
        .package(path: "../HydraAgentPlugin")
    ],
    targets: [
        .target(
            name: "HydraChannelProtocol",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "HydraRdpCore",
            dependencies: [
                "HydraChannelProtocol",
                .product(name: "HydraAgentCore", package: "HydraAgentPlugin")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "HydraRdp",
            dependencies: ["HydraRdpCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AuthenticationServices"),
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "HydraRdpCoreTests",
            dependencies: ["HydraRdpCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

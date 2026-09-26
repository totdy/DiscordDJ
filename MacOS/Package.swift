// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DiscordDJMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DiscordDJMac", targets: ["DiscordDJMac"]),
    ],
    targets: [
        .executableTarget(
            name: "DiscordDJMac",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
    ]
)

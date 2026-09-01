// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NightOwl",
    platforms: [
        .macOS("14.0")
    ],
    targets: [
        .executableTarget(
            name: "NightOwl",
            path: "Sources/NightOwl",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("UserNotifications")
            ]
        )
    ]
)

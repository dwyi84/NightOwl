// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NightOwl",
    platforms: [
        .macOS("14.0")
    ],
    targets: [
        .target(
            name: "CGVirtualDisplayBridge",
            path: "Sources/CGVirtualDisplayBridge",
            linkerSettings: [
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "NightOwl",
            dependencies: ["CGVirtualDisplayBridge"],
            path: "Sources/NightOwl",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("UserNotifications")
            ]
        )
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Glasstop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Glasstop", targets: ["Glasstop"]),
    ],
    targets: [
        // Small C shim around the private IOHIDEventSystemClient API (temperatures).
        .target(
            name: "CSensors",
            path: "Sources/CSensors",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .executableTarget(
            name: "Glasstop",
            dependencies: ["CSensors"],
            path: "Sources/Glasstop"
        ),
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Benji",
    platforms: [.macOS(.v14)],   // ScreenCaptureKit one-shot screenshots need 14+
    targets: [
        // Pure logic — no AppKit — so it is unit-testable headlessly.
        .target(name: "BenjiCore"),
        // The AppKit/SwiftUI app and the backend transport.
        .executableTarget(
            name: "BenjiApp",
            dependencies: ["BenjiCore"]
        ),
        .testTarget(
            name: "BenjiCoreTests",
            dependencies: ["BenjiCore"]
        ),
        // The app's coordinator (CompanionModel) driven through a fake backend: no windows, no mic.
        .testTarget(
            name: "BenjiAppTests",
            dependencies: ["BenjiApp", "BenjiCore"]
        ),
    ]
)

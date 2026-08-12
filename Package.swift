// swift-tools-version: 6.0
import PackageDescription

/// The three kits are AppKit-free on purpose: they are the part `swift test` can exercise headless,
/// and the part a future `onair` CLI would reuse (ADR-0002).
let package = Package(
    name: "OnAir",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DeviceKit", targets: ["DeviceKit"]),
        .library(name: "StatusKit", targets: ["StatusKit"]),
        .library(name: "SlackKit", targets: ["SlackKit"]),
        .executable(name: "onair", targets: ["OnAir"]),
    ],
    targets: [
        // Answers one question — is a camera or a microphone running somewhere — and never opens
        // a stream to find out (ADR-0001, invariant A5).
        .target(name: "DeviceKit"),
        // The domain and the policy. Depends on nothing, so every rule worth changing is testable
        // without hardware or a network.
        .target(name: "StatusKit"),
        // Slack's Web API and the OAuth loopback that gets a token for it. Depends on StatusKit
        // for `UserStatus`, which is the domain type both sides speak.
        .target(name: "SlackKit", dependencies: ["StatusKit"]),
        // The kits stay in Swift 6 language mode; the app does not. Its surface is AppKit and
        // SwiftUI — `NSApplication.shared`, delegate callbacks, global menu state — which Swift 6
        // isolation rejects on sight. Holding the *libraries* to strict concurrency is what has
        // value, since they are the reusable and the testable part (ADR-0009).
        .executableTarget(
            name: "OnAir",
            dependencies: ["DeviceKit", "StatusKit", "SlackKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "DeviceKitTests", dependencies: ["DeviceKit"]),
        .testTarget(name: "StatusKitTests", dependencies: ["StatusKit"]),
        .testTarget(name: "SlackKitTests", dependencies: ["SlackKit", "StatusKit"]),
    ]
)

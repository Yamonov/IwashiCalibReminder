// swift-tools-version: 6.4.1
import PackageDescription

let strictSwift: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault")
]

let package = Package(
    name: "EIZODisplayHID",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EIZOHID", targets: ["EIZOHID"]),
        .library(name: "ReminderSupport", targets: ["ReminderSupport"]),
        .executable(name: "eizo-usage", targets: ["EIZOUsageCLI"])
    ],
    targets: [
        .target(name: "EIZOHID", swiftSettings: strictSwift,
                linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("IOKit")]),
        .executableTarget(name: "EIZOUsageCLI", dependencies: ["EIZOHID"], swiftSettings: strictSwift),
        .target(name: "ReminderSupport", dependencies: ["EIZOHID"],
                resources: [.process("Resources")], swiftSettings: strictSwift),
    ],
    swiftLanguageModes: [.v6]
)

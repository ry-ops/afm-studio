// swift-tools-version: 6.2
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]


let package = Package(
    name: "afm-studio",
    platforms: [.macOS("26.4")],
    products: [
        .executable(name: "afm", targets: ["afm"]),
        .executable(name: "AFMStudio", targets: ["AFMStudio"]),
        .library(name: "AFMKit", targets: ["AFMKit"]),
    ],
    dependencies: [
        // The in-app terminal. MIT, pinned to an exact release.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.0"),
    ],
    targets: [
        .target(name: "AFMKit", swiftSettings: v5),
        .target(name: "AFMServer", dependencies: ["AFMKit"], swiftSettings: v5),
        // Integrations: one module each, built on AFMKit, switched on per user.
        .target(name: "AFMGitHub", dependencies: ["AFMKit"], swiftSettings: v5),
        .executableTarget(name: "afm", dependencies: ["AFMKit", "AFMServer", "AFMGitHub"], swiftSettings: v5),
        .executableTarget(name: "AFMStudio", dependencies: ["AFMKit", "AFMServer", "AFMGitHub", .product(name: "SwiftTerm", package: "SwiftTerm")], swiftSettings: v5),
        .executableTarget(name: "afm-selftest", dependencies: ["AFMKit", "AFMServer", "AFMGitHub"], path: "Tests/SelfTest", swiftSettings: v5),
    ]
)

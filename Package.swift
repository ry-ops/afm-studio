// swift-tools-version: 6.2
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]


let package = Package(
    name: "afm-studio",
    // AFM Studio requires macOS 27.1. The macOS 27.0 SDK only accepts deployment targets up to 27.0.x,
    // so raise this to 27.1, along with LSMinimumSystemVersion in scripts/build-app.sh, once the 27.1 SDK is out.
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "afm", targets: ["afm"]),
        .executable(name: "AFMStudio", targets: ["AFMStudio"]),
        .library(name: "AFMKit", targets: ["AFMKit"]),
    ],
    dependencies: [
        // The in-app terminal. MIT, pinned to an exact release.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.1"),
    ],
    targets: [
        .target(name: "AFMKit", swiftSettings: v5),
        .target(name: "AFMServer", dependencies: ["AFMKit"], swiftSettings: v5),
        // Integrations: one module each, built on AFMKit, switched on per user.
        .target(name: "AFMGitHub", dependencies: ["AFMKit"], swiftSettings: v5),
        .target(name: "AFMJev", dependencies: ["AFMKit"], swiftSettings: v5),
        .executableTarget(name: "afm", dependencies: ["AFMKit", "AFMServer", "AFMGitHub", "AFMJev"], swiftSettings: v5),
        .executableTarget(name: "AFMStudio", dependencies: ["AFMKit", "AFMServer", "AFMGitHub", "AFMJev", .product(name: "SwiftTerm", package: "SwiftTerm")], swiftSettings: v5),
        .executableTarget(name: "afm-selftest", dependencies: ["AFMKit", "AFMServer", "AFMGitHub", "AFMJev"], path: "Tests/SelfTest", swiftSettings: v5),
    ]
)

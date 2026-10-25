import SwiftUI

/// SwiftUI's `@State` property wrapper under a name that can't be mistaken for a macro.
///
/// The macOS 27 SDK adds a `@State` macro next to the property wrapper, and the
/// compiler resolves `@State` to the macro. The macro's plugin ships with Xcode
/// but not with the Command Line Tools, so `swift build` fails there. Using the
/// wrapper through this alias builds with either toolchain and either SDK, and
/// behaves exactly as `@State` did on macOS 26.
typealias ViewState<Value> = SwiftUI.State<Value>

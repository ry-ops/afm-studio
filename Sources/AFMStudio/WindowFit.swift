import SwiftUI
import AppKit

extension View {
    /// Keeps the hosting window inside its screen's visible area, below the menu bar and above the Dock.
    func keepsWindowOnScreen() -> some View { background(WindowScreenFitter()) }
}

/// Clamps the window to the screen's visible frame when it first appears and whenever that frame
/// changes: a new display resolution, the Dock resizing or moving, or the window moving to another display.
/// A restored frame from a larger display would otherwise leave part of the window behind the Dock.
private struct WindowScreenFitter: NSViewRepresentable {
    func makeNSView(context: Context) -> FitterView { FitterView() }
    func updateNSView(_ view: FitterView, context: Context) {}

    final class FitterView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let nc = NotificationCenter.default
            observers.forEach(nc.removeObserver)
            observers = []
            guard let window else { return }
            let refit: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.fit() } }
            observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: refit))
            observers.append(nc.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main, using: refit))
            DispatchQueue.main.async { [weak self] in self?.fit() }
        }

        func fit() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
            var f = window.frame
            f.size.width = min(f.width, visible.width)
            f.size.height = min(f.height, visible.height)
            f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
            f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
            if f != window.frame { window.setFrame(f, display: true) }
        }
    }
}

import SwiftUI
import AppKit
import AFMKit

@main
struct AFMStudioApp: App {
    @State private var app = AppState()

    init() {
        // Lets the app behave normally even when launched as a bare executable (swift run).
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApp.activate() }
    }

    var body: some Scene {
        WindowGroup("AFM Studio", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { app.newChat() }.keyboardShortcut("n")
            }
            CommandMenu("Go") {
                Button("Recipes") { app.pane = .recipes }.keyboardShortcut("1")
                Button("Structured Output") { app.pane = .structured }.keyboardShortcut("2")
                Button("Batch") { app.pane = .batch }.keyboardShortcut("3")
                Button("Compare") { app.pane = .compare }.keyboardShortcut("4")
                Button("Tokens") { app.pane = .tokens }.keyboardShortcut("5")
                Button("Benchmark") { app.pane = .bench }.keyboardShortcut("6")
                Button("History") { app.pane = .history }.keyboardShortcut("7")
                Button("Model") { app.pane = .model }.keyboardShortcut("8")
                Button("Claude") { app.pane = .claude }.keyboardShortcut("0")
                Button("Integrations") { app.pane = .integrations }.keyboardShortcut("9")
            }
        }

        MenuBarExtra("AFM Studio", systemImage: "sparkles") {
            QuickAskView().environment(app)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(app)
        }
    }
}

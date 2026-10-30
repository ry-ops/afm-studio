import SwiftUI
import AppKit
import AFMKit
import AFMGitHub
import AFMJev

@main
struct AFMStudioApp: App {
    @ViewState private var app = AppState()

    init() {
        IntegrationRegistry.install([GitHubIntegration(), JevIntegration()])
        // Lets the app behave normally even when launched as a bare executable (swift run).
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApp.activate() }
    }

    var body: some Scene {
        WindowGroup("AFM Studio", id: "main") {
            RootView()
                .environment(app)
                // Small enough to fit a 1024 × 640 point display with the Dock showing.
                .frame(minWidth: 800, minHeight: 420)
                .keepsWindowOnScreen()
        }
        .defaultWindowPlacement { _, context in
            // Open at 1320 × 860 when there's room, otherwise fill most of the visible screen.
            let visible = context.defaultDisplay.visibleRect
            return WindowPlacement(.center, size: CGSize(width: min(1320, visible.width * 0.94), height: min(860, visible.height * 0.94)))
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { app.updates.checkNow() }.disabled(app.updates.checking)
            }
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
                Button("CLI & API") { app.pane = .integrations }.keyboardShortcut("9")
                Button("Integrations") { app.pane = .integrationsHub }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("GitHub") { app.pane = .github }.keyboardShortcut("g", modifiers: [.command, .shift])
            }
            CommandMenu("Terminal") {
                Button(app.terminal.visible ? "Hide Terminal" : "Show Terminal") { app.terminal.toggle() }
                    .keyboardShortcut("`", modifiers: .control)
                Button("New Terminal") { app.terminal.newTab() }
                    .keyboardShortcut("`", modifiers: [.control, .shift])
                Button("New Terminal in Folder…") { app.terminal.newTabInFolder() }
                Divider()
                Button("Explain Output") { app.terminal.explain() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(app.terminal.current == nil || !app.status.available)
                Button("Clear") { app.terminal.clear() }
                    .disabled(app.terminal.current == nil)
                Divider()
                Button("Larger Text") { app.terminal.changeFont(by: 1) }
                Button("Smaller Text") { app.terminal.changeFont(by: -1) }
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

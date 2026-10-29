import AppIntents

/// What you can say to Siri. Every phrase also works typed into Spotlight or Type to Siri.
/// Apple allows ten of these per app; the other actions are in the Shortcuts app under AFM Studio.
struct StudioShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .purple

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskIntent(), phrases: [
            "Ask \(.applicationName)",
            "Ask \(.applicationName) a question",
            "Start a private question in \(.applicationName)",
        ], shortTitle: "Ask", systemImageName: "sparkles")

        AppShortcut(intent: NewChatIntent(), phrases: [
            "New chat in \(.applicationName)",
            "Start a new \(.applicationName) chat",
            "Open a new chat in \(.applicationName)",
        ], shortTitle: "New Chat", systemImageName: "square.and.pencil")

        AppShortcut(intent: OpenChatIntent(), phrases: [
            "Open \(\.$chat) in \(.applicationName)",
            "Open a chat in \(.applicationName)",
            "Show my \(.applicationName) chats",
        ], shortTitle: "Open Chat", systemImageName: "bubble.left.and.text.bubble.right")

        AppShortcut(intent: ContinueChatIntent(), phrases: [
            "Reply in \(\.$chat) with \(.applicationName)",
            "Continue a chat in \(.applicationName)",
            "Reply in an \(.applicationName) chat",
        ], shortTitle: "Reply in Chat", systemImageName: "arrowshape.turn.up.left")

        AppShortcut(intent: OpenSectionIntent(), phrases: [
            "Open \(\.$section) in \(.applicationName)",
            "Show \(\.$section) in \(.applicationName)",
            "Go to \(\.$section) in \(.applicationName)",
        ], shortTitle: "Open Section", systemImageName: "sidebar.left")

        AppShortcut(intent: RunRecipeIntent(), phrases: [
            "Run \(\.$recipe) in \(.applicationName)",
            "Run a recipe in \(.applicationName)",
            "Use an \(.applicationName) recipe",
        ], shortTitle: "Run Recipe", systemImageName: "wand.and.stars")

        AppShortcut(intent: RecentActivityIntent(), phrases: [
            "What has \(.applicationName) done today",
            "Show \(.applicationName) activity",
            "\(.applicationName) insights",
        ], shortTitle: "Recent Activity", systemImageName: "clock.arrow.circlepath")

        AppShortcut(intent: SetIntegrationIntent(), phrases: [
            "Turn on \(\.$integration) in \(.applicationName)",
            "Toggle an \(.applicationName) integration",
            "Change \(.applicationName) integrations",
        ], shortTitle: "Integrations", systemImageName: "puzzlepiece.extension")

        AppShortcut(intent: ModelStatusIntent(), phrases: [
            "Is \(.applicationName) ready",
            "\(.applicationName) model status",
            "Check the \(.applicationName) model",
        ], shortTitle: "Model Status", systemImageName: "cpu")

        AppShortcut(intent: SetAPIServerIntent(), phrases: [
            "Start the \(.applicationName) server",
            "Toggle the \(.applicationName) API server",
            "Turn the \(.applicationName) API on",
        ], shortTitle: "API Server", systemImageName: "antenna.radiowaves.left.and.right")
    }
}

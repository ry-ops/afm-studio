import SwiftUI
import AppIntents
import AFMKit
import AFMServer
import AFMGitHub

enum Pane: Hashable {
    case chat(String)
    case recipes, structured, batch, compare, tokens, bench, history, model, claude, integrations, github, integrationsHub
}

@Observable @MainActor
final class AppState {
    /// The one instance, shared by the window, the menu bar and Siri's actions.
    static let shared = AppState()

    var status = ModelStatus.current()
    var sessions: [ChatSessionRecord] = []
    var pane: Pane? = .recipes
    var recipes: [Recipe] = []
    var settings = AFMSettings.load()
    var chatModels: [String: ChatViewModel] = [:]
    let server = ServerController()
    let claude = ClaudeState()
    let github = GitHubState()
    let terminal = TerminalStore()
    let updates = UpdateState()
    /// Captured from the main window so Siri can reopen it after it's been closed.
    var openWindow: OpenWindowAction?

    init() {
        reloadSessions()
        reloadRecipes()
        if let first = sessions.first { pane = .chat(first.id) }
        claude.refreshKey()
        let s = settings
        Task { await claude.sync(settings: s) }
        Task { await watch() }
        updates.startBackgroundChecks { [weak self] in self?.settings.checkForUpdates == true }
    }

    /// Picks up chats created by the CLI or the MCP server and model status changes.
    private func watch() async {
        while true {
            try? await Task.sleep(for: .seconds(4))
            let fresh = SessionStore.shared.list()
            if fresh.map({ "\($0.id)\($0.updated)" }) != sessions.map({ "\($0.id)\($0.updated)" }) {
                sessions = fresh
                for s in fresh where chatModels[s.id]?.busy == false { chatModels[s.id]?.reloadIfChanged(s) }
            }
            let st = ModelStatus.current()
            if st != status { status = st }
        }
    }

    func reloadSessions() {
        let before = sessions.map(\.id)
        sessions = SessionStore.shared.list()
        // Lets Siri recognize chat titles in phrases like "Open <chat> in AFM Studio".
        if sessions.map(\.id) != before { StudioShortcuts.updateAppShortcutParameters() }
    }
    func reloadRecipes() { recipes = RecipeBook.shared.all() }

    func newChat() { createChat(source: "studio", select: true) }

    /// Makes a chat with the default settings. Siri's questions use `select: false`, so they don't move the window.
    @discardableResult
    func createChat(source: String, select: Bool) -> String {
        let r = ChatSessionRecord(instructions: settings.defaultInstructions, config: settings.defaultConfig,
                                  options: settings.defaultOptions, tools: settings.defaultTools, source: source,
                                  integrations: ChatSessionRecord.defaultIntegrations)
        SessionStore.shared.save(r)
        reloadSessions()
        if select { pane = .chat(r.id) }
        return r.id
    }

    /// Brings AFM Studio forward, reopening the main window if it was closed.
    func showMainWindow() {
        NSApp.activate()
        let visible = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        if !visible { openWindow?(id: "main") }
    }

    func setIntegration(_ id: String, enabled: Bool) {
        var p = settings.integrationPrefs[id] ?? IntegrationPrefs()
        p.enabled = enabled
        settings.integrationPrefs[id] = p
        saveSettings()
        if !enabled, pane == .github, id == "github" { pane = .integrationsHub }
        Task { await github.refreshStatus() }
    }

    func chatModel(_ id: String) -> ChatViewModel {
        if let m = chatModels[id] { return m }
        let rec = SessionStore.shared.load(id) ?? ChatSessionRecord(id: id, integrations: ChatSessionRecord.defaultIntegrations)
        let m = ChatViewModel(engine: ChatEngine(record: rec), app: self)
        chatModels[id] = m
        return m
    }

    func deleteChat(_ id: String) {
        chatModels[id]?.stop()
        chatModels[id] = nil
        SessionStore.shared.delete(id)
        reloadSessions()
        if pane == .chat(id) { pane = sessions.first.map { .chat($0.id) } ?? .recipes }
    }

    func saveSettings() { settings.save() }
}

@Observable @MainActor
final class ServerController {
    var running = false
    var error: String?
    var log: [String] = []
    private var server: OpenAIServer?

    func start(port: Int, token: String?) {
        stop()
        let s = OpenAIServer(port: UInt16(clamping: port), token: token)
        s.onLog = { line in Task { @MainActor in self.append(line) } }
        s.onState = { ok, err in Task { @MainActor in self.running = ok; self.error = err } }
        do { try s.start(); server = s } catch { self.error = AFMError.from(error).message }
    }

    func stop() {
        server?.stop()
        server = nil
        running = false
    }

    private func append(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date()))  \(line)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

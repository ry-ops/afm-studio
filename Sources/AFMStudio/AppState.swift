import SwiftUI
import AFMKit
import AFMServer

enum Pane: Hashable {
    case chat(String)
    case recipes, structured, batch, compare, tokens, bench, history, model, integrations
}

@Observable @MainActor
final class AppState {
    var status = ModelStatus.current()
    var sessions: [ChatSessionRecord] = []
    var pane: Pane? = .recipes
    var recipes: [Recipe] = []
    var settings = AFMSettings.load()
    var chatModels: [String: ChatViewModel] = [:]
    let server = ServerController()

    init() {
        reloadSessions()
        reloadRecipes()
        if let first = sessions.first { pane = .chat(first.id) }
        Task { await watch() }
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

    func reloadSessions() { sessions = SessionStore.shared.list() }
    func reloadRecipes() { recipes = RecipeBook.shared.all() }

    func newChat() {
        let r = ChatSessionRecord(instructions: settings.defaultInstructions, config: settings.defaultConfig,
                                  options: settings.defaultOptions, tools: settings.defaultTools, source: "studio")
        SessionStore.shared.save(r)
        reloadSessions()
        pane = .chat(r.id)
    }

    func chatModel(_ id: String) -> ChatViewModel {
        if let m = chatModels[id] { return m }
        let rec = SessionStore.shared.load(id) ?? ChatSessionRecord(id: id)
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

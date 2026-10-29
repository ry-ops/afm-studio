import AppIntents
import AFMKit

// Actions Siri and Shortcuts can run. The ones that answer a question (ask, reply, run a recipe,
// status checks) work without bringing AFM Studio forward. The ones that show something open the app.

/// Why an action couldn't run, phrased for Siri to read aloud.
struct StudioIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }

    static func from(_ error: Error) -> StudioIntentError {
        if let e = error as? StudioIntentError { return e }
        return StudioIntentError(message: AFMError.from(error).message)
    }
}

@MainActor private func requireModel() throws {
    let s = ModelStatus.current()
    guard s.available else {
        throw StudioIntentError(message: s.guidance ?? "Apple's on-device model isn't available right now.")
    }
}

// MARK: - Chats

struct AskIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask AFM Studio"
    static let description = IntentDescription("Asks Apple's on-device model a question in a new chat and returns the answer. The chat is saved with your others.", categoryName: "Chats")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask?")
    var question: String

    static var parameterSummary: some ParameterSummary { Summary("Ask AFM Studio \(\.$question)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try requireModel()
        let app = AppState.shared
        let id = app.createChat(source: "siri", select: false)
        do {
            let reply = try await app.chatModel(id).reply(to: question)
            return .result(value: reply.text, dialog: "\(reply.text)")
        } catch { throw StudioIntentError.from(error) }
    }
}

struct NewChatIntent: AppIntent {
    static let title: LocalizedStringResource = "New Chat"
    static let description = IntentDescription("Opens a new chat in AFM Studio, optionally starting it with a message.", categoryName: "Chats")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "First Message")
    var message: String?

    static var parameterSummary: some ParameterSummary { Summary("New chat starting with \(\.$message)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ChatEntity> {
        let app = AppState.shared
        let id = app.createChat(source: "studio", select: true)
        app.showMainWindow()
        if let m = message?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
            app.chatModel(id).send(m)
        }
        let rec = SessionStore.shared.load(id) ?? ChatSessionRecord(id: id)
        return .result(value: ChatEntity(rec))
    }
}

struct OpenChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Chat"
    static let description = IntentDescription("Opens one of your previous chats in AFM Studio.", categoryName: "Chats")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Chat", requestValueDialog: "Which chat?")
    var chat: ChatEntity

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$chat)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = AppState.shared
        guard SessionStore.shared.load(chat.id) != nil else { throw StudioIntentError(message: "That chat no longer exists.") }
        app.reloadSessions()
        app.pane = .chat(chat.id)
        app.showMainWindow()
        return .result()
    }
}

struct ContinueChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Reply in Chat"
    static let description = IntentDescription("Sends a message in one of your previous chats and returns the model's reply. The chat keeps its history, settings and tools.", categoryName: "Chats")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Chat", requestValueDialog: "Which chat?")
    var chat: ChatEntity

    @Parameter(title: "Message", requestValueDialog: "What do you want to say?")
    var message: String

    static var parameterSummary: some ParameterSummary { Summary("Say \(\.$message) in \(\.$chat)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try requireModel()
        guard SessionStore.shared.load(chat.id) != nil else { throw StudioIntentError(message: "That chat no longer exists.") }
        do {
            let reply = try await AppState.shared.chatModel(chat.id).reply(to: message)
            return .result(value: reply.text, dialog: "\(reply.text)")
        } catch { throw StudioIntentError.from(error) }
    }
}

struct LastReplyIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Last Reply"
    static let description = IntentDescription("Reads the model's most recent answer in a chat.", categoryName: "Chats")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Chat", requestValueDialog: "Which chat?")
    var chat: ChatEntity

    static var parameterSummary: some ParameterSummary { Summary("Get the last reply in \(\.$chat)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let rec = SessionStore.shared.load(chat.id) else { throw StudioIntentError(message: "That chat no longer exists.") }
        guard let last = rec.messages.last(where: { $0.role == .assistant }) else {
            return .result(value: "", dialog: "\(ChatEntity(rec).title) has no replies yet.")
        }
        return .result(value: last.text, dialog: "\(last.text)")
    }
}

struct DeleteChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete Chat"
    static let description = IntentDescription("Deletes a chat from AFM Studio. Asks first.", categoryName: "Chats")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Chat", requestValueDialog: "Which chat?")
    var chat: ChatEntity

    static var parameterSummary: some ParameterSummary { Summary("Delete \(\.$chat)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await requestConfirmation(dialog: "Delete the chat \(chat.title)? This can't be undone.")
        AppState.shared.deleteChat(chat.id)
        return .result(dialog: "Deleted \(chat.title).")
    }
}

// MARK: - Workbench, Insights, Integrations, System: navigation

struct OpenSectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Section"
    static let description = IntentDescription("Opens a part of AFM Studio: a Workbench tool, Insights, Integrations, or System settings.", categoryName: "Navigation")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Section", requestValueDialog: "Which section?")
    var section: StudioSection

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$section)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = AppState.shared
        if section == .github, !IntegrationRegistry.isEnabled("github") {
            app.pane = .integrationsHub
        } else {
            app.pane = section.pane
        }
        app.showMainWindow()
        return .result()
    }
}

// MARK: - Workbench

struct RunRecipeIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Recipe"
    static let description = IntentDescription("Runs a Workbench recipe, such as Summarize or Proofread, on text and returns the result. Long text is read in parts.", categoryName: "Workbench")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Recipe", requestValueDialog: "Which recipe?")
    var recipe: RecipeEntity

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true), requestValueDialog: "What text should it work on?")
    var text: String

    static var parameterSummary: some ParameterSummary { Summary("Run \(\.$recipe) on \(\.$text)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try requireModel()
        guard let r = RecipeBook.shared.find(recipe.id) else { throw StudioIntentError(message: "The recipe \(recipe.title) no longer exists.") }
        let s = AppState.shared.settings
        do {
            let res = try await RecipeRunner.run(r, input: text, options: s.defaultOptions, config: s.defaultConfig)
            History.append(HistoryEntry(source: "siri", kind: "recipe", title: r.title, input: text, output: res.text, seconds: res.seconds, outputTokens: res.outputTokens))
            return .result(value: res.text, dialog: "\(res.text)")
        } catch { throw StudioIntentError.from(error) }
    }
}

struct CountTokensIntent: AppIntent {
    static let title: LocalizedStringResource = "Count Tokens"
    static let description = IntentDescription("Counts how many of the on-device model's 4,096 context tokens a piece of text uses.", categoryName: "Workbench")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true), requestValueDialog: "What text should I count?")
    var text: String

    static var parameterSummary: some ParameterSummary { Summary("Count tokens in \(\.$text)") }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let n = await AFM.tokenCount(text)
        return .result(value: n, dialog: "That's \(n) tokens.")
    }
}

// MARK: - Insights

struct RecentActivityIntent: AppIntent {
    static let title: LocalizedStringResource = "Recent Activity"
    static let description = IntentDescription("Says what AFM Studio has done today, from your local history.", categoryName: "Insights")
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        guard History.enabled else { return .result(value: [], dialog: "History is turned off in AFM Studio's settings.") }
        let today = History.load(limit: 500).filter { Calendar.current.isDateInToday($0.date) }
        guard !today.isEmpty else { return .result(value: [], dialog: "Nothing has run today.") }
        let failed = today.filter { !$0.ok }.count
        let kinds = Dictionary(grouping: today, by: \.kind).sorted { $0.value.count > $1.value.count }
            .prefix(3).map { "\($0.value.count) \($0.key)" }.joined(separator: ", ")
        let n = today.count
        var line = "\(n) run\(n == 1 ? "" : "s") today: \(kinds)."
        if failed > 0 { line += " \(failed) failed." }
        return .result(value: today.map(\.title), dialog: "\(line)")
    }
}

struct RunBenchmarkIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Benchmark"
    static let description = IntentDescription("Times the on-device model on five short tasks and reports its decode speed in tokens per second.", categoryName: "Insights")
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        try await requireModel()
        do {
            let runs = try await Bench.run(rounds: 1)
            let speed = Bench.decodeSpeed(runs) ?? 0
            let ttft = runs.map(\.firstToken).sorted()[runs.count / 2]
            return .result(value: speed, dialog: "\(Bench.format(speed)) tokens per second, with the first token in \(String(format: "%.2f", ttft)) seconds.")
        } catch { throw StudioIntentError.from(error) }
    }
}

// MARK: - Integrations

struct SetIntegrationIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Integration On or Off"
    static let description = IntentDescription("Turns an integration, such as GitHub, on or off. Off means no credentials are read and none of its tools exist.", categoryName: "Integrations")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Integration", requestValueDialog: "Which integration?")
    var integration: IntegrationEntity

    @Parameter(title: "On", default: true, displayName: Bool.IntentDisplayName(true: "on", false: "off"))
    var on: Bool

    static var parameterSummary: some ParameterSummary { Summary("Turn \(\.$integration) \(\.$on)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = AppState.shared
        app.setIntegration(integration.id, enabled: on)
        return .result(dialog: "\(integration.name) is \(on ? "on" : "off"). Restart Claude Code or Claude Desktop to refresh their tool list.")
    }
}

struct IntegrationStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Integration Status"
    static let description = IntentDescription("Says whether an integration is on and connected.", categoryName: "Integrations")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Integration", requestValueDialog: "Which integration?")
    var integration: IntegrationEntity

    static var parameterSummary: some ParameterSummary { Summary("Get the status of \(\.$integration)") }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        guard let i = IntegrationRegistry.find(integration.id) else { throw StudioIntentError(message: "That integration isn't installed.") }
        guard IntegrationRegistry.isEnabled(i.id) else { return .result(value: false, dialog: "\(i.name) is turned off.") }
        let s = await i.status()
        return .result(value: s.connected, dialog: "\(i.name) is on. \(s.detail)")
    }
}

// MARK: - System

struct ModelStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Model Status"
    static let description = IntentDescription("Says whether Apple's on-device model is ready, and its context size.", categoryName: "System")
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let s = ModelStatus.current()
        if s.available {
            return .result(value: true, dialog: "The on-device model is ready, with a \(s.contextSize)-token context.")
        }
        return .result(value: false, dialog: "\(s.guidance ?? "The on-device model isn't available right now.")")
    }
}

struct SetAPIServerIntent: AppIntent {
    static let title: LocalizedStringResource = "Start or Stop the API Server"
    static let description = IntentDescription("Starts or stops AFM Studio's OpenAI-compatible server on this Mac.", categoryName: "System")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Running", default: true, displayName: Bool.IntentDisplayName(true: "on", false: "off"))
    var on: Bool

    static var parameterSummary: some ParameterSummary { Summary("Turn the API server \(\.$on)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = AppState.shared
        let port = app.settings.serverPort
        guard on else {
            app.server.stop()
            return .result(dialog: "The API server is stopped.")
        }
        app.server.start(port: port, token: nil)
        // The listener reports its state asynchronously.
        for _ in 0..<20 where !app.server.running && app.server.error == nil { try? await Task.sleep(for: .milliseconds(100)) }
        if let e = app.server.error { throw StudioIntentError(message: e) }
        return .result(dialog: "The API server is running on port \(port).")
    }
}

struct CheckForUpdatesIntent: AppIntent {
    static let title: LocalizedStringResource = "Check for Updates"
    static let description = IntentDescription("Checks GitHub for a newer release of AFM Studio.", categoryName: "System")
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        do {
            switch try await Updates.check() {
            case .available(let r): return .result(value: true, dialog: "AFM Studio \(r.tag) is available. Open AFM Studio to install it.")
            case .upToDate(let v): return .result(value: false, dialog: "AFM Studio \(AFMVersion.string) is up to date. The latest release is \(v).")
            case .noReleases: return .result(value: false, dialog: "No releases are published yet.")
            }
        } catch { throw StudioIntentError.from(error) }
    }
}

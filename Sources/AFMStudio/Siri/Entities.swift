import AppIntents
import AFMKit

// What Siri, Shortcuts and Spotlight can point at in AFM Studio: chats, recipes,
// integrations, and the app's sections. Everything is read from the same local files the app uses.

/// A saved chat, from any surface: Studio, the CLI, Claude over MCP, or Siri.
struct ChatEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: "Chat", numericFormat: "\(placeholder: .int) chats")
    static let defaultQuery = ChatQuery()

    var id: String
    @Property(title: "Title") var title: String
    @Property(title: "Messages") var messageCount: Int
    @Property(title: "Updated") var updated: Date
    @Property(title: "Last Reply") var lastReply: String

    init(_ r: ChatSessionRecord) {
        id = r.id
        title = r.title.isEmpty ? "Untitled" : r.title
        messageCount = r.messages.filter { $0.role != .notice }.count
        updated = r.updated
        lastReply = r.messages.last { $0.role == .assistant }?.text ?? ""
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)",
                              subtitle: "\(messageCount) message\(messageCount == 1 ? "" : "s")",
                              image: .init(systemName: "bubble.left.and.text.bubble.right"))
    }
}

struct ChatQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ChatEntity] {
        identifiers.compactMap { SessionStore.shared.load($0) }.map(ChatEntity.init)
    }

    /// Matches the title first, then anything said in the chat.
    func entities(matching string: String) async throws -> [ChatEntity] {
        SessionStore.shared.search(string).map(ChatEntity.init)
    }

    /// The most recent chats, newest first.
    func suggestedEntities() async throws -> [ChatEntity] {
        SessionStore.shared.list().prefix(20).map(ChatEntity.init)
    }
}

/// A built-in or custom recipe from the Workbench.
struct RecipeEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Recipe"
    static let defaultQuery = RecipeQuery()

    var id: String
    @Property(title: "Title") var title: String
    @Property(title: "Category") var category: String
    var summary: String
    var symbol: String

    init(_ r: Recipe) {
        id = r.id; summary = r.summary; symbol = r.symbol
        title = r.title; category = r.category
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(summary)", image: .init(systemName: symbol))
    }
}

struct RecipeQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [RecipeEntity] {
        identifiers.compactMap { RecipeBook.shared.find($0) }.map(RecipeEntity.init)
    }

    func entities(matching string: String) async throws -> [RecipeEntity] {
        RecipeBook.shared.all()
            .filter { $0.title.localizedCaseInsensitiveContains(string) || $0.id.localizedCaseInsensitiveContains(string) || $0.category.localizedCaseInsensitiveContains(string) }
            .map(RecipeEntity.init)
    }

    func suggestedEntities() async throws -> [RecipeEntity] {
        RecipeBook.shared.all().map(RecipeEntity.init)
    }
}

/// An integration AFM Studio ships, such as GitHub.
struct IntegrationEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Integration"
    static let defaultQuery = IntegrationQuery()

    var id: String
    @Property(title: "Name") var name: String
    @Property(title: "Turned On") var enabled: Bool
    var symbol: String

    init(_ i: any AFMIntegration) {
        id = i.id; symbol = i.symbol
        name = i.name
        enabled = IntegrationRegistry.isEnabled(i.id)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: enabled ? "On" : "Off", image: .init(systemName: symbol))
    }
}

struct IntegrationQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [IntegrationEntity] {
        identifiers.compactMap { IntegrationRegistry.find($0) }.map(IntegrationEntity.init)
    }

    func entities(matching string: String) async throws -> [IntegrationEntity] {
        IntegrationRegistry.all.filter { $0.name.localizedCaseInsensitiveContains(string) || $0.id.localizedCaseInsensitiveContains(string) }
            .map(IntegrationEntity.init)
    }

    func suggestedEntities() async throws -> [IntegrationEntity] {
        IntegrationRegistry.all.map(IntegrationEntity.init)
    }
}

/// Every place in the sidebar, grouped the same way: Workbench, Insights, Integrations, System.
enum StudioSection: String, AppEnum {
    case recipes, structured, batch, compare, tokens
    case benchmark, history
    case integrations, github
    case model, claude, cliAndAPI

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Section"
    static let caseDisplayRepresentations: [StudioSection: DisplayRepresentation] = [
        .recipes: DisplayRepresentation(title: "Recipes", subtitle: "Workbench", image: .init(systemName: "wand.and.stars")),
        .structured: DisplayRepresentation(title: "Structured Output", subtitle: "Workbench", image: .init(systemName: "curlybraces.square")),
        .batch: DisplayRepresentation(title: "Batch", subtitle: "Workbench", image: .init(systemName: "square.stack.3d.up")),
        .compare: DisplayRepresentation(title: "Compare", subtitle: "Workbench", image: .init(systemName: "rectangle.split.3x1")),
        .tokens: DisplayRepresentation(title: "Tokens", subtitle: "Workbench", image: .init(systemName: "number.square")),
        .benchmark: DisplayRepresentation(title: "Benchmark", subtitle: "Insights", image: .init(systemName: "speedometer")),
        .history: DisplayRepresentation(title: "History", subtitle: "Insights", image: .init(systemName: "clock.arrow.circlepath")),
        .integrations: DisplayRepresentation(title: "Integrations", subtitle: "Integrations", image: .init(systemName: "puzzlepiece.extension")),
        .github: DisplayRepresentation(title: "GitHub", subtitle: "Integrations", image: .init(systemName: "chevron.left.forwardslash.chevron.right")),
        .model: DisplayRepresentation(title: "Model", subtitle: "System", image: .init(systemName: "cpu")),
        .claude: DisplayRepresentation(title: "Claude", subtitle: "System", image: .init(systemName: "brain")),
        .cliAndAPI: DisplayRepresentation(title: "CLI and API", subtitle: "System", image: .init(systemName: "terminal")),
    ]

    var pane: Pane {
        switch self {
        case .recipes: .recipes
        case .structured: .structured
        case .batch: .batch
        case .compare: .compare
        case .tokens: .tokens
        case .benchmark: .bench
        case .history: .history
        case .integrations: .integrationsHub
        case .github: .github
        case .model: .model
        case .claude: .claude
        case .cliAndAPI: .integrations
        }
    }
}

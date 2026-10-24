import Foundation
import FoundationModels

/// Output of an integration tool, shared by MCP and the CLI.
public struct IntegrationOutput: @unchecked Sendable {
    public var text: String
    public var json: [String: Any]?
    public init(text: String, json: [String: Any]? = nil) { self.text = text; self.json = json }
}

/// A tool an integration exposes to Claude over MCP.
public struct IntegrationTool: @unchecked Sendable {
    public let name: String
    public let title: String
    public let description: String
    public let properties: [String: Any]
    public let required: [String]
    public let run: @Sendable ([String: Any]) async throws -> IntegrationOutput

    public init(name: String, title: String, description: String, properties: [String: Any] = [:], required: [String] = [],
                run: @escaping @Sendable ([String: Any]) async throws -> IntegrationOutput) {
        self.name = name; self.title = title; self.description = description
        self.properties = properties; self.required = required; self.run = run
    }

    public var mcpDefinition: [String: Any] {
        [
            "name": name, "title": title, "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
            "annotations": ["title": title, "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true],
        ]
    }
}

public struct IntegrationStatus: Sendable, Equatable {
    public var connected: Bool
    public var detail: String
    public init(connected: Bool, detail: String) { self.connected = connected; self.detail = detail }
}

/// What an integration can do, shown to the user before they turn it on.
public struct IntegrationManifest: Sendable {
    public enum Writes: String, Sendable {
        /// Never changes anything in the outside service.
        case none
        /// Produces drafts and pre-filled links; the user submits them.
        case draftsOnly = "drafts only"
        /// May write, but each write is confirmed by the user.
        case confirmEach = "confirm each write"
    }
    public var credentials: [String]
    public var hosts: [String]
    public var writes: Writes
    public var dataNote: String

    public init(credentials: [String], hosts: [String], writes: Writes, dataNote: String) {
        self.credentials = credentials; self.hosts = hosts; self.writes = writes; self.dataNote = dataNote
    }
}

/// The user's switches for one integration. Everything starts off.
public struct IntegrationPrefs: Codable, Sendable, Equatable {
    /// Master switch. Off: no credentials are read and no tools exist anywhere.
    public var enabled: Bool = false
    /// The on-device model may call its tools (each chat still opts in).
    public var chat: Bool = true
    /// Its tools are listed in the MCP server for Claude.
    public var claude: Bool = true
    public init(enabled: Bool = false, chat: Bool = true, claude: Bool = true) { self.enabled = enabled; self.chat = chat; self.claude = claude }
}

/// A plug-in that connects AFM Studio to an outside service. Each lives in its own module
/// (AFMGitHub, …) and is installed into the registry by the app and the CLI.
public protocol AFMIntegration: Sendable {
    var id: String { get }
    var name: String { get }
    var symbol: String { get }
    var summary: String { get }
    var manifest: IntegrationManifest { get }
    func status() async -> IntegrationStatus
    var mcpTools: [IntegrationTool] { get }
    func modelTools(tracker: ToolCallTracker?) -> [any Tool]
}

public enum IntegrationRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: [any AFMIntegration] = []

    /// Called once at startup by each executable with the integrations it ships.
    public static func install(_ list: [any AFMIntegration]) {
        lock.lock(); installed = list; lock.unlock()
    }

    public static var all: [any AFMIntegration] { lock.lock(); defer { lock.unlock() }; return installed }
    public static func find(_ id: String) -> (any AFMIntegration)? { all.first { $0.id == id } }

    public static func prefs(_ id: String, _ settings: AFMSettings = .load()) -> IntegrationPrefs { settings.integrationPrefs[id] ?? IntegrationPrefs() }
    public static func isEnabled(_ id: String) -> Bool { prefs(id).enabled }

    /// Integrations whose tools the on-device model may use.
    public static var chatEnabled: [any AFMIntegration] {
        let s = AFMSettings.load()
        return all.filter { let p = prefs($0.id, s); return p.enabled && p.chat }
    }

    /// Tools Claude sees over MCP: only from integrations that are on and shared with Claude.
    public static var mcpTools: [IntegrationTool] {
        let s = AFMSettings.load()
        return all.filter { let p = prefs($0.id, s); return p.enabled && p.claude }.flatMap(\.mcpTools)
    }
    public static func mcpTool(named name: String) -> IntegrationTool? { mcpTools.first { $0.name == name } }
    /// True if `name` belongs to an installed integration, whether or not it's on.
    public static func isIntegrationTool(_ name: String) -> Bool { all.contains { $0.mcpTools.contains { $0.name == name } } }

    /// Throws unless the integration is switched on. Used by the CLI and workflows.
    public static func requireEnabled(_ id: String) throws {
        guard isEnabled(id) else {
            let name = find(id)?.name ?? id
            throw AFMError(code: "integration_off", message: "The \(name) integration is turned off.",
                           suggestion: "Turn it on in AFM Studio > Integrations, or run `afm integrations enable \(id)`.")
        }
    }

    public static func setPrefs(_ id: String, _ change: (inout IntegrationPrefs) -> Void) {
        var s = AFMSettings.load()
        var p = s.integrationPrefs[id] ?? IntegrationPrefs()
        change(&p)
        s.integrationPrefs[id] = p
        s.save()
    }
}

/// Per-integration data (repos, profiles…), each in its own file. Never credentials.
public enum IntegrationStore {
    public static func url(_ id: String) -> URL { AFMPaths.dir("integrations").appendingPathComponent("\(id).json") }
    public static func load<T: Decodable>(_ id: String, as: T.Type) -> T? {
        guard let d = try? Data(contentsOf: url(id)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
    public static func save<T: Encodable>(_ id: String, _ value: T) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? enc.encode(value).write(to: url(id), options: .atomic)
    }
}

extension Dictionary where Key == String, Value == Any {
    public func s(_ k: String) -> String? {
        if let v = self[k] as? String, !v.isEmpty { return v }
        if let n = self[k] as? NSNumber { return n.stringValue }
        return nil
    }
    public func i(_ k: String) -> Int? { (self[k] as? NSNumber)?.intValue ?? (self[k] as? String).flatMap(Int.init) }
}

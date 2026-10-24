import Foundation

public struct HistoryEntry: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var date: Date
    public var source: String
    public var kind: String
    public var title: String
    public var input: String
    public var output: String
    public var seconds: Double
    public var outputTokens: Int?
    public var ok: Bool

    public init(id: UUID = UUID(), date: Date = Date(), source: String, kind: String, title: String, input: String, output: String,
                seconds: Double, outputTokens: Int? = nil, ok: Bool = true) {
        self.id = id; self.date = date; self.source = source; self.kind = kind; self.title = title
        self.input = String(input.prefix(4000)); self.output = String(output.prefix(12000))
        self.seconds = seconds; self.outputTokens = outputTokens; self.ok = ok
    }
}

/// A local JSON Lines log of every run, from every surface. Never leaves the Mac.
public enum History {
    private static let lock = NSLock()

    public static var enabled: Bool {
        ProcessInfo.processInfo.environment["AFM_NO_HISTORY"] != "1" && AFMSettings.load().historyEnabled
    }

    public static func append(_ e: HistoryEntry) {
        guard enabled else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard var line = try? enc.encode(e) else { return }
        line.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        let url = AFMPaths.history
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    public static func load(limit: Int = 500) -> [HistoryEntry] {
        guard let d = try? String(contentsOf: AFMPaths.history, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let lines = d.split(separator: "\n").suffix(limit)
        return lines.compactMap { try? dec.decode(HistoryEntry.self, from: Data($0.utf8)) }.reversed()
    }

    public static func clear() { try? FileManager.default.removeItem(at: AFMPaths.history) }
}

/// Settings shared by the app and the CLI.
public struct AFMSettings: Codable, Sendable, Equatable {
    public var historyEnabled: Bool = true
    public var defaultConfig: ModelConfig = .default
    public var defaultOptions: GenOptions = .default
    public var defaultInstructions: String = ChatSessionRecord.defaultInstructions
    public var defaultTools: [ToolKind] = ToolKind.safeDefaults
    public var serverPort: Int = 11535
    public var mcpAllowFileTools: Bool = false
    /// Claude (cloud) settings. The API key itself lives only in the Keychain.
    public var claudeModel: String = ClaudeModel.defaultID
    public var claudeEffort: String = "medium"
    public var autoHookClaudeCode: Bool = true
    public var autoHookClaudeDesktop: Bool = true
    /// On/off switches per integration id. Integration data lives in its own file; credentials in the Keychain.
    public var integrationPrefs: [String: IntegrationPrefs] = [:]

    public init() {}

    public static func load() -> AFMSettings {
        guard let d = try? Data(contentsOf: AFMPaths.settings), let s = try? JSONDecoder().decode(AFMSettings.self, from: d) else { return AFMSettings() }
        return s
    }

    public func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: AFMPaths.settings, options: .atomic)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AFMSettings()
        historyEnabled = (try? c.decode(Bool.self, forKey: .historyEnabled)) ?? d.historyEnabled
        defaultConfig = (try? c.decode(ModelConfig.self, forKey: .defaultConfig)) ?? d.defaultConfig
        defaultOptions = (try? c.decode(GenOptions.self, forKey: .defaultOptions)) ?? d.defaultOptions
        defaultInstructions = (try? c.decode(String.self, forKey: .defaultInstructions)) ?? d.defaultInstructions
        defaultTools = (try? c.decode([ToolKind].self, forKey: .defaultTools)) ?? d.defaultTools
        serverPort = (try? c.decode(Int.self, forKey: .serverPort)) ?? d.serverPort
        mcpAllowFileTools = (try? c.decode(Bool.self, forKey: .mcpAllowFileTools)) ?? d.mcpAllowFileTools
        claudeModel = (try? c.decode(String.self, forKey: .claudeModel)) ?? d.claudeModel
        claudeEffort = (try? c.decode(String.self, forKey: .claudeEffort)) ?? d.claudeEffort
        autoHookClaudeCode = (try? c.decode(Bool.self, forKey: .autoHookClaudeCode)) ?? d.autoHookClaudeCode
        autoHookClaudeDesktop = (try? c.decode(Bool.self, forKey: .autoHookClaudeDesktop)) ?? d.autoHookClaudeDesktop
        integrationPrefs = (try? c.decode([String: IntegrationPrefs].self, forKey: .integrationPrefs)) ?? [:]
    }
}

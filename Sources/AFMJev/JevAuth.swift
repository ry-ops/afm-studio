import Foundation
import AFMKit

/// The TypeSafe API key: the Keychain first, then TYPESAFE_API_KEY. Never written to a file.
public enum JevAuth {
    static let secret = KeychainSecret(service: "dev.ry-ops.afm-studio.typesafe", label: "AFM Studio – TypeSafe API key", account: "api-key")

    public enum Source: String, Sendable { case keychain, environment, none }

    public static func save(_ key: String) throws {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.hasPrefix("apikey_"), k.count > 20, !k.contains(where: \.isWhitespace) else {
            throw AFMError(code: "bad_key", message: "That doesn't look like a TypeSafe API key.", suggestion: "Keys start with apikey_.")
        }
        try secret.save(k)
    }

    public static func delete() { secret.delete() }

    public static func resolve() -> (key: String?, source: Source) {
        if let k = secret.read(), !k.isEmpty { return (k, .keychain) }
        if let k = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !k.isEmpty { return (k, .environment) }
        return (nil, .none)
    }

    public static var sourceDescription: String {
        switch resolve().source {
        case .keychain: "your Keychain"
        case .environment: "TYPESAFE_API_KEY"
        case .none: "nothing yet"
        }
    }
}

/// Jev's settings on this Mac. Never the key.
public struct JevSettings: Codable, Sendable, Equatable {
    /// `jev-latest` follows TypeSafe's newest model. Pin a version such as jev-1.13.0 for repeatable results.
    public var model: String = JevClient.defaultModel
    public init() {}
    public static func load() -> JevSettings { IntegrationStore.load(JevIntegration.integrationID, as: JevSettings.self) ?? JevSettings() }
    public func save() { IntegrationStore.save(JevIntegration.integrationID, self) }
}

/// A running tally of what Jev calls cost, so a small budget is easy to watch. Counts only calls made from this Mac.
public struct JevUsage: Codable, Sendable, Equatable {
    /// TypeSafe's list price per million input tokens. Output tokens are free.
    public static let pricePerMillionInput = 0.042
    public var calls = 0
    public var inputTokens = 0
    public var since = Date()
    public var lastCall: Date?
    public var bySource: [String: Int] = [:]
    public init() {}

    public var estimatedCost: Double { Self.cost(inputTokens: inputTokens) }
    public static func cost(inputTokens: Int) -> Double { Double(inputTokens) / 1_000_000 * pricePerMillionInput }

    static let file = "jev-usage"
    private static let lock = NSLock()
    public static func load() -> JevUsage { IntegrationStore.load(file, as: JevUsage.self) ?? JevUsage() }

    public static func record(inputTokens: Int, model: String, source: String) {
        lock.lock(); defer { lock.unlock() }
        var u = load()
        u.calls += 1
        u.inputTokens += inputTokens
        u.lastCall = Date()
        u.bySource[source, default: 0] += 1
        IntegrationStore.save(file, u)
    }

    public static func reset() { IntegrationStore.save(file, JevUsage()) }

    public var summary: String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return String(format: "%d calls · %d input tokens · about $%.4f since %@", calls, inputTokens, estimatedCost, f.string(from: since))
    }
}

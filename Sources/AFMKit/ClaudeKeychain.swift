import Foundation

/// Stores the Anthropic API key in the macOS login Keychain. It never touches the repo,
/// the settings file, or any other file on disk.
public enum ClaudeKeychain {
    static let secret = KeychainSecret(service: "dev.ry-ops.afm-studio.anthropic", label: "AFM Studio – Anthropic API key", account: "api-key")

    public enum Source: String, Sendable { case keychain, environment, none }

    public static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk-ant-") else {
            throw AFMError(code: "bad_key", message: "That doesn't look like an Anthropic API key.", suggestion: "Keys start with sk-ant-.")
        }
        try secret.save(trimmed)
    }

    public static func readKeychain() -> String? { secret.read() }
    public static func delete() { secret.delete() }

    /// Keychain first, then ANTHROPIC_API_KEY.
    public static func resolve() -> (key: String?, source: Source) {
        if let k = readKeychain(), !k.isEmpty { return (k, .keychain) }
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty { return (k, .environment) }
        return (nil, .none)
    }

    /// Shows only the start and end, e.g. sk-ant-api…9f2c
    public static func masked(_ key: String) -> String { KeychainSecret.masked(key) }
}

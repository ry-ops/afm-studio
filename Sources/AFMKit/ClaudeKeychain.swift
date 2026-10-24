import Foundation
import Security

/// Stores the Anthropic API key in the macOS login Keychain. It never touches the repo,
/// the settings file, or any other file on disk.
public enum ClaudeKeychain {
    static let service = "dev.ry-ops.afm-studio.anthropic"
    static let account = "api-key"

    public enum Source: String, Sendable { case keychain, environment, none }

    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk-ant-") else {
            throw AFMError(code: "bad_key", message: "That doesn't look like an Anthropic API key.", suggestion: "Keys start with sk-ant-.")
        }
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrLabel as String] = "AFM Studio – Anthropic API key"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AFMError(code: "keychain", message: "Couldn't save to the Keychain (\(status)).")
        }
    }

    public static func readKeychain() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public static func delete() { SecItemDelete(query as CFDictionary) }

    /// Keychain first, then ANTHROPIC_API_KEY.
    public static func resolve() -> (key: String?, source: Source) {
        if let k = readKeychain(), !k.isEmpty { return (k, .keychain) }
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty { return (k, .environment) }
        return (nil, .none)
    }

    /// Shows only the start and end, e.g. sk-ant-api…9f2c
    public static func masked(_ key: String) -> String {
        guard key.count > 16 else { return "••••" }
        return String(key.prefix(10)) + "…" + String(key.suffix(4))
    }
}

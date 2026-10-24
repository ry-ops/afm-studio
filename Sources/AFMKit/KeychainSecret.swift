import Foundation
import Security

/// A secret kept in the macOS login Keychain ("this device only"). Never written to a file.
public struct KeychainSecret: Sendable {
    public let service: String
    public let label: String
    let account: String

    public init(service: String, label: String, account: String = "token") {
        self.service = service
        self.label = label
        self.account = account
    }

    var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func save(_ value: String) throws {
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrLabel as String] = label
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw AFMError(code: "keychain", message: "Couldn't save to the Keychain (\(status)).") }
    }

    public func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public func delete() { SecItemDelete(query as CFDictionary) }

    public static func masked(_ key: String) -> String {
        guard key.count > 16 else { return "••••" }
        return String(key.prefix(10)) + "…" + String(key.suffix(4))
    }
}

public enum Shell {
    /// Runs a command through a login shell so the user's PATH is available.
    public static func run(_ command: String) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

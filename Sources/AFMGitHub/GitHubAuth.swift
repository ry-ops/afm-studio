import Foundation
import AFMKit

/// GitHub credentials: a token in the Keychain wins; otherwise the `gh` CLI login; otherwise GITHUB_TOKEN / GH_TOKEN.
public enum GitHubAuth {
    public static let secret = KeychainSecret(service: "dev.ry-ops.afm-studio.github", label: "AFM Studio – GitHub token")

    public enum Source: String, Sendable { case keychain, ghCLI = "gh", environment, none }

    private static let cache = Cache()
    final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var gh: String??
        func ghToken() -> String? {
            lock.lock(); defer { lock.unlock() }
            if let gh { return gh }
            let (code, out) = Shell.run("gh auth token 2>/dev/null")
            let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
            let value: String? = (code == 0 && !t.isEmpty) ? t : nil
            gh = .some(value)
            return value
        }
        func reset() { lock.lock(); gh = nil; lock.unlock() }
    }

    public static func resolve() -> (token: String?, source: Source) {
        if let k = secret.read(), !k.isEmpty { return (k, .keychain) }
        if let g = cache.ghToken() { return (g, .ghCLI) }
        let env = ProcessInfo.processInfo.environment
        if let e = env["GITHUB_TOKEN"] ?? env["GH_TOKEN"], !e.isEmpty { return (e, .environment) }
        return (nil, .none)
    }

    public static func save(_ token: String) throws {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("github_pat_") || t.hasPrefix("ghp_") || t.hasPrefix("gho_") || t.hasPrefix("ghs_") else {
            throw AFMError(code: "bad_token", message: "That doesn't look like a GitHub token.", suggestion: "Fine-grained tokens start with github_pat_.")
        }
        try secret.save(t)
    }

    public static func delete() { secret.delete() }
    public static func refreshGH() { cache.reset() }

    public static var sourceDescription: String {
        switch resolve().source {
        case .keychain: "your Keychain token"
        case .ghCLI: "your gh CLI login"
        case .environment: "GITHUB_TOKEN"
        case .none: "nothing yet"
        }
    }
}

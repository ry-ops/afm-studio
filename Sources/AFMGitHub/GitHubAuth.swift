import Foundation
import AFMKit

/// GitHub credentials: a token in the Keychain wins; otherwise the `gh` CLI login; otherwise GITHUB_TOKEN / GH_TOKEN.
public enum GitHubAuth {
    public static let secret = KeychainSecret(service: "dev.ry-ops.afm-studio.github", label: "AFM Studio – GitHub token")

    public enum Source: String, Sendable { case keychain, ghCLI = "gh", environment, none }

    private static let cache = Cache()
    final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var gh: (token: String?, at: Date)?
        /// A failed lookup is retried after this long, so signing in with `gh` works without restarting.
        static let retryAfter: TimeInterval = 60
        func ghToken() -> String? {
            lock.lock(); defer { lock.unlock() }
            if let gh, gh.token != nil || Date().timeIntervalSince(gh.at) < Self.retryAfter { return gh.token }
            let value = GitHubAuth.findGH().flatMap(GitHubAuth.ghToken(at:))
            gh = (value, Date())
            return value
        }
        func reset() { lock.lock(); gh = nil; lock.unlock() }
    }

    /// Places to look for `gh`: the PATH first, then the usual install folders. An app opened from the
    /// Finder gets a minimal PATH, and the login shell it falls back to skips `.zshrc`, so `gh` in
    /// `~/.local/bin` or Homebrew is often missing from both.
    public static func ghCandidates(path: String? = ProcessInfo.processInfo.environment["PATH"],
                             home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        let dirs = (path ?? "").split(separator: ":").map(String.init)
            + [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", home + "/bin"]
        var seen = Set<String>()
        return dirs.filter { $0.hasPrefix("/") }.map { $0 + "/gh" }.filter { seen.insert($0).inserted }
    }

    /// The first executable `gh` among the candidates, or else whatever a login shell finds.
    public static func findGH(in candidates: [String] = ghCandidates()) -> String? {
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        let (code, out) = Shell.run("command -v gh")
        let found = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return code == 0 && found.hasPrefix("/") ? found : nil
    }

    /// The token `gh` is signed in with, or nil when it isn't signed in.
    public static func ghToken(at gh: String) -> String? {
        let (code, out) = Shell.exec(gh, ["auth", "token"])
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return code == 0 && !t.isEmpty ? t : nil
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

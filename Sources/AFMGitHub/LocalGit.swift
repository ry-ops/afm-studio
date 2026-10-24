import Foundation
import AFMKit

/// Read-only access to a local git checkout.
public struct LocalRepo: Sendable {
    public let path: String

    public init(path: String) throws {
        let p = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        self.path = p
        guard (try? git(["rev-parse", "--is-inside-work-tree"]))?.hasPrefix("true") == true else {
            throw AFMError(code: "not_git", message: "\(path) isn't a git repository.")
        }
    }

    @discardableResult
    public func git(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", path] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let edata = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw AFMError(code: "git", message: "git \(args.first ?? ""): " + String(decoding: edata, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: data, as: UTF8.self)
    }

    public var currentBranch: String { ((try? git(["rev-parse", "--abbrev-ref", "HEAD"])) ?? "HEAD").trimmingCharacters(in: .whitespacesAndNewlines) }

    public var defaultBranch: String {
        if let r = try? git(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]) {
            return r.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "refs/remotes/origin/", with: "")
        }
        for b in ["main", "master"] where (try? git(["rev-parse", "--verify", "--quiet", b])) != nil { return b }
        return "main"
    }

    /// The base ref to compare against: origin/<default> when it exists.
    public var defaultBase: String {
        let b = defaultBranch
        return (try? git(["rev-parse", "--verify", "--quiet", "origin/\(b)"])) != nil ? "origin/\(b)" : b
    }

    /// owner/repo parsed from the origin remote, if it's on GitHub.
    public var githubSlug: String? {
        guard let url = try? git(["remote", "get-url", "origin"]).trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        var s = url
        if s.hasPrefix("git@github.com:") { s = "github.com/" + s.dropFirst("git@github.com:".count) }
        guard s.contains("github.com") else { return nil }
        return GHRef.parse(s).map(\.slug)
    }

    public var latestTag: String? { (try? git(["describe", "--tags", "--abbrev=0"]))?.trimmingCharacters(in: .whitespacesAndNewlines) }

    public func commits(_ range: String, limit: Int = 200) throws -> [String] {
        try git(["log", range, "--no-merges", "-n", String(limit), "--format=%s%n%b%x1e"])
            .components(separatedBy: "\u{1e}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public func diffStat(_ range: String) throws -> String { try git(["diff", "--stat", range]) }
    public func diff(_ range: String) throws -> String { try git(["diff", "--no-color", range]) }
}

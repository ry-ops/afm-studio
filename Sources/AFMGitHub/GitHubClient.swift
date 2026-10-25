import Foundation
import AFMKit

// MARK: - Models (only the fields AFM Studio uses)

public struct GHUser: Decodable, Sendable, Hashable { public let login: String; public let name: String? }
public struct GHLabel: Decodable, Sendable, Hashable { public let name: String; public let description: String? }

public struct GHRepo: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let fullName: String
    public let description: String?
    public let htmlUrl: String
    public let defaultBranch: String
    public let language: String?
    public let stargazersCount: Int
    public let openIssuesCount: Int
    public let pushedAt: String?
    public let `private`: Bool
    public let archived: Bool
    public let fork: Bool
}

public struct GHIssue: Decodable, Sendable, Hashable, Identifiable {
    public struct PRMarker: Decodable, Sendable, Hashable { public let url: String? }
    public let id: Int
    public let number: Int
    public let title: String
    public let body: String?
    public let state: String
    public let user: GHUser?
    public let labels: [GHLabel]
    public let comments: Int
    public let htmlUrl: String
    public let createdAt: String
    public let updatedAt: String
    public let pullRequest: PRMarker?
    public let repositoryUrl: String?
    public let draft: Bool?

    public var isPR: Bool { pullRequest != nil }
    /// "owner/repo", from the API URL.
    public var repo: String {
        guard let u = repositoryUrl, let r = u.range(of: "/repos/") else { return "" }
        return String(u[r.upperBound...])
    }
    public var ref: String { "\(repo)#\(number)" }
}

public struct GHComment: Decodable, Sendable, Hashable { public let user: GHUser?; public let body: String?; public let createdAt: String }

public struct GHPull: Decodable, Sendable, Hashable {
    public struct Branch: Decodable, Sendable, Hashable { public let ref: String; public let sha: String }
    public let number: Int
    public let title: String
    public let body: String?
    public let state: String
    public let merged: Bool?
    public let draft: Bool?
    public let additions: Int?
    public let deletions: Int?
    public let changedFiles: Int?
    public let head: Branch
    public let base: Branch
    public let user: GHUser?
    public let htmlUrl: String
}

public struct GHFile: Decodable, Sendable, Hashable {
    public let filename: String
    public let status: String
    public let additions: Int
    public let deletions: Int
    public let patch: String?
}

public struct GHCommit: Decodable, Sendable, Hashable {
    public struct Inner: Decodable, Sendable, Hashable {
        public struct Author: Decodable, Sendable, Hashable { public let name: String?; public let date: String? }
        public let message: String
        public let author: Author?
    }
    public let sha: String
    public let commit: Inner
    public var subject: String { commit.message.split(separator: "\n").first.map(String.init) ?? "" }
}

struct GHCompare: Decodable { let commits: [GHCommit]; let files: [GHFile]?; let totalCommits: Int? }
struct GHSearch<T: Decodable>: Decodable { let totalCount: Int; let items: [T] }
struct GHTree: Decodable { struct Item: Decodable { let path: String; let type: String }; let tree: [Item] }
struct GHContent: Decodable { let content: String?; let encoding: String? }
struct GHTag: Decodable { let name: String }

// MARK: - References

/// owner/repo#123, owner/repo/issues/123, or a github.com URL.
public struct GHRef: Sendable, Hashable, CustomStringConvertible {
    public let owner: String
    public let repo: String
    public let number: Int?
    public var slug: String { "\(owner)/\(repo)" }
    public var description: String { number.map { "\(slug)#\($0)" } ?? slug }

    public init(owner: String, repo: String, number: Int? = nil) { self.owner = owner; self.repo = repo; self.number = number }

    public static func parse(_ raw: String) -> GHRef? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasPrefix("github.com/") { s.removeFirst("github.com/".count) }
        if s.hasSuffix(".git") { s.removeLast(4) }
        var number: Int?
        if let hash = s.firstIndex(of: "#") {
            number = Int(s[s.index(after: hash)...])
            s = String(s[..<hash])
        }
        let parts = s.split(separator: "/").map(String.init)
        // GitHub names use letters, digits, '-', '_' and '.'. Anything else (or "." and "..") could
        // steer the API path somewhere other than the repo.
        func valid(_ n: String) -> Bool {
            !n.isEmpty && n != "." && n != ".." && n.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        }
        guard parts.count >= 2, valid(parts[0]), valid(parts[1]) else { return nil }
        if number == nil, parts.count >= 4, ["issues", "pull", "pulls"].contains(parts[2]) { number = Int(parts[3]) }
        return GHRef(owner: parts[0], repo: parts[1], number: number)
    }
}

// MARK: - Client

/// Read-only GitHub REST client. AFM Studio never writes to GitHub.
public struct GitHubClient: Sendable {
    let token: String
    static let base = "https://api.github.com"

    public init(token: String) { self.token = token }

    /// The one way to get a client. Refuses while the integration is off, so no token is read.
    public static func make() throws -> GitHubClient {
        try IntegrationRegistry.requireEnabled(GitHubIntegration.integrationID)
        guard let t = GitHubAuth.resolve().token else {
            throw AFMError(code: "no_github_auth", message: "No GitHub sign-in found.",
                           suggestion: "Run `gh auth login`, or add a token with `afm github auth set`.")
        }
        return GitHubClient(token: t)
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    func data(_ path: String, query: [String: String] = [:], accept: String = "application/vnd.github+json") async throws -> Data {
        var comps = URLComponents(string: Self.base + path)!
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!, timeoutInterval: 30)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("afm-studio", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            switch status {
            case 401: throw AFMError(code: "github_auth", message: "GitHub rejected the token.", suggestion: "Check `afm github auth status`.")
            case 403 where http?.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0":
                throw AFMError(code: "github_rate_limit", message: "GitHub's rate limit was hit.", suggestion: "Try again after the limit resets.")
            case 404: throw AFMError(code: "github_not_found", message: "GitHub couldn't find \(path).", suggestion: "Check the name, and that your token can see it.")
            default: throw AFMError(code: "github_\(status)", message: "GitHub: \(msg)")
            }
        }
        return data
    }

    public func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        let d = try await data(path, query: query)
        do { return try Self.decoder.decode(T.self, from: d) }
        catch { throw AFMError(code: "github_decode", message: "Unexpected response from GitHub for \(path).") }
    }

    public func me() async throws -> GHUser { try await get("/user") }
    public func repo(_ slug: String) async throws -> GHRepo { try await get("/repos/\(slug)") }

    public func myRepos(limit: Int = 50) async throws -> [GHRepo] {
        try await get("/user/repos", ["sort": "pushed", "per_page": String(min(limit, 100)), "affiliation": "owner,collaborator,organization_member"])
    }

    public func issue(_ r: GHRef) async throws -> GHIssue { try await get("/repos/\(r.slug)/issues/\(r.number ?? 0)") }
    public func comments(_ r: GHRef, limit: Int = 40) async throws -> [GHComment] {
        try await get("/repos/\(r.slug)/issues/\(r.number ?? 0)/comments", ["per_page": String(min(limit, 100))])
    }
    public func pull(_ r: GHRef) async throws -> GHPull { try await get("/repos/\(r.slug)/pulls/\(r.number ?? 0)") }
    public func pullFiles(_ r: GHRef, limit: Int = 100) async throws -> [GHFile] {
        try await get("/repos/\(r.slug)/pulls/\(r.number ?? 0)/files", ["per_page": String(min(limit, 100))])
    }
    public func labels(_ slug: String) async throws -> [GHLabel] { try await get("/repos/\(slug)/labels", ["per_page": "100"]) }
    public func openIssues(_ slug: String, limit: Int = 50) async throws -> [GHIssue] {
        try await get("/repos/\(slug)/issues", ["state": "open", "per_page": String(min(limit, 100)), "sort": "updated"])
    }
    public func commits(_ slug: String, since: Date? = nil, limit: Int = 30) async throws -> [GHCommit] {
        var q = ["per_page": String(min(limit, 100))]
        if let since { q["since"] = ISO8601DateFormatter().string(from: since) }
        return try await get("/repos/\(slug)/commits", q)
    }
    func compare(_ slug: String, base: String, head: String) async throws -> GHCompare {
        try await get("/repos/\(slug)/compare/\(base)...\(head)")
    }
    public func readme(_ slug: String) async throws -> String {
        String(decoding: try await data("/repos/\(slug)/readme", accept: "application/vnd.github.raw+json"), as: UTF8.self)
    }
    public func file(_ slug: String, path: String) async throws -> String {
        String(decoding: try await data("/repos/\(slug)/contents/\(path)", accept: "application/vnd.github.raw+json"), as: UTF8.self)
    }
    public func paths(_ slug: String, ref: String = "HEAD") async throws -> [String] {
        let t: GHTree = try await get("/repos/\(slug)/git/trees/\(ref)", ["recursive": "1"])
        return t.tree.filter { $0.type == "blob" }.map(\.path)
    }
    public func latestTag(_ slug: String) async throws -> String? {
        let tags: [GHTag] = try await get("/repos/\(slug)/tags", ["per_page": "1"])
        return tags.first?.name
    }
    public func search(_ q: String, limit: Int = 20) async throws -> [GHIssue] {
        let r: GHSearch<GHIssue> = try await get("/search/issues", ["q": q, "per_page": String(min(limit, 100)), "sort": "updated"])
        return r.items
    }
}

// MARK: - Browser links (drafts only: you review and submit them yourself)

public enum GitHubLinks {
    static func enc(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
    /// Pre-filled "new issue" page. nil when the URL would be too long for a browser.
    public static func newIssue(_ slug: String, title: String, body: String, labels: [String] = []) -> URL? {
        var s = "https://github.com/\(slug)/issues/new?title=\(enc(title))&body=\(enc(body))"
        if !labels.isEmpty { s += "&labels=\(enc(labels.joined(separator: ",")))" }
        return s.count < 7800 ? URL(string: s) : nil
    }
    public static func newPR(_ slug: String, base: String, head: String, title: String, body: String) -> URL? {
        let s = "https://github.com/\(slug)/compare/\(enc(base))...\(enc(head))?quick_pull=1&title=\(enc(title))&body=\(enc(body))"
        return s.count < 7800 ? URL(string: s) : nil
    }
    public static func newFile(_ slug: String, branch: String, dir: String, filename: String, content: String) -> URL? {
        let s = "https://github.com/\(slug)/new/\(branch)/\(dir)?filename=\(enc(filename))&value=\(enc(content))"
        return s.count < 7800 ? URL(string: s) : nil
    }
}

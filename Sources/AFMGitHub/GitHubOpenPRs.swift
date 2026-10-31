import Foundation

/// Open pull requests across the repos a user and their organizations own. The query and the summary are
/// built here, not by the model: GitHub has no qualifier for "all my orgs", and the on-device model can't
/// know the org names or fit hundreds of results in its context.
public enum GitHubOpenPRs {
    public enum Scope: String, Sendable {
        case mine, orgs, all
        /// Reads what the model passes, which may be loose ("my orgs", "everything", "").
        public init(loose: String) {
            let s = loose.lowercased()
            if s.contains("org") { self = .orgs }
            else if s.contains("mine") || s.contains("my") || s.contains("personal") || s.contains("own") { self = .mine }
            else { self = .all }
        }
    }

    /// `user:` and `org:` qualifiers for a scope. GitHub ORs repeated owner qualifiers.
    public static func owners(login: String, orgs: [String], scope: Scope) -> [String] {
        var owners: [String] = []
        if scope != .orgs { owners.append("user:\(login)") }
        if scope != .mine { owners += orgs.map { "org:\($0)" } }
        return owners
    }

    /// The search query, or nil when the scope covers no owners (orgs only, with no orgs).
    public static func query(login: String, orgs: [String], scope: Scope) -> String? {
        let owners = owners(login: login, orgs: orgs, scope: scope)
        guard !owners.isEmpty else { return nil }
        return "is:open is:pr archived:false " + owners.joined(separator: " ")
    }

    /// A short summary that fits the model's context: totals, counts per repo and the latest few PRs.
    public static func summary(total: Int, items: [GHIssue], login: String, orgs: [String], scope: Scope,
                               repoLimit: Int = 10, listLimit: Int = 8) -> String {
        let owners: String = switch scope {
        case .mine: "\(login)'s repos"
        case .orgs: "the repos of \(orgs.count) organizations (\(orgs.joined(separator: ", ")))"
        case .all: orgs.isEmpty ? "\(login)'s repos" : "\(login)'s repos and \(orgs.count) organizations (\(orgs.joined(separator: ", ")))"
        }
        guard total > 0, !items.isEmpty else { return "No open pull requests in \(owners)." }
        var lines = ["\(total) open pull request\(total == 1 ? "" : "s") in \(owners)."]
        if items.count < total { lines.append("Counts below cover the \(items.count) most recently updated.") }

        if scope == .all, !orgs.isEmpty, items.count == total {
            let yours = items.filter { $0.repo.hasPrefix(login + "/") }.count
            lines.append("In \(login)'s own repos: \(yours). In organization repos: \(total - yours).")
        }
        let bots = items.filter { ($0.user?.login ?? "").hasSuffix("[bot]") }.count
        if bots > 0 { lines.append("\(bots) are from bots such as Dependabot.") }
        let byYou = items.filter { $0.user?.login == login }.count
        if byYou > 0 { lines.append("\(byYou) were opened by \(login).") }

        let byOwner = counts(items) { $0.repo.split(separator: "/").first.map(String.init) ?? "" }
        lines.append("By owner: " + byOwner.map { "\($0.key) \($0.count)" }.joined(separator: ", ") + ".")

        let byRepo = counts(items) { $0.repo }
        lines.append("Top repos:")
        lines += byRepo.prefix(repoLimit).map { "- \($0.key): \($0.count)" }
        if byRepo.count > repoLimit { lines.append("- and \(byRepo.count - repoLimit) more repos") }

        lines.append("Most recently updated:")
        lines += items.prefix(listLimit).map { i in
            "- \(i.ref) \(i.title) (by \(i.user?.login ?? "unknown")\(i.draft == true ? ", draft" : ""), updated \(i.updatedAt.prefix(10)))"
        }
        return lines.joined(separator: "\n")
    }

    /// Counts per key, largest first, ties in name order.
    static func counts(_ items: [GHIssue], by key: (GHIssue) -> String) -> [(key: String, count: Int)] {
        var c: [String: Int] = [:]
        for i in items { c[key(i), default: 0] += 1 }
        return c.map { (key: $0.key, count: $0.value) }.sorted { a, b in a.count != b.count ? a.count > b.count : a.key < b.key }
    }
}

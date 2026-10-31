import Foundation
import AFMKit

/// Recipe sources for GitHub. Each kind fetches with fixed queries and writes short lines the
/// 4K-context model can read. Nothing here writes to GitHub.
///
/// - `github.search`: one line per issue or PR matching `query`.
/// - `github.thread`: one issue or PR in full (`ref`).
/// - `github.each`: the search lines, then the first `each` threads in full.
/// - `github.runs`: failed GitHub Actions runs in `repo`, with the failing steps and the end of their logs.
///
/// In a query, `{{owners}}` becomes `repo:` qualifiers for the `repo` parameter when it's set, and
/// otherwise `user:` and `org:` qualifiers for the `scope` parameter (mine, orgs or all).
public enum GitHubSources {
    public static func fetch(_ source: RecipeSource, values: [String: String], onProgress: (@Sendable (String) -> Void)?) async throws -> SourceMaterial? {
        switch source.kind {
        case "github.search": return try await search(source, values: values, onProgress: onProgress, read: 0)
        case "github.each": return try await search(source, values: values, onProgress: onProgress, read: min(max(source.each ?? 3, 1), 5))
        case "github.thread": return try await thread(source, values: values, onProgress: onProgress)
        case "github.runs": return try await runs(source, values: values, onProgress: onProgress)
        default: return nil
        }
    }

    // MARK: Search

    /// `owner/repo` values from a comma-separated list. `.` means the checkout in the current directory.
    static func repos(_ raw: String?) -> [String] {
        (raw ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.compactMap { r -> String? in
            if r == "." { return currentRepo() }
            return r.isEmpty ? nil : GHRef.parse(r)?.slug ?? r
        }
    }

    /// The GitHub repo of the git checkout in the current directory, if there is one.
    static func currentRepo() -> String? {
        (try? LocalRepo(path: FileManager.default.currentDirectoryPath))?.githubSlug
    }

    /// The query with parameters, dates and `{{owners}}` filled in.
    public static func query(_ template: String, values: [String: String], login: @Sendable () async throws -> (String, [String])) async throws -> String {
        var q = RecipeSource.render(template, values)
        if q.contains("{{owners}}") {
            let list = repos(values["repo"])
            let owners: [String]
            if !list.isEmpty {
                owners = list.map { "repo:\($0)" }
            } else {
                let (me, orgs) = try await login()
                owners = GitHubOpenPRs.owners(login: me, orgs: orgs, scope: GitHubOpenPRs.Scope(loose: values["scope"] ?? "all"))
                guard !owners.isEmpty else {
                    throw AFMError(code: "no_owners", message: "You're not in any GitHub organizations, so the orgs scope has nothing to search.",
                                   suggestion: "Choose all or mine, or name repos like owner/name.")
                }
            }
            q = q.replacingOccurrences(of: "{{owners}}", with: owners.joined(separator: " "))
        }
        return q.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func days(since iso: String, now: Date) -> Int? {
        guard let d = ISO8601DateFormatter().date(from: iso) else { return nil }
        return max(0, Int(now.timeIntervalSince(d) / 86400))
    }

    static func ago(_ iso: String, now: Date) -> String {
        guard let n = days(since: iso, now: now) else { return String(iso.prefix(10)) }
        let when = n == 0 ? "today" : n == 1 ? "1 day ago" : "\(n) days ago"
        return "\(iso.prefix(10)) (\(when))"
    }

    /// One line per item. Ages are worked out here, since the model is unreliable at date math.
    public static func line(_ i: GHIssue, now: Date = Date()) -> String {
        var kind = i.isPR ? "PR" : "issue"
        if i.draft == true { kind += ", draft" }
        var s = "- \(i.ref) [\(kind)] \"\(i.title)\" by @\(i.user?.login ?? "?"). Opened \(ago(i.createdAt, now: now)), updated \(ago(i.updatedAt, now: now))."
        if i.comments > 0 { s += " \(i.comments) comment\(i.comments == 1 ? "" : "s")." }
        if !i.labels.isEmpty { s += " Labels: \(i.labels.map(\.name).joined(separator: ", "))." }
        return s
    }

    static func isBot(_ i: GHIssue) -> Bool { (i.user?.login ?? "").hasSuffix("[bot]") }

    /// The items the model sees: people's first, then bots', each group in search order.
    public static func listed(_ found: [GHIssue], max: Int) -> [GHIssue] {
        Array((found.filter { !isBot($0) } + found.filter(isBot)).prefix(max))
    }

    /// Exact counts, worked out here so the model never has to count.
    public static func overview(q: String, total: Int, found: [GHIssue], oldest: Bool, now: Date) -> String {
        var s = "GitHub search `\(q)` found \(total) item\(total == 1 ? "" : "s")."
        if total > found.count { s += " The counts below cover the \(found.count) \(oldest ? "least" : "most") recently updated." }
        var byRepo: [String: Int] = [:]
        for i in found { byRepo[i.repo, default: 0] += 1 }
        let repos = byRepo.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        s += "\nBy repo: " + repos.prefix(8).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        s += repos.count > 8 ? ", and \(repos.count - 8) more repos." : "."
        let bots = found.filter(isBot).count
        let drafts = found.filter { $0.draft == true }.count
        let idle = found.filter { (days(since: $0.updatedAt, now: now) ?? 0) >= 14 }.count
        s += "\nOpened by bots: \(bots). By people: \(found.count - bots). Drafts: \(drafts). Not updated in 14 or more days: \(idle)."
        return s
    }

    static func item(_ i: GHIssue) -> SourceItem {
        SourceItem(ref: i.ref, title: i.title, url: i.htmlUrl, kind: i.isPR ? "pull_request" : "issue", updated: i.updatedAt)
    }

    static func search(_ source: RecipeSource, values: [String: String], onProgress: (@Sendable (String) -> Void)?, read: Int) async throws -> SourceMaterial {
        guard let template = source.query, !template.isEmpty else {
            throw AFMError(code: "bad_source", message: "A \(source.kind) source needs a query.")
        }
        let gh = try GitHubClient.make()
        let q = try await query(template, values: values) {
            onProgress?("Looking up your GitHub organizations")
            let me = try await gh.me().login
            let orgs = try await gh.orgs().map(\.login)
            return (me, orgs)
        }
        let limit = min(max(source.limit ?? 30, 1), 100)
        let oldest = source.order?.lowercased() == "oldest"
        onProgress?("Searching GitHub: \(q)")
        let (total, found) = try await gh.searchAll(q, maxItems: limit, oldestFirst: oldest)
        guard !found.isEmpty else {
            return SourceMaterial(text: "", items: [], description: q, emptyMessage: "Nothing on GitHub matches `\(q)`.")
        }
        var text = overview(q: q, total: total, found: found, oldest: oldest, now: Date())
        let shown = listed(found, max: min(max(source.list ?? 15, 1), 40))
        text += "\n\nItems" + (shown.count < found.count ? " (\(shown.count) of them; people's before bots')" : "") + ":\n"
        text += shown.map { line($0, now: Date()) }.joined(separator: "\n")
        for (n, i) in found.prefix(read).enumerated() {
            guard let ref = GHRef.parse(i.ref) else { continue }
            onProgress?("Reading \(i.ref) (\(n + 1) of \(min(read, found.count)))")
            let t = try await GitHubWorkflows.threadText(gh, ref, includeDiff: source.diff ?? false).text
            text += "\n\n---\n\n" + GitHubWorkflows.clip(t, 3500)
        }
        return SourceMaterial(text: text, items: found.map(item), description: q, headline: headline(total: total, found: found, now: Date()))
    }

    /// One exact sentence or two for the top of the answer.
    public static func headline(total: Int, found: [GHIssue], now: Date) -> String {
        var byRepo: [String: Int] = [:]
        for i in found { byRepo[i.repo, default: 0] += 1 }
        let top = byRepo.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3)
        let prs = found.allSatisfy(\.isPR), noun = prs ? "pull request" : found.allSatisfy { !$0.isPR } ? "issue" : "item"
        var s = "**\(total) \(noun)\(total == 1 ? "" : "s")**"
        if byRepo.count > 1 { s += ", most in " + top.map { "\($0.key) (\($0.value))" }.joined(separator: ", ") }
        else if let only = top.first { s += " in \(only.key)" }
        s += "."
        let bots = found.filter(isBot).count
        let idle = found.filter { (days(since: $0.updatedAt, now: now) ?? 0) >= 14 }.count
        var facts: [String] = []
        if bots > 0 { facts.append(bots == found.count ? "all opened by bots" : "\(bots) opened by bots") }
        if idle > 0 { facts.append("\(idle) not updated in 14 or more days") }
        if !facts.isEmpty { s += " " + (total > found.count ? "Of the \(found.count) most recent, " : "") + facts.joined(separator: ", ") + "." }
        return s.replacingOccurrences(of: ". all opened", with: ". All opened")
    }

    // MARK: Thread

    static func thread(_ source: RecipeSource, values: [String: String], onProgress: (@Sendable (String) -> Void)?) async throws -> SourceMaterial {
        let raw = RecipeSource.render(source.ref ?? "{{ref}}", values).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !raw.contains("{{"), let ref = GHRef.parse(raw), ref.number != nil else {
            throw AFMError(code: "bad_ref", message: raw.isEmpty || raw.contains("{{") ? "Which issue or pull request? None was given." : "\"\(raw)\" isn't an issue or pull request.",
                           suggestion: "Give one like owner/repo#123, or paste its GitHub URL. In Terminal: -p ref=owner/repo#123.")
        }
        let gh = try GitHubClient.make()
        onProgress?("Reading \(ref)")
        let (issue, text) = try await GitHubWorkflows.threadText(gh, ref, includeDiff: source.diff ?? true)
        return SourceMaterial(text: text, items: [item(issue)], description: ref.description)
    }

    // MARK: Actions runs

    /// The part of a job log worth reading: around the first error, or the end. Timestamps are removed.
    public static func logExcerpt(_ log: String, maxChars: Int = 2500) -> String {
        let stamp = try? NSRegularExpression(pattern: #"^\d{4}-\d\d-\d\dT[\d:.]+Z ?"#)
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false).map { l -> String in
            let s = String(l).replacingOccurrences(of: "\r", with: "")
            var bare = stamp.map { $0.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "") } ?? s
            bare = bare.replacingOccurrences(of: #"\x1B\[[0-9;]*m"#, with: "", options: .regularExpression)
            return squeeze(bare)
        }.filter { l in
            // The runner's own bookkeeping says nothing about why a step failed.
            let noise = ["##[group]", "##[endgroup]", "##[start-action", "##[end-action", "shell: /usr/bin/bash"]
            return l.contains { $0.isLetter || $0.isNumber } && !noise.contains { l.hasPrefix($0) }
        }
        let picked: ArraySlice<String>
        if let e = lines.firstIndex(where: { $0.contains("##[error]") }) {
            picked = lines[max(0, e - 20)..<min(lines.count, e + 3)]
        } else {
            picked = lines.suffix(40)
        }
        let text = picked.joined(separator: "\n")
        return text.count <= maxChars ? text : "…" + String(text.suffix(maxChars))
    }

    /// Table borders and column padding cost the model's context and say nothing.
    static func squeeze(_ line: String) -> String {
        var out = "", last: Character? = nil, run = 0
        for c in line {
            run = c == last ? run + 1 : 1
            last = c
            if c == " " && run > 1 { continue }
            if !c.isLetter && !c.isNumber && c != " " && run > 3 { continue }
            out.append(c)
        }
        let t = out.trimmingCharacters(in: .whitespaces)
        return t.count <= 300 ? t : String(t.prefix(300)) + "…"
    }

    static func runs(_ source: RecipeSource, values: [String: String], onProgress: (@Sendable (String) -> Void)?) async throws -> SourceMaterial {
        let named = repos(RecipeSource.render(source.repo ?? "{{repo}}", values).replacingOccurrences(of: "{{repo}}", with: ""))
        guard let slug = named.first ?? currentRepo() else {
            throw AFMError(code: "no_repo", message: "Which repository? None was given, and the current directory isn't a GitHub checkout.",
                           suggestion: "Give one like owner/name. In Terminal, -p repo=owner/name, or run it inside the repo's folder.")
        }
        var branch = RecipeSource.render(source.branch ?? "{{branch}}", values).trimmingCharacters(in: .whitespaces)
        if ["all", "*", "any"].contains(branch.lowercased()) { branch = "" }
        let gh = try GitHubClient.make()
        onProgress?("Listing failed runs in \(slug)")
        let limit = min(max(source.limit ?? 10, 1), 30)
        let runs = try await gh.failedRuns(slug, branch: branch.isEmpty || branch.contains("{{") ? nil : branch, limit: limit)
        let on = branch.isEmpty || branch.contains("{{") ? "" : " on \(branch)"
        guard !runs.isEmpty else {
            return SourceMaterial(text: "", items: [], description: "\(slug) failed runs\(on)", emptyMessage: "No failed GitHub Actions runs\(on) in \(slug).")
        }
        let now = Date()
        // The same workflow failing again on the same commit (a nightly scan) is one failure.
        var groups: [(run: GHRun, count: Int)] = []
        for r in runs {
            if let i = groups.firstIndex(where: { $0.run.name == r.name && $0.run.headSha == r.headSha }) { groups[i].count += 1 }
            else { groups.append((r, 1)) }
        }
        let read = min(max(source.each ?? 3, 1), 5)
        let full = min(read, groups.count)
        var text = "The \(runs.count) latest failed GitHub Actions runs\(on) in \(slug) are \(groups.count) distinct failure\(groups.count == 1 ? "" : "s"). \(full == 1 ? "1 is" : "\(full) are") read in full below.\n"
        text += groups.map { g in
            let r = g.run
            let title = r.displayTitle.flatMap { $0 == r.name || $0.isEmpty ? nil : ", \"\($0)\"" } ?? ""
            let again = g.count > 1 ? " Failed \(g.count) times on this commit; the latest" : ""
            return "- Run \(r.id): workflow \"\(r.name ?? "?")\" on \(r.headBranch ?? "?") at \(String(r.headSha.prefix(7)))\(title), triggered by \(r.event).\(again) \(ago(r.createdAt, now: now))."
        }.joined(separator: "\n")
        for (n, r) in groups.map(\.run).prefix(read).enumerated() {
            onProgress?("Reading the failed jobs of run \(r.id) (\(n + 1) of \(min(read, groups.count)))")
            let jobs = (try? await gh.jobs(slug, runID: r.id)) ?? []
            let failed = jobs.filter { $0.conclusion == "failure" || $0.conclusion == "timed_out" }
            text += "\n\n---\n\nRun \(r.id), workflow \"\(r.name ?? "?")\":"
            if failed.isEmpty { text += " no failed jobs were listed (it may have been cancelled or failed to start)." }
            // One log per run keeps three runs in a single pass of the 4K context.
            for (k, j) in failed.prefix(3).enumerated() {
                let steps = (j.steps ?? []).filter { $0.conclusion == "failure" }.map(\.name)
                text += "\nJob \"\(j.name)\" failed" + (steps.isEmpty ? "." : " at step: \(steps.joined(separator: ", ")).")
                guard k == 0 else { continue }
                if let log = try? await gh.jobLog(slug, jobID: j.id), !log.isEmpty {
                    text += "\nLog excerpt:\n" + logExcerpt(log, maxChars: 1500)
                } else {
                    text += "\n(The log couldn't be read. It may have expired, or the token can't read Actions.)"
                }
            }
        }
        let items = runs.map { SourceItem(ref: "\(slug) run \($0.id)", title: $0.displayTitle ?? $0.name ?? "Run \($0.id)", url: $0.htmlUrl, kind: "workflow_run", updated: $0.createdAt) }
        let top = groups.prefix(3).map { "\($0.run.name ?? "?")\($0.count > 1 ? " (×\($0.count))" : "")" }.joined(separator: ", ")
        let headline = "**\(groups.count) distinct failure\(groups.count == 1 ? "" : "s")** in the last \(runs.count) failed runs\(on) in \(slug): \(top)\(groups.count > 3 ? ", and more" : "")."
        return SourceMaterial(text: text, items: items, description: "\(slug) failed runs\(on)", headline: headline)
    }
}

// MARK: - Starter recipes

public enum GitHubRecipes {
    static let scope = RecipeParam(key: "scope", label: "Whose repos", defaultValue: "all", choices: ["all", "mine", "orgs"],
                                   help: "Your repos, your organizations' repos, or both. Ignored when repo is set.")
    static let repo = RecipeParam(key: "repo", label: "Repos", defaultValue: "",
                                  help: "Optional: owner/name, comma-separated. A dot means the repo in the current folder.")
    static let rules = "Use only the items given. Refer to each item by its repo#number. Never invent status, owners or dates."

    public static let all: [Recipe] = [
        Recipe(id: "gh-open-prs", title: "Open pull requests", summary: "Open PRs across your repos and orgs, grouped by repo, with what needs attention.",
               symbol: "arrow.triangle.pull", category: "GitHub",
               instructions: "You brief a developer on their open pull requests. " + rules,
               template: "Brief me on my open pull requests. Don't repeat the counts. List up to six listed PRs that need attention, one bullet each with a reason of a few words: PRs from people first, then stale or draft ones. Then say in one sentence which repos have bot updates that could be merged together. End with one sentence on what to do first.\n\n{{input}}",
               params: [scope, repo], temperature: 0.2, permissive: true,
               source: RecipeSource(kind: "github.search", query: "is:open is:pr archived:false {{owners}}", limit: 100)),
        Recipe(id: "gh-review-queue", title: "Review queue", summary: "Pull requests waiting on your review, ranked by urgency.",
               symbol: "eye", category: "GitHub",
               instructions: "You help a developer decide which reviews to do first. " + rules,
               template: "These pull requests are waiting for my review. Rank them, most urgent first, as a numbered list. Give each one a short reason, such as how long it has waited or that it's small. Put drafts last.\n\n{{input}}",
               temperature: 0.2, permissive: true,
               source: RecipeSource(kind: "github.search", query: "is:open is:pr review-requested:@me archived:false", limit: 30)),
        Recipe(id: "gh-stale-prs", title: "Stale pull requests", summary: "Open PRs nobody has touched in a while, with a suggestion for each.",
               symbol: "hourglass", category: "GitHub",
               instructions: "You help a developer clean up old pull requests. " + rules,
               template: "These open pull requests haven't been updated in at least {{days}} days. Don't repeat the counts. For each listed PR write one bullet: its repo#number, then one action (merge, ask for review, rebase or close), then a reason of a few words based on that PR's own title, age and labels. Security fixes should be merged or reviewed, not closed. Pattern: \"- REPO#NUMBER: ACTION. REASON.\"\n\n{{input}}",
               params: [RecipeParam(key: "days", label: "Idle for days", defaultValue: "14"), scope, repo], temperature: 0.2, permissive: true,
               source: RecipeSource(kind: "github.search", query: "is:open is:pr archived:false {{owners}} updated:<{{date-{{days}}}}", limit: 100, order: "oldest")),
        Recipe(id: "gh-incidents", title: "Incident status", summary: "Open issues labeled as incidents: what's broken, where it stands and the next step.",
               symbol: "flame", category: "GitHub",
               instructions: "You write incident status updates for an engineering team. Be factual and brief. " + rules + " If the thread doesn't say something, write \"not stated\".",
               template: "Write a status update for these open incidents. For each incident read in full, give: what is broken, current status, who is working on it, the last update and the next step. For incidents only listed, give one line each. Most severe first.\n\n{{input}}",
               params: [RecipeParam(key: "labels", label: "Incident labels", defaultValue: "incident,sev1,sev2,outage",
                                    help: "Comma-separated; an issue with any of them counts."), scope, repo],
               temperature: 0.2, permissive: true, long: .reduce,
               source: RecipeSource(kind: "github.each", query: "is:open is:issue archived:false {{owners}} label:{{labels}}", limit: 20, each: 3)),
        Recipe(id: "gh-postmortem", title: "Postmortem draft", summary: "A blameless postmortem drafted from an incident's issue thread.",
               symbol: "doc.text.magnifyingglass", category: "GitHub",
               instructions: "You draft blameless postmortems. Describe systems and events, never blame people. Use only the thread given; write \"Not stated\" for anything it doesn't say.",
               template: "Draft a postmortem in Markdown from this incident thread, with these sections: \"## Summary\", \"## Impact\", \"## Timeline\" (dated bullets), \"## Root cause\", \"## What went well\", \"## What to improve\" and \"## Action items\" (bullets, with an owner when the thread names one).\n\n{{input}}",
               params: [RecipeParam(key: "ref", label: "Incident", defaultValue: "", help: "owner/repo#123 or the issue's URL.")],
               temperature: 0.2, permissive: true, long: .reduce,
               source: RecipeSource(kind: "github.thread", ref: "{{ref}}", diff: false)),
        Recipe(id: "gh-ci-failures", title: "CI failures", summary: "Why GitHub Actions runs failed, from the failing steps and their logs.",
               symbol: "xmark.octagon", category: "GitHub",
               instructions: "You explain CI failures to a developer. Quote the error line when there is one. Say \"unclear from the log\" rather than guess. Use only the material given.",
               template: "Explain the failures read in full below; the first line says how many. Write one short paragraph per failure, starting with its run number, saying what failed, the error line if there is one, the likely cause and what to try. Use only run numbers that appear below. If there is more than one, end with one sentence on whether they share a cause.\n\n{{input}}",
               params: [RecipeParam(key: "repo", label: "Repo", defaultValue: "", help: "owner/name. Empty means the repo in the current folder."),
                        RecipeParam(key: "branch", label: "Branch", defaultValue: "main", help: "all means every branch.")],
               temperature: 0.2, permissive: true, long: .reduce,
               source: RecipeSource(kind: "github.runs", repo: "{{repo}}", branch: "{{branch}}", limit: 10, each: 3)),
    ]
}

import Foundation
import AFMKit

public struct GitHubDigest: Sendable {
    public struct Section: Sendable, Identifiable { public let id = UUID(); public let title: String; public let items: [GHIssue] }
    public let login: String
    public let days: Int
    public let sections: [Section]
    public let summary: String

    public var markdown: String {
        var out = "# GitHub digest for @\(login) (last \(days) day\(days == 1 ? "" : "s"))\n\n\(summary)\n"
        for s in sections where !s.items.isEmpty {
            out += "\n## \(s.title)\n"
            for i in s.items { out += "- [\(i.ref)](\(i.htmlUrl)) \(i.title)\n" }
        }
        return out
    }
}

public struct TriageResult: Sendable {
    public let ref: GHRef
    public let title: String
    public let json: String
    public let duplicates: [(issue: GHIssue, score: Double)]
    public let result: GenerationResult

    public var markdown: String {
        var s = "Triage for \(ref): \(title)\n\n```json\n\(json)\n```"
        if !duplicates.isEmpty {
            s += "\n\nPossible duplicates:\n" + duplicates.map { "- \($0.issue.ref) \($0.issue.title) (similarity \(Int($0.score * 100))%)" }.joined(separator: "\n")
        }
        return s
    }
}

public struct PRDraft: Sendable {
    public let title: String
    public let body: String
    public let repo: String?
    public let base: String
    public let head: String
    public let result: GenerationResult
    public var url: URL? { repo.flatMap { GitHubLinks.newPR($0, base: base, head: head, title: title, body: body) } }
    public var markdown: String { "# \(title)\n\n\(body)" }
}

public struct IssueDraft: Sendable, Identifiable, Hashable {
    public let id = UUID()
    public let repo: String
    public var title: String
    public var body: String
    public var labels: [String]
    public var url: URL? { GitHubLinks.newIssue(repo, title: title, body: body, labels: labels) }
}

/// GitHub work done by the on-device model. Everything here reads from GitHub or local git
/// and produces text; nothing writes to GitHub.
public enum GitHubWorkflows {
    public typealias Progress = @Sendable (String) -> Void

    static func clip(_ s: String?, _ n: Int) -> String {
        guard let s, !s.isEmpty else { return "" }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= n ? t : String(t.prefix(n)) + " …[truncated]"
    }

    static func recipe(_ id: String, _ instructions: String, _ template: String, schema: String? = nil, long: LongStrategy = .reduce, temperature: Double = 0.2) -> Recipe {
        Recipe(id: id, title: id, summary: "", instructions: instructions, template: template, schema: schema,
               temperature: temperature, permissive: true, long: long)
    }

    static func log(_ source: String, _ kind: String, _ title: String, _ input: String, _ r: GenerationResult) {
        History.append(HistoryEntry(source: source, kind: kind, title: title, input: input, output: r.text, seconds: r.seconds, outputTokens: r.outputTokens))
    }

    // MARK: Threads

    /// Title, body, comments and (for PRs) the changed files, as plain text for the model.
    public static func threadText(_ gh: GitHubClient, _ ref: GHRef, includeDiff: Bool = true) async throws -> (issue: GHIssue, text: String) {
        let issue = try await gh.issue(ref)
        var text = "\(issue.isPR ? "Pull request" : "Issue") \(ref): \(issue.title)\n"
        text += "State: \(issue.state)\(issue.draft == true ? " (draft)" : "") · Author: \(issue.user?.login ?? "?") · Opened \(issue.createdAt.prefix(10))\n"
        if !issue.labels.isEmpty { text += "Labels: \(issue.labels.map(\.name).joined(separator: ", "))\n" }
        text += "\nDescription:\n\(clip(issue.body, 4000).isEmpty ? "(none)" : clip(issue.body, 4000))\n"
        if issue.isPR {
            let pr = try await gh.pull(ref)
            let files = try await gh.pullFiles(ref)
            text += "\nBranch \(pr.head.ref) into \(pr.base.ref)\(pr.merged == true ? " (merged)" : ""). \(files.count) files, +\(pr.additions ?? 0) -\(pr.deletions ?? 0).\n"
            text += files.prefix(40).map { "- \($0.status) \($0.filename) (+\($0.additions) -\($0.deletions))" }.joined(separator: "\n") + "\n"
            if includeDiff {
                var budget = 18000
                for f in files.sorted(by: { $0.additions + $0.deletions > $1.additions + $1.deletions }) {
                    guard let p = f.patch, budget > 0 else { continue }
                    let chunk = clip(p, min(2500, budget))
                    text += "\nDiff of \(f.filename):\n\(chunk)\n"
                    budget -= chunk.count
                }
            }
        }
        if issue.comments > 0 {
            let cs = try await gh.comments(ref)
            text += "\nComments (\(cs.count)):\n" + cs.prefix(30).map { "- \($0.user?.login ?? "?"): \(clip($0.body, 700))" }.joined(separator: "\n") + "\n"
        }
        return (issue, text)
    }

    public static func summarize(_ ref: GHRef, source: String = "studio", onPartial: (@Sendable (String) -> Void)? = nil, onProgress: Progress? = nil) async throws -> GenerationResult {
        let gh = try GitHubClient.make()
        onProgress?("Reading \(ref) from GitHub")
        let (issue, text) = try await threadText(gh, ref)
        let r = recipe("_gh_summary",
                       "You summarize GitHub issues and pull requests for a busy maintainer. Be specific and factual. Use only the given text.",
                       "Summarize this GitHub \(issue.isPR ? "pull request" : "issue") as short Markdown bullet points. Cover what it is about, what changed or was proposed, the current state, any disagreements, and what is needed next.\n\n{{input}}")
        onProgress?("Summarizing on device")
        let res = try await RecipeRunner.run(r, input: text, onPartial: onPartial, onProgress: { p in onProgress?(p.stage) })
        log(source, "github.summary", "\(ref) \(issue.title)", text, res)
        return res
    }

    // MARK: Triage

    static let stopwords: Set<String> = ["the", "and", "for", "with", "when", "this", "that", "from", "not", "are", "does", "doesn", "can", "cannot", "into", "after", "should", "have", "has", "but", "you", "your", "our"]

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 && !stopwords.contains($0) })
    }

    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    public static func triage(_ ref: GHRef, source: String = "studio", onProgress: Progress? = nil) async throws -> TriageResult {
        let gh = try GitHubClient.make()
        onProgress?("Reading \(ref) and the repo's labels")
        let (issue, text) = try await threadText(gh, ref, includeDiff: false)
        let labels = (try? await gh.labels(ref.slug))?.map(\.name).prefix(40).map { $0 } ?? []
        let others = ((try? await gh.openIssues(ref.slug, limit: 100)) ?? []).filter { $0.number != issue.number }

        var labelSchema: [String: Any] = ["type": "string"]
        if !labels.isEmpty { labelSchema["enum"] = labels }
        let schema: [String: Any] = [
            "type": "object", "title": "Triage",
            "properties": [
                "type": ["type": "string", "enum": ["bug", "feature", "question", "docs", "chore", "security", "other"]],
                "priority": ["type": "string", "enum": ["high", "medium", "low"]],
                "summary": ["type": "string", "description": "One sentence"],
                "suggested_labels": ["type": "array", "maxItems": 4, "items": labelSchema],
                "needs_more_info": ["type": "boolean"],
                "missing_info": ["type": "string", "description": "What the reporter should add, or an empty string"],
                "reason": ["type": "string", "description": "Why this type and priority"],
            ],
            "required": ["type", "priority", "summary", "suggested_labels", "needs_more_info", "missing_info", "reason"],
            "x-order": ["type", "priority", "summary", "suggested_labels", "needs_more_info", "missing_info", "reason"],
        ]
        let r = recipe("_gh_triage",
                       "You triage GitHub issues and pull requests for a maintainer. Judge priority by user impact. Only suggest labels from the allowed list. Type is what the item changes or asks for: new or improved behavior is a feature, broken behavior is a bug. A title that starts with feat:, fix:, docs: or chore: states its type. Never describe user feelings the text doesn't state.",
                       "Triage this item.\(labels.isEmpty ? "" : " Allowed labels: \(labels.joined(separator: ", ")).")\n\n{{input}}",
                       schema: JSONSchemaConverter.jsonText(schema), long: .merge, temperature: 0.1)
        onProgress?("Triaging on device")
        let res = try await RecipeRunner.run(r, input: clip(text, 9000))
        let me = issue.title + " " + clip(issue.body, 300)
        let dups = others.map { ($0, similarity(me, $0.title + " " + clip($0.body, 300))) }
            .filter { $0.1 >= 0.25 }.sorted { $0.1 > $1.1 }.prefix(3).map { (issue: $0.0, score: $0.1) }
        log(source, "github.triage", "\(ref) \(issue.title)", text, res)
        return TriageResult(ref: ref, title: issue.title, json: res.text, duplicates: Array(dups), result: res)
    }

    // MARK: Digest

    public static func digest(days: Int = 1, source: String = "studio", onProgress: Progress? = nil) async throws -> GitHubDigest {
        let gh = try GitHubClient.make()
        onProgress?("Checking who you are on GitHub")
        let login = try await gh.me().login
        let since = Calendar.current.date(byAdding: .day, value: -max(1, days), to: Date())!
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let d = f.string(from: since)
        let queries: [(String, String)] = [
            ("Waiting on your review", "is:open is:pr review-requested:\(login) archived:false"),
            ("Assigned to you", "is:open assignee:\(login) archived:false"),
            ("Mentioning you", "mentions:\(login) updated:>=\(d) archived:false"),
            ("Your open pull requests", "is:open is:pr author:\(login) archived:false"),
            ("Recent activity you're involved in", "involves:\(login) updated:>=\(d) archived:false"),
        ]
        var seen = Set<Int>()
        var sections: [GitHubDigest.Section] = []
        for (title, q) in queries {
            onProgress?("Searching: \(title.lowercased())")
            let items = try await gh.search(q, limit: 25).filter { seen.insert($0.id).inserted }
            sections.append(.init(title: title, items: items))
        }
        let lines = sections.flatMap { s in s.items.prefix(12).map { "[\(s.title)] \($0.ref) \($0.isPR ? "PR" : "issue"): \($0.title) (updated \($0.updatedAt.prefix(10)))" } }
        var summary = "Nothing needs you right now."
        if !lines.isEmpty {
            onProgress?("Writing your briefing on device")
            summary = try await AFM.generate(
                "Here is my GitHub activity. Write a 3 to 5 sentence briefing: what needs my attention first and why, then what can wait. Mention items by repo and number.\n\n" + lines.prefix(45).joined(separator: "\n"),
                instructions: "You are a concise engineering assistant writing a morning briefing. Use only the items given.",
                options: GenOptions(temperature: 0.3), config: ModelConfig(guardrails: .permissive))
        }
        let digest = GitHubDigest(login: login, days: days, sections: sections, summary: summary)
        History.append(HistoryEntry(source: source, kind: "github.digest", title: "Digest @\(login)", input: lines.joined(separator: "\n"), output: digest.markdown, seconds: 0))
        return digest
    }

    // MARK: PR descriptions

    static let prRecipe = recipe("_gh_pr",
        "You write clear, honest pull request descriptions for reviewers. Use only the material given. Never invent tests or results, and never describe a file the material doesn't explain. Call it a pull request or this change, not a release.",
        "Write a pull request description in Markdown with three sections: \"## Summary\" (two or three sentences), \"## Changes\" (one bullet point per entry under \"What each file's change does\", and none for any other file), and \"## Testing\" (how to verify; if the material doesn't say, write only \"Not stated\").\n\n{{input}}")

    static func titleFor(_ commits: [String], body: String) async -> String {
        if commits.count == 1, let s = commits.first?.split(separator: "\n").first { return String(s) }
        // The commit subjects say what the branch is for; the description alone gave titles about one detail.
        let subjects = commits.prefix(12).compactMap { $0.split(separator: "\n").first.map { "- \($0)" } }.joined(separator: "\n")
        let t = (try? await AFM.generate("Write one pull request title, under 70 characters, imperative mood, no quotes, that covers the whole branch.\n\nCommits:\n\(subjects)\n\nDescription:\n" + clip(body, 1200),
                                         options: GenOptions(temperature: 0.2, maxTokens: 40), config: ModelConfig(guardrails: .permissive))) ?? "Update"
        return t.split(separator: "\n").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' #")) } ?? "Update"
    }

    /// Splits a unified diff into (file, patch) pairs.
    public static func filePatches(_ diff: String) -> [(String, String)] {
        diff.components(separatedBy: "\ndiff --git ").enumerated().compactMap { i, chunk in
            let c = i == 0 ? (chunk.hasPrefix("diff --git ") ? String(chunk.dropFirst(11)) : chunk) : chunk
            guard let first = c.split(separator: "\n").first, let b = first.range(of: " b/") else { return nil }
            return (String(first[b.upperBound...]), c)
        }
    }

    /// One sentence per changed file (largest first, up to `limit`), so the final description sees every file.
    /// A patch without its unchanged context lines: the hunk headers and the lines added or removed.
    /// Reading is cheap for the model but not free, and context lines are most of a patch.
    public static func changedLines(_ patch: String) -> String {
        patch.split(separator: "\n", omittingEmptySubsequences: false).filter { l in
            !(l.hasPrefix(" ") || l.hasPrefix("index ") || l.hasPrefix("--- ") || l.hasPrefix("+++ ") || l == "\\ No newline at end of file")
        }.joined(separator: "\n")
    }

    static func fileNotes(_ patches: [(String, String)], limit: Int = 6, onProgress: Progress?) async throws -> String {
        let ranked = patches.map { ($0.0, changedLines($0.1)) }.sorted { $0.1.count > $1.1.count }
        var notes: [String] = []
        for (i, p) in ranked.prefix(limit).enumerated() {
            onProgress?("Reading \(p.0) (\(i + 1) of \(min(limit, ranked.count)))")
            let s = try await AFM.generate("In one short sentence of at most 25 words, what does this change to \(p.0) do? Name concrete functions, settings or behavior in plain words, without quoting code. Lines starting with + were added and - removed.\n\n" + clip(p.1, 4000),
                                           instructions: "You explain code changes to reviewers. One factual sentence. No preamble.",
                                           options: GenOptions(temperature: 0.1, maxTokens: 70), config: ModelConfig(guardrails: .permissive))
            notes.append("- \(p.0): \(s.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        // Listing the rest here made the model write a bullet for each with an invented description.
        // They still appear under "Files changed".
        return notes.joined(separator: "\n")
    }

    static func composePR(_ header: String, commits: [String], stat: String, notes: String, onPartial: (@Sendable (String) -> Void)?, onProgress: Progress?) async throws -> GenerationResult {
        let material = header + "\n\nCommits:\n" + commits.prefix(40).map { "- " + clip($0, 300) }.joined(separator: "\n")
            + "\n\nFiles changed:\n" + clip(stat, 1500) + "\n\nWhat each file's change does:\n" + notes
        onProgress?("Writing the description")
        return try await RecipeRunner.run(prRecipe, input: material, onPartial: onPartial, onProgress: { p in onProgress?(p.stage) })
    }

    /// From a local branch: commits and diff against the default branch.
    public static func prDescription(local: LocalRepo, base: String? = nil, source: String = "studio", onPartial: (@Sendable (String) -> Void)? = nil, onProgress: Progress? = nil) async throws -> PRDraft {
        let baseRef = base ?? local.defaultBase
        let head = local.currentBranch
        onProgress?("Reading \(head) against \(baseRef)")
        let commits = try local.commits("\(baseRef)..HEAD")
        guard !commits.isEmpty else { throw AFMError(code: "no_changes", message: "\(head) has no commits that aren't on \(baseRef).") }
        let notes = try await fileNotes(filePatches(try local.diff("\(baseRef)...HEAD")), onProgress: onProgress)
        let res = try await composePR("Branch \(head) into \(baseRef).", commits: commits, stat: try local.diffStat("\(baseRef)...HEAD"),
                                      notes: notes, onPartial: onPartial, onProgress: onProgress)
        let title = await titleFor(commits, body: res.text)
        log(source, "github.pr-description", title, notes, res)
        let baseBranch = baseRef.replacingOccurrences(of: "origin/", with: "")
        return PRDraft(title: title, body: res.text, repo: local.githubSlug, base: baseBranch, head: head, result: res)
    }

    /// For an existing pull request on GitHub (to rewrite or fill in its description).
    public static func prDescription(ref: GHRef, source: String = "studio", onPartial: (@Sendable (String) -> Void)? = nil, onProgress: Progress? = nil) async throws -> PRDraft {
        let gh = try GitHubClient.make()
        onProgress?("Reading \(ref)")
        let pr = try await gh.pull(ref)
        let files = try await gh.pullFiles(ref)
        let commits: [GHCommit] = (try? await gh.get("/repos/\(ref.slug)/pulls/\(ref.number ?? 0)/commits", ["per_page": "100"])) ?? []
        let notes = try await fileNotes(files.map { ($0.filename, $0.patch ?? "(binary or too large to show)") }, onProgress: onProgress)
        let stat = files.map { "\($0.filename) +\($0.additions) -\($0.deletions)" }.joined(separator: "\n")
        let res = try await composePR("Pull request \(ref): \(pr.title)\nCurrent description: \(clip(pr.body, 800))\nBranch \(pr.head.ref) into \(pr.base.ref).",
                                      commits: commits.map(\.commit.message), stat: stat, notes: notes, onPartial: onPartial, onProgress: onProgress)
        log(source, "github.pr-description", pr.title, notes, res)
        return PRDraft(title: pr.title, body: res.text, repo: ref.slug, base: pr.base.ref, head: pr.head.ref, result: res)
    }

    // MARK: Release notes

    static let groups: [(String, [String])] = [
        ("Features", ["feat"]), ("Fixes", ["fix"]), ("Performance", ["perf"]), ("Security", ["security", "sec"]),
        ("Documentation", ["docs"]), ("Maintenance", ["chore", "refactor", "build", "ci", "test", "style", "deps"]),
    ]

    public static func group(_ subjects: [String]) -> [(String, [String])] {
        var out: [String: [String]] = [:]
        for s in subjects {
            var title = "Other"
            var text = s
            if let colon = s.firstIndex(of: ":") {
                let prefix = s[..<colon].lowercased()
                let type = prefix.split(separator: "(").first.map { String($0).replacingOccurrences(of: "!", with: "") } ?? ""
                if let g = groups.first(where: { $0.1.contains(type) }) {
                    title = g.0
                    text = s[s.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
            out[title, default: []].append(text)
        }
        return (groups.map(\.0) + ["Other"]).compactMap { k in out[k].map { (k, $0) } }
    }

    /// Release notes from commits between two refs. Pass a local repo, or a GitHub slug.
    public static func releaseNotes(local: LocalRepo? = nil, slug: String? = nil, from: String? = nil, to: String = "HEAD",
                                    source: String = "studio", onProgress: Progress? = nil) async throws -> GenerationResult {
        let start = Date()
        var subjects: [String] = []
        var fromRef = from
        if let local {
            fromRef = fromRef ?? local.latestTag
            let range = fromRef.map { "\($0)..\(to)" } ?? to
            onProgress?("Reading commits \(range)")
            subjects = try local.commits(range, limit: fromRef == nil ? 50 : 400).compactMap { $0.split(separator: "\n").first.map(String.init) }
        } else if let slug {
            let gh = try GitHubClient.make()
            if fromRef == nil { fromRef = try await gh.latestTag(slug) }
            onProgress?("Reading commits from GitHub")
            if let f = fromRef {
                subjects = try await gh.compare(slug, base: f, head: to == "HEAD" ? (try await gh.repo(slug).defaultBranch) : to).commits.map(\.subject)
            } else {
                subjects = try await gh.commits(slug, limit: 50).map(\.subject)
            }
        } else {
            throw AFMError(code: "no_repo", message: "Give a local repo path or a GitHub repo.")
        }
        let trivial: Set<String> = ["initial commit", "init", "wip", "update", "updates", "first commit"]
        subjects = subjects.filter { !$0.lowercased().hasPrefix("merge ") && !trivial.contains($0.lowercased().trimmingCharacters(in: .whitespaces)) }
        guard !subjects.isEmpty else { throw AFMError(code: "no_changes", message: "No commits found in that range.") }

        let rewrite = recipe("_gh_release_group",
                             "You turn commit subjects into release notes for users. Plain language, no commit jargon, no hashes.",
                             "Rewrite these commit subjects as Markdown bullet points for release notes. Merge duplicates and drop trivial ones. Keep each bullet under 20 words.\n\n{{input}}",
                             long: .concatenate)
        var body = ""
        for (title, items) in group(subjects) {
            var bullets: [String]
            if items.count <= 3 {
                bullets = items.map { "- " + $0.prefix(1).uppercased() + $0.dropFirst() }
            } else {
                onProgress?("Writing \(title.lowercased())")
                let r = try await RecipeRunner.run(rewrite, input: items.map { "- " + $0 }.joined(separator: "\n"),
                                                   options: GenOptions(maxTokens: min(900, 60 + items.count * 45)))
                bullets = r.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("-") || $0.hasPrefix("*") }
            }
            // Small models sometimes repeat themselves; keep each bullet once, and never more than one per commit.
            var seen = Set<String>()
            bullets = bullets.filter { seen.insert($0.lowercased()).inserted }.prefix(items.count).map { $0 }
            body += "\n### \(title)\n\n" + bullets.joined(separator: "\n") + "\n"
        }
        var highlights = ""
        if subjects.count >= 4 {
            onProgress?("Writing highlights")
            highlights = try await AFM.generate("Write two sentences highlighting the most important changes in these release notes. Restate only what the notes say; add nothing.\n\n" + clip(body, 6000),
                                                instructions: "You write crisp release highlights. Never mention anything that isn't in the notes.",
                                                options: GenOptions(temperature: 0.2, maxTokens: 160), config: ModelConfig(guardrails: .permissive))
            if !isProseHighlight(highlights) { highlights = "" }
        }
        let header = "## Release notes\(fromRef.map { " (\($0) → \(to))" } ?? "")\n" + (highlights.isEmpty ? "" : "\n\(highlights.trimmingCharacters(in: .whitespacesAndNewlines))\n")
        let res = GenerationResult(text: header + body, seconds: Date().timeIntervalSince(start))
        log(source, "github.release-notes", slug ?? local?.path ?? "", subjects.joined(separator: "\n"), res)
        return res
    }

    /// Asked for two sentences, the model sometimes copies the notes (headings and bullets),
    /// which then printed every section twice. Only plain prose of a few sentences is kept.
    public static func isProseHighlight(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 600 else { return false }
        return !t.split(separator: "\n").contains { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            return l.hasPrefix("#") || l.hasPrefix("- ") || l.hasPrefix("* ")
        }
    }

    // MARK: Repo brief and next steps

    static func repoMaterial(_ gh: GitHubClient, _ slug: String, readmeChars: Int) async throws -> (GHRepo, [GHIssue], String) {
        let repo = try await gh.repo(slug)
        let readme = (try? await gh.readme(slug)) ?? ""
        let commits = (try? await gh.commits(slug, limit: 15)) ?? []
        let open = (try? await gh.openIssues(slug, limit: 40)) ?? []
        let release = try? await gh.latestRelease(slug)
        var m = "Repository \(repo.fullName)\(repo.private ? " (private)" : "")\(repo.archived ? " (archived)" : "")\n"
        m += "Description: \(repo.description ?? "none") · Language: \(repo.language ?? "?") · Stars: \(repo.stargazersCount) · Last push: \(repo.pushedAt?.prefix(10) ?? "?")\n"
        // Without this the model called a "release: x.y" commit the stable release, though it was never published.
        m += "Latest published release: " + (release.map { "\($0.tagName) (\($0.publishedAt?.prefix(10) ?? "date unknown"))" } ?? "none") + "\n"
        m += "\nRecent commits:\n" + commits.map { "- \($0.commit.author?.date?.prefix(10) ?? "") \($0.subject)" }.joined(separator: "\n")
        let prs = open.filter(\.isPR), issues = open.filter { !$0.isPR }
        m += "\n\nOpen pull requests (\(prs.count)):\n" + prs.prefix(15).map { "- #\($0.number) \($0.title)" }.joined(separator: "\n")
        m += "\n\nOpen issues (\(issues.count)):\n" + issues.prefix(20).map { "- #\($0.number) \($0.title)\($0.labels.isEmpty ? "" : " [\($0.labels.map(\.name).joined(separator: ", "))]")" }.joined(separator: "\n")
        m += "\n\nREADME:\n" + clip(readme, readmeChars)
        return (repo, open, m)
    }

    public static func repoBrief(_ slug: String, source: String = "studio", onPartial: (@Sendable (String) -> Void)? = nil, onProgress: Progress? = nil) async throws -> GenerationResult {
        let gh = try GitHubClient.make()
        onProgress?("Reading \(slug)")
        let (_, _, material) = try await repoMaterial(gh, slug, readmeChars: 6000)
        let r = recipe("_gh_brief",
                       "You brief an engineer on a software project. Be concrete and honest about its state. Use only the material given. The latest release is the one the material lists as published; a commit that mentions a release is not one.",
                       "Write a project brief in Markdown with these sections: \"## What it is\", \"## Current state\", \"## Recent activity\", \"## Open work\", and \"## Suggested next steps\" (three to five bullets).\n\n{{input}}")
        onProgress?("Writing the brief on device")
        let res = try await RecipeRunner.run(r, input: material, onPartial: onPartial, onProgress: { p in onProgress?(p.stage) })
        log(source, "github.repo-brief", slug, material, res)
        return res
    }

    /// The parts of a roadmap that aren't done: sections whose status says shipped or fixed are left
    /// out, so the model plans from open work rather than re-proposing finished work.
    public static func openRoadmap(_ text: String) -> String {
        let parts = text.components(separatedBy: "\n### ").flatMap { $0.components(separatedBy: "\n## ") }
        return parts.filter { part in
            guard let status = part.range(of: "**Status.**") else { return true }
            let line = part[status.upperBound...].prefix { $0 != "\n" }.lowercased()
            return !(line.contains("fixed") || line.contains("shipped") || line.contains("added in") || line.contains("added for") || line.contains("done"))
                || line.contains("still to do") || line.contains("except")
        }.joined(separator: "\n\n")
    }

    /// Drafts up to five issues for sensible next steps. Opening them is up to you.
    public static func nextSteps(_ slug: String, focus: String? = nil, source: String = "studio", onProgress: Progress? = nil) async throws -> [IssueDraft] {
        let gh = try GitHubClient.make()
        onProgress?("Reading \(slug)")
        var (_, _, material) = try await repoMaterial(gh, slug, readmeChars: 3000)
        // Without the project's own plans the model guessed, calling recent fixes "incomplete". A
        // roadmap's open items give it real next steps to draft.
        if let roadmap = try? await gh.file(slug, path: "ROADMAP.md"), !roadmap.isEmpty {
            material += "\n\nROADMAP.md (the project's own plans):\n" + clip(Self.openRoadmap(roadmap), 3500)
        }
        let labels = (try? await gh.labels(slug))?.map(\.name).prefix(40).map { $0 } ?? []
        var labelSchema: [String: Any] = ["type": "string"]
        if !labels.isEmpty { labelSchema["enum"] = labels }
        let schema: [String: Any] = [
            "type": "object", "title": "NextSteps",
            "properties": ["issues": ["type": "array", "maxItems": 5, "items": [
                "type": "object", "title": "IssueDraft",
                "properties": [
                    "title": ["type": "string", "description": "Imperative, under 70 characters"],
                    "body": ["type": "string", "description": "Markdown: context, what to do, and how to know it's done"],
                    "labels": ["type": "array", "maxItems": 3, "items": labelSchema],
                ],
                "required": ["title", "body", "labels"], "x-order": ["title", "body", "labels"],
            ]]],
            "required": ["issues"],
        ]
        let r = recipe("_gh_next",
                       "You plan practical next steps for a software project. Base every issue on one specific item in the material, such as a roadmap item that isn't done, an open issue, or a limit the README states, and name that item in the body. Each issue comes from a different item. Put known bugs first, then unfinished features; skip cosmetic tweaks such as wording or icons. Fewer good issues beat five weak ones. Never claim that existing work is broken or incomplete unless the material says so. Don't duplicate work that is already in an open issue or pull request. Name a file, folder or path only if it appears in the material. Suggest documentation work only when an issue asks for it or the material shows the topic is missing; never for something the README already covers.",
                       "Suggest up to five next-step issues for this project\(focus.map { ", focused on: \($0)" } ?? "").\n\n{{input}}",
                       schema: JSONSchemaConverter.jsonText(schema), long: .merge, temperature: 0.4)
        onProgress?("Planning on device")
        let res = try await RecipeRunner.run(r, input: material)
        log(source, "github.next-steps", slug, material, res)
        guard let d = res.text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let items = obj["issues"] as? [[String: Any]] else { return [] }
        return items.compactMap { i in
            guard let t = i["title"] as? String, !t.isEmpty else { return nil }
            return IssueDraft(repo: slug, title: t, body: (i["body"] as? String) ?? "", labels: (i["labels"] as? [String]) ?? [])
        }
    }
}

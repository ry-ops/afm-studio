import Foundation
import AFMKit
import FoundationModels

/// The GitHub integration: read-only, drafts only. Nothing here writes to GitHub.
public struct GitHubIntegration: AFMIntegration {
    public static let integrationID = "github"
    /// Items `github_read` reads in one answer. Each result stays in the 4K context, and more than this overflowed it.
    static let readsPerAnswer = 2
    public init() {}
    public let id = GitHubIntegration.integrationID
    public let name = "GitHub"
    public let symbol = "chevron.left.forwardslash.chevron.right"
    public let summary = "Summaries, triage, digests, PR descriptions, release notes, repo briefs and blog drafts. Read-only; everything it writes is a draft for you."

    public let manifest = IntegrationManifest(
        credentials: ["A GitHub token from your Keychain, or your existing `gh` login"],
        hosts: ["api.github.com", "GitHub's log storage, for the CI failures recipe"],
        writes: .draftsOnly,
        dataNote: "Repo lists and your blog setup are saved on this Mac. Reading and drafting happen on device; nothing is posted, labeled or committed for you.")

    public var recipes: [Recipe] { GitHubRecipes.all }

    public func fetch(_ source: RecipeSource, values: [String: String], onProgress: (@Sendable (String) -> Void)?) async throws -> SourceMaterial? {
        try await GitHubSources.fetch(source, values: values, onProgress: onProgress)
    }

    public func status() async -> IntegrationStatus {
        guard IntegrationRegistry.isEnabled(id) else { return IntegrationStatus(connected: false, detail: "Turned off.") }
        let auth = GitHubAuth.resolve()
        guard auth.token != nil else { return IntegrationStatus(connected: false, detail: "Not signed in. Run `gh auth login` or add a token.") }
        do {
            let me = try await GitHubClient.make().me()
            return IntegrationStatus(connected: true, detail: "Signed in as @\(me.login) via \(GitHubAuth.sourceDescription).")
        } catch {
            return IntegrationStatus(connected: false, detail: AFMError.from(error).fullDescription)
        }
    }

    // MARK: Tools for the on-device model (chat). Few and small: every definition uses the 4K context.

    public func modelTools(tracker: ToolCallTracker?) -> [any Tool] {
        func args(_ name: String, _ props: [(String, String)]) -> GenerationSchema {
            try! GenerationSchema(root: DynamicGenerationSchema(name: name, properties: props.map {
                .init(name: $0.0, description: $0.1, schema: .init(type: String.self))
            }), dependencies: [])
        }
        @Sendable func str(_ c: GeneratedContent, _ k: String) -> String { ((try? c.value(String?.self, forProperty: k)) ?? nil) ?? "" }
        return [
            DynamicTool(name: "github_read", description: "Read one GitHub issue or pull request: its description and recent comments. Pass owner/repo#number or a URL.",
                        parameters: args("GHReadArgs", [("ref", "owner/repo#number or a github.com URL")])) { a in
                let raw = str(a, "ref")
                tracker?.record("github_read(\(raw))")
                if (tracker?.callsThisTurn("github_read(") ?? 0) > GitHubIntegration.readsPerAnswer {
                    return "Not read: \(GitHubIntegration.readsPerAnswer) items were already read for this answer, which is all that fits. Answer with what you have, and offer to read \(raw) next."
                }
                guard let ref = GHRef.parse(raw), ref.number != nil else { return "Give a reference like owner/repo#123." }
                let (_, text) = try await GitHubWorkflows.threadText(try GitHubClient.make(), ref, includeDiff: false)
                return GitHubWorkflows.clip(text, 1800)
            },
            DynamicTool(name: "github_open_prs", description: "Count and list open pull requests in repositories owned by the user or their organizations, including PRs other people and bots opened.",
                        parameters: args("GHOpenPRsArgs", [("scope", "mine (the user's own repos), orgs (their organizations' repos) or all. Default all.")])) { a in
                let scope = GitHubOpenPRs.Scope(loose: str(a, "scope"))
                tracker?.record("github_open_prs(\(scope.rawValue))")
                let gh = try GitHubClient.make()
                let login = try await gh.me().login
                let orgs = scope == .mine ? [] : try await gh.orgs().map(\.login)
                guard let q = GitHubOpenPRs.query(login: login, orgs: orgs, scope: scope) else { return "The user doesn't belong to any GitHub organizations." }
                let r = try await gh.searchAll(q)
                return GitHubOpenPRs.summary(total: r.total, items: r.items, login: login, orgs: orgs, scope: scope)
            },
            DynamicTool(name: "github_my_work", description: "List what needs the user personally on GitHub: pull requests they wrote, reviews requested from them and items assigned to them.",
                        parameters: args("GHMineArgs", [("scope", "Optional: reviews, assigned or prs")])) { a in
                tracker?.record("github_my_work()")
                let gh = try GitHubClient.make()
                let login = try await gh.me().login
                var out: [String] = []
                for (t, q) in [("Review requested", "is:open is:pr review-requested:\(login)"), ("Assigned", "is:open assignee:\(login)"), ("Your PRs", "is:open is:pr author:\(login)")] {
                    let items = try await gh.search(q + " archived:false", limit: 8)
                    out.append("\(t): " + (items.isEmpty ? "none" : items.map { "\($0.ref) \($0.title)" }.joined(separator: "; ")))
                }
                return GitHubWorkflows.clip(out.joined(separator: "\n"), 2500)
            },
        ]
    }

    // MARK: Tools for Claude (MCP)

    static let ref: [String: Any] = ["type": "string", "description": "owner/repo#number or a github.com issue/PR URL"]
    static let repo: [String: Any] = ["type": "string", "description": "owner/repo"]

    static func parseRef(_ a: [String: Any]) throws -> GHRef {
        guard let s = a.s("ref"), let r = GHRef.parse(s), r.number != nil else {
            throw AFMError(code: "bad_ref", message: "Give `ref` as owner/repo#number or a GitHub URL.")
        }
        return r
    }

    /// The structured reply for a tool whose answer is prose. MCP clients that read
    /// `structuredContent` show it in place of the text block, so the text goes in it too.
    static func meta(_ r: GenerationResult) -> [String: Any] { ["text": r.text, "seconds": (r.seconds * 10).rounded() / 10, "chunks": r.chunks] }

    public var mcpTools: [IntegrationTool] {
        [
            IntegrationTool(name: "afm_github_summarize", title: "Summarize GitHub issue or PR",
                            description: "Read a GitHub issue or pull request (description, comments and diff) and summarize it on device. Saves your context: the thread and diff never enter it.",
                            properties: ["ref": Self.ref], required: ["ref"]) { a in
                let r = try await GitHubWorkflows.summarize(try Self.parseRef(a), source: "mcp")
                return IntegrationOutput(text: r.text, json: Self.meta(r))
            },
            IntegrationTool(name: "afm_github_triage", title: "Triage GitHub issue or PR",
                            description: "Classify type and priority, suggest labels from the repo's own label set, flag missing information and list possible duplicates. Returns JSON. Does not apply labels.",
                            properties: ["ref": Self.ref], required: ["ref"]) { a in
                let t = try await GitHubWorkflows.triage(try Self.parseRef(a), source: "mcp")
                var json = (try? JSONSerialization.jsonObject(with: Data(t.json.utf8))) as? [String: Any] ?? [:]
                json["possible_duplicates"] = t.duplicates.map { ["ref": $0.issue.ref, "title": $0.issue.title, "similarity": (($0.score * 100).rounded()) / 100] }
                return IntegrationOutput(text: t.markdown, json: json)
            },
            IntegrationTool(name: "afm_github_digest", title: "GitHub digest",
                            description: "What needs the user on GitHub: review requests, assignments, mentions, their open PRs and recent activity, with a short on-device briefing.",
                            properties: ["days": ["type": "integer", "minimum": 1, "maximum": 30, "description": "How far back to look (default 1)"]]) { a in
                let d = try await GitHubWorkflows.digest(days: a.i("days") ?? 1, source: "mcp")
                return IntegrationOutput(text: d.markdown)
            },
            IntegrationTool(name: "afm_github_pr_description", title: "Draft PR description",
                            description: "Draft a pull request title and description. Give `repo_path` (a local checkout; uses its current branch against the default branch) or `ref` (an existing PR). Returns a draft and a pre-filled GitHub link; nothing is posted.",
                            properties: ["repo_path": ["type": "string", "description": "Local git checkout path"], "base": ["type": "string", "description": "Base branch (default: the repo's default branch)"], "ref": Self.ref]) { a in
                let d: PRDraft
                if let p = a.s("repo_path") { d = try await GitHubWorkflows.prDescription(local: try LocalRepo(path: p), base: a.s("base"), source: "mcp") }
                else { d = try await GitHubWorkflows.prDescription(ref: try Self.parseRef(a), source: "mcp") }
                var json: [String: Any] = ["title": d.title, "body": d.body]
                if let u = d.url { json["open_pr_url"] = u.absoluteString }
                return IntegrationOutput(text: d.markdown + (d.url.map { "\n\nOpen a pre-filled PR: \($0.absoluteString)" } ?? ""), json: json)
            },
            IntegrationTool(name: "afm_github_release_notes", title: "Draft release notes",
                            description: "Draft release notes from commits since the last tag (or `from`). Give `repo_path` for a local checkout or `repo` for GitHub.",
                            properties: ["repo_path": ["type": "string"], "repo": Self.repo, "from": ["type": "string", "description": "Start tag or commit (default: latest tag)"], "to": ["type": "string", "description": "End ref (default HEAD)"]]) { a in
                let r = try await GitHubWorkflows.releaseNotes(local: try a.s("repo_path").map { try LocalRepo(path: $0) }, slug: a.s("repo"),
                                                               from: a.s("from"), to: a.s("to") ?? "HEAD", source: "mcp")
                return IntegrationOutput(text: r.text)
            },
            IntegrationTool(name: "afm_github_repo_brief", title: "Repo brief",
                            description: "Brief on a GitHub repo: what it is, its current state, recent activity, open work and suggested next steps.",
                            properties: ["repo": Self.repo], required: ["repo"]) { a in
                let r = try await GitHubWorkflows.repoBrief(a.s("repo") ?? "", source: "mcp")
                return IntegrationOutput(text: r.text, json: Self.meta(r))
            },
            IntegrationTool(name: "afm_github_next_steps", title: "Draft next-step issues",
                            description: "Draft up to five next-step issues for a repo, each with a pre-filled 'new issue' link. Nothing is created on GitHub.",
                            properties: ["repo": Self.repo, "focus": ["type": "string", "description": "Optional area to focus on"]], required: ["repo"]) { a in
                let drafts = try await GitHubWorkflows.nextSteps(a.s("repo") ?? "", focus: a.s("focus"), source: "mcp")
                let text = drafts.enumerated().map { i, d in "\(i + 1). \(d.title)\n\(d.body)\(d.url.map { "\nOpen pre-filled: \($0.absoluteString)" } ?? "")" }.joined(separator: "\n\n")
                return IntegrationOutput(text: text.isEmpty ? "No suggestions." : text,
                                         json: ["issues": drafts.map { ["title": $0.title, "body": $0.body, "labels": $0.labels, "url": $0.url?.absoluteString ?? ""] }])
            },
            IntegrationTool(name: "afm_github_blog_draft", title: "Draft a blog post",
                            description: "Draft a blog post in the format of the user's blog repo (set up in AFM Studio). Optionally uses a repo's recent work as source material. Saves a Markdown draft locally; nothing is committed.",
                            properties: ["topic": ["type": "string"], "notes": ["type": "string", "description": "Facts, links or bullet notes to build on"],
                                         "source_repo": Self.repo, "days": ["type": "integer", "minimum": 1, "maximum": 90]],
                            required: ["topic"]) { a in
                guard let profile = GitHubSettings.load().blog else {
                    throw AFMError(code: "no_blog", message: "No blog is set up.", suggestion: "Set one up in AFM Studio > GitHub > Blog, or run `afm github blog setup owner/repo`.")
                }
                let d = try await BlogWriter.draft(.init(topic: a.s("topic") ?? "", notes: a.s("notes") ?? "", sourceRepo: a.s("source_repo"),
                                                         sourceDays: a.i("days") ?? 14, engine: .onDevice, profile: profile), source: "mcp")
                return IntegrationOutput(text: "Saved to \(d.savedTo.path)\n\n" + d.markdown, json: ["path": d.savedTo.path, "filename": d.filename, "title": d.title])
            },
        ]
    }
}

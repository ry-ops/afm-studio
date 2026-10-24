import Foundation
import AFMKit

/// How a blog repo stores posts. Learned from the repo itself and kept in local settings.
public struct BlogProfile: Codable, Sendable, Equatable {
    public var repo: String
    public var branch: String
    public var postsPath: String
    public var authorName: String
    public var authorAvatar: String?
    public var categories: [String]
    public var styleGuide: String

    public init(repo: String, branch: String = "main", postsPath: String = "src/content/posts", authorName: String = "",
                authorAvatar: String? = nil, categories: [String] = [], styleGuide: String = BlogProfile.defaultStyle) {
        self.repo = repo; self.branch = branch; self.postsPath = postsPath; self.authorName = authorName
        self.authorAvatar = authorAvatar; self.categories = categories; self.styleGuide = styleGuide
    }

    public static let defaultStyle = "First person. Honest, conversational and technical. Real examples and code over abstractions. No buzzwords."
}

public struct BlogDraft: Sendable {
    public let title: String
    public let slug: String
    public let filename: String
    public let markdown: String
    public let savedTo: URL
    public let profile: BlogProfile
    public let engine: BlogWriter.Engine
    public let seconds: Double
    /// Opens GitHub's "new file" page pre-filled, when the post is short enough for a URL. You commit it yourself.
    public var newFileURL: URL? { GitHubLinks.newFile(profile.repo, branch: profile.branch, dir: profile.postsPath, filename: filename, content: markdown) }
}

public enum BlogWriter {
    public enum Engine: String, Codable, Sendable, CaseIterable, Identifiable {
        case onDevice = "on-device", claude
        public var id: String { rawValue }
        public var title: String { self == .onDevice ? "On-device (private, free)" : "Claude (your API key)" }
    }

    // MARK: Learning a profile

    /// Reads the repo to find the posts folder, author, categories and style notes.
    public static func learn(repo slug: String) async throws -> BlogProfile {
        let gh = try GitHubClient.make()
        let repo = try await gh.repo(slug)
        let paths = try await gh.paths(slug, ref: repo.defaultBranch)
        let posts = paths.filter { ($0.hasSuffix(".md") || $0.hasSuffix(".mdx")) && ($0.contains("content/posts/") || $0.contains("content/blog/") || $0.contains("_posts/") || $0.contains("/posts/")) }
        guard let latest = posts.sorted().last else {
            throw AFMError(code: "no_posts", message: "Couldn't find blog posts in \(slug).", suggestion: "Posts are expected in a folder like src/content/posts.")
        }
        var profile = BlogProfile(repo: slug, branch: repo.defaultBranch, postsPath: (latest as NSString).deletingLastPathComponent)
        let fm = frontmatter(try await gh.file(slug, path: latest))
        profile.authorName = fm.first { $0.0 == "name" }?.1 ?? fm.first { $0.0 == "author" }?.1 ?? ""
        profile.authorAvatar = fm.first { $0.0 == "avatar" }?.1

        // Categories: an enum in the content config if there is one, otherwise the recent posts' categories.
        if let cfg = paths.first(where: { $0.hasSuffix("content.config.ts") || $0.hasSuffix("content/config.ts") }),
           let text = try? await gh.file(slug, path: cfg),
           let r = text.range(of: #"category:\s*z\.enum\(\[([^\]]*)\]"#, options: .regularExpression) {
            profile.categories = text[r].components(separatedBy: "[").last?.components(separatedBy: "]").first?
                .split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \n'\"")) }.filter { !$0.isEmpty } ?? []
        }
        if profile.categories.isEmpty {
            var cats: [String] = []
            for p in posts.sorted().suffix(8) {
                if let c = frontmatter((try? await gh.file(slug, path: p)) ?? "").first(where: { $0.0 == "category" })?.1, !cats.contains(c) { cats.append(c) }
            }
            profile.categories = cats
        }
        // Style notes from a "Writing Style" section in CLAUDE.md, CONTRIBUTING.md or the README.
        for doc in ["CLAUDE.md", "CONTRIBUTING.md", "README.md"] where paths.contains(doc) {
            if let text = try? await gh.file(slug, path: doc), let section = section(text, titled: "writing style") {
                profile.styleGuide = section
                break
            }
        }
        return profile
    }

    static func frontmatter(_ text: String) -> [(String, String)] {
        let parts = text.components(separatedBy: "\n---")
        guard text.hasPrefix("---"), let head = parts.first else { return [] }
        return head.split(separator: "\n").compactMap { line in
            guard let c = line.firstIndex(of: ":") else { return nil }
            let k = line[..<c].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: c)...].trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
            return v.isEmpty ? nil : (k, v)
        }
    }

    static func section(_ md: String, titled: String) -> String? {
        let lines = md.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.hasPrefix("#") && $0.lowercased().contains(titled) }) else { return nil }
        let level = lines[i].prefix { $0 == "#" }.count
        var out: [String] = []
        for l in lines[(i + 1)...] {
            if l.hasPrefix("#") && l.prefix(while: { $0 == "#" }).count <= level { break }
            out.append(l)
        }
        let s = out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : String(s.prefix(1200))
    }

    // MARK: Drafting

    public struct Request: Sendable {
        public var topic: String
        public var notes: String
        /// Optional GitHub repo whose recent activity becomes source material.
        public var sourceRepo: String?
        public var sourceDays: Int
        public var engine: Engine
        public var profile: BlogProfile

        public init(topic: String, notes: String = "", sourceRepo: String? = nil, sourceDays: Int = 14, engine: Engine = .onDevice, profile: BlogProfile) {
            self.topic = topic; self.notes = notes; self.sourceRepo = sourceRepo; self.sourceDays = sourceDays; self.engine = engine; self.profile = profile
        }
    }

    struct Outline { var title: String; var description: String; var category: String; var tags: [String]; var sections: [(String, [String])] }

    public static func draft(_ req: Request, source: String = "studio", onProgress: GitHubWorkflows.Progress? = nil) async throws -> BlogDraft {
        let start = Date()
        var material = req.notes
        if let repo = req.sourceRepo, !repo.isEmpty {
            onProgress?("Gathering recent work in \(repo)")
            material += "\n\n" + (try await activity(repo, days: req.sourceDays))
        }
        let (outline, body): (Outline, String)
        switch req.engine {
        case .onDevice: (outline, body) = try await onDevice(req, material: material, onProgress: onProgress)
        case .claude: (outline, body) = try await withClaude(req, material: material, onProgress: onProgress)
        }
        let markdown = frontmatter(outline, profile: req.profile) + "\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let slug = slugify(outline.title)
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let filename = "\(df.string(from: Date()))-\(slug).md"
        let url = AFMPaths.dir("drafts/blog").appendingPathComponent(filename)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        History.append(HistoryEntry(source: source, kind: "github.blog-draft", title: outline.title, input: req.topic + "\n" + material, output: markdown, seconds: Date().timeIntervalSince(start)))
        return BlogDraft(title: outline.title, slug: slug, filename: filename, markdown: markdown, savedTo: url, profile: req.profile, engine: req.engine, seconds: Date().timeIntervalSince(start))
    }

    static func activity(_ slug: String, days: Int) async throws -> String {
        let gh = try GitHubClient.make()
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let commits = (try? await gh.commits(slug, since: since, limit: 60)) ?? []
        let merged = (try? await gh.search("repo:\(slug) is:pr is:merged merged:>=\(f.string(from: since))", limit: 20)) ?? []
        let readme = (try? await gh.readme(slug)) ?? ""
        let about = try? await gh.repo(slug)
        var s = "About \(slug): \(about?.description ?? "")\n\nREADME excerpt:\n\(GitHubWorkflows.clip(readme, 3500))\n\nRecent work in \(slug) (last \(days) days):\n"
        s += merged.map { "- Merged PR #\($0.number): \($0.title)\n  " + GitHubWorkflows.clip($0.body, 300) }.joined(separator: "\n")
        s += "\nCommits:\n" + commits.map { "- " + $0.subject }.joined(separator: "\n")
        return GitHubWorkflows.clip(s, 12000)
    }

    /// The 4K context can't hold a whole post, so the on-device path plans an outline, then writes each part separately.
    static func onDevice(_ req: Request, material: String, onProgress: GitHubWorkflows.Progress?) async throws -> (Outline, String) {
        let cfg = ModelConfig(guardrails: .permissive)
        let style = req.profile.styleGuide
        var context = material
        if await AFM.tokenCount(material) > 1500 {
            onProgress?("Condensing the source material")
            let sum = Recipe.builtins.first { $0.id == "key-points" }!
            context = try await RecipeRunner.run(sum, input: material, config: cfg).text
        }
        context = GitHubWorkflows.clip(context, 4500)

        var catSchema: [String: Any] = ["type": "string"]
        if !req.profile.categories.isEmpty { catSchema["enum"] = req.profile.categories }
        let schema: [String: Any] = [
            "type": "object", "title": "PostOutline",
            "properties": [
                "title": ["type": "string", "description": "Specific, under 80 characters"],
                "description": ["type": "string", "description": "One sentence, under 160 characters"],
                "category": catSchema,
                "tags": ["type": "array", "maxItems": 6, "items": ["type": "string"]],
                "sections": ["type": "array", "minItems": 3, "maxItems": 5, "items": [
                    "type": "object", "title": "Section",
                    "properties": ["heading": ["type": "string"], "points": ["type": "array", "maxItems": 4, "items": ["type": "string"]]],
                    "required": ["heading", "points"], "x-order": ["heading", "points"],
                ]],
            ],
            "required": ["title", "description", "category", "tags", "sections"],
            "x-order": ["title", "description", "category", "tags", "sections"],
        ]
        onProgress?("Planning the outline")
        let plan = try await AFM.run(GenerationRequest(
            prompt: "Plan a blog post about: \(req.topic)\n\nSource material:\n\(context)",
            instructions: "You plan technical blog posts. Use only facts from the source material and the topic.",
            options: GenOptions(temperature: 0.5), config: cfg, schema: try JSONSchemaConverter.schema(from: schema), measureTokens: false))
        guard let d = plan.text.data(using: .utf8), let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw AFMError(code: "outline", message: "The model didn't return an outline.")
        }
        let outline = Outline(title: o["title"] as? String ?? req.topic, description: o["description"] as? String ?? "",
                              category: o["category"] as? String ?? (req.profile.categories.first ?? "Engineering"),
                              tags: o["tags"] as? [String] ?? [],
                              sections: ((o["sections"] as? [[String: Any]]) ?? []).map { ($0["heading"] as? String ?? "", $0["points"] as? [String] ?? []) })

        onProgress?("Pinning down the key facts")
        let facts = try await AFM.generate("List the 6 most important concrete facts in this material as short bullet points. Expand abbreviations exactly as the material defines them.\n\n" + GitHubWorkflows.clip(context, 3500),
                                           instructions: "You extract facts. Copy names and terms exactly. Add nothing.",
                                           options: GenOptions(temperature: 0.1, maxTokens: 300), config: cfg)
        let writer = "You write blog posts. Style: \(style)\nWrite in Markdown. Use only these facts and the outline; never invent hardware, numbers, quotes, users, results or release steps. If you don't know something, leave it out.\nFacts:\n\(facts)"
        let plan2 = outline.sections.map { "- \($0.0)" }.joined(separator: "\n")
        func write(_ prompt: String, heading: String? = nil, limit: Int = 700) async throws -> String {
            let raw = try await AFM.generate(prompt, instructions: writer, options: GenOptions(temperature: 0.5, maxTokens: limit), config: cfg)
            // Drop any headings the model added and lines that just repeat the section title.
            return raw.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("#") { return false }
                if let h = heading, t.lowercased() == h.lowercased() { return false }
                return true
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        onProgress?("Writing the introduction")
        var body = try await write("Write the opening two paragraphs of a blog post titled \"\(outline.title)\". The post covers:\n\(plan2)\n\nSource material:\n\(GitHubWorkflows.clip(context, 2500))\n\nKeep it to two short paragraphs that set up the problem; the sections cover the details. Don't add a heading.", limit: 260) + "\n"
        for (i, s) in outline.sections.enumerated() {
            onProgress?("Writing section \(i + 1) of \(outline.sections.count)")
            let text = try await write("Blog post: \"\(outline.title)\".\nWrite the section \"\(s.0)\" in two or three paragraphs, covering:\n" + s.1.map { "- " + $0 }.joined(separator: "\n")
                                       + "\n\nSource material:\n\(GitHubWorkflows.clip(context, 2000))\n\nDon't repeat the heading.", heading: s.0)
            body += "\n## \(s.0)\n\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        onProgress?("Writing the ending")
        body += "\n" + (try await write("Write a short closing paragraph for the blog post \"\(outline.title)\", which covered:\n\(plan2)\nNo heading.", limit: 200)) + "\n"
        return (outline, body)
    }

    static func withClaude(_ req: Request, material: String, onProgress: GitHubWorkflows.Progress?) async throws -> (Outline, String) {
        let s = AFMSettings.load()
        let client = try ClaudeClient.fromStoredKey(model: s.claudeModel, effort: s.claudeEffort)
        let cats = req.profile.categories.isEmpty ? "any fitting category" : "one of: " + req.profile.categories.joined(separator: ", ")
        let system = """
        You write blog posts for \(req.profile.authorName.isEmpty ? "the author" : req.profile.authorName). Style: \(req.profile.styleGuide)
        Use only facts from the topic and source material. Never invent numbers, quotes or results.
        Reply in exactly this format, with nothing before it:
        TITLE: <specific title under 80 characters>
        DESCRIPTION: <one sentence under 160 characters>
        CATEGORY: <\(cats)>
        TAGS: <up to 6 tags, comma-separated>
        ---BODY---
        <the post body in Markdown, with ## section headings, no title heading>
        """
        onProgress?("Writing with \(ClaudeModel.find(s.claudeModel).name)")
        let r = try await client.stream("Topic: \(req.topic)\n\nSource material:\n\(material.isEmpty ? "(none)" : material)", system: system)
        let parts = r.text.components(separatedBy: "---BODY---")
        let head = parts.first ?? ""
        func field(_ k: String) -> String {
            head.split(separator: "\n").first { $0.hasPrefix(k + ":") }.map { String($0.dropFirst(k.count + 1)).trimmingCharacters(in: .whitespaces) } ?? ""
        }
        let outline = Outline(title: field("TITLE").isEmpty ? req.topic : field("TITLE"), description: field("DESCRIPTION"),
                              category: field("CATEGORY").isEmpty ? (req.profile.categories.first ?? "Engineering") : field("CATEGORY"),
                              tags: field("TAGS").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                              sections: [])
        return (outline, parts.count > 1 ? parts[1] : r.text)
    }

    static func yaml(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

    static func frontmatter(_ o: Outline, profile: BlogProfile) -> String {
        var s = "---\ntitle: \(yaml(o.title))\ncategory: \(yaml(o.category))\ndescription: \(yaml(o.description))\n"
        s += "date: \(ISO8601DateFormatter().string(from: Date()))\n"
        if !profile.authorName.isEmpty {
            s += "author:\n  name: \(profile.authorName)\n"
            if let a = profile.authorAvatar { s += "  avatar: \(a)\n" }
        }
        if !o.tags.isEmpty { s += "tags:\n" + o.tags.map { "  - \($0)\n" }.joined() }
        return s + "---\n"
    }

    public static func slugify(_ s: String) -> String {
        let words = s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(8)
        return words.isEmpty ? "draft" : words.joined(separator: "-")
    }
}

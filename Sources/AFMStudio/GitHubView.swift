import SwiftUI
import AFMKit
import AFMGitHub

enum GHTab: String, CaseIterable, Identifiable {
    case inbox = "Inbox", item = "Issue / PR", repo = "Repo", writeups = "Write-ups", blog = "Blog", account = "Account"
    var id: String { rawValue }
}

@Observable @MainActor
final class GitHubState {
    var tab: GHTab = .inbox
    var status = IntegrationStatus(connected: false, detail: "Checking…")
    var digest: GitHubDigest?
    var digestDays = 1
    var itemRef = ""
    var repo = ""
    var repos: [GHRepo] = []
    var localPath = ""
    var base = ""
    var output = ""
    var issues: [IssueDraft] = []
    var prDraft: PRDraft?
    var blogDraft: BlogDraft?
    var triage: TriageResult?
    var settings = GitHubSettings.load()
    var running = false
    var progress: String?
    var error: String?
    var task: Task<Void, Never>?

    func refreshStatus() async { status = await GitHubIntegration().status() }
    func saveSettings() { settings.save() }

    func loadRepos() async {
        guard repos.isEmpty, let gh = try? GitHubClient.make() else { return }
        repos = (try? await gh.myRepos(limit: 60)) ?? []
    }

    func run(_ op: @escaping @MainActor (GitHubState) async throws -> Void) {
        running = true; error = nil; progress = nil
        output = ""; issues = []; prDraft = nil; blogDraft = nil; triage = nil
        task = Task {
            do { try await op(self) } catch {
                if !Task.isCancelled { self.error = AFMError.from(error).fullDescription }
            }
            running = false
            progress = nil
        }
    }

    nonisolated func progressHandler() -> GitHubWorkflows.Progress {
        { s in Task { @MainActor in self.progress = s } }
    }
    nonisolated func partialHandler() -> @Sendable (String) -> Void {
        { s in Task { @MainActor in self.output = s } }
    }
}

struct GitHubView: View {
    @Environment(AppState.self) private var app
    var gh: GitHubState { app.github }

    var body: some View {
        if app.settings.integrationPrefs["github"]?.enabled != true {
            ContentUnavailableView {
                Label("GitHub is turned off", systemImage: "chevron.left.forwardslash.chevron.right")
            } description: {
                Text("Turn it on in Integrations to read your repos, issues and pull requests. It only drafts; nothing is posted for you.")
            } actions: {
                Button("Open Integrations") { app.pane = .integrationsHub }.buttonStyle(.borderedProminent)
            }
        } else {
            content
        }
    }

    var content: some View {
        @Bindable var gh = app.github
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                PaneHeader(title: "GitHub", subtitle: "Read-only. The on-device model reads and drafts; you decide what gets posted.", symbol: "chevron.left.forwardslash.chevron.right")
                Label(gh.status.detail, systemImage: gh.status.connected ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.callout).foregroundStyle(gh.status.connected ? Color.green : Color.orange).lineLimit(2).frame(maxWidth: 340, alignment: .trailing)
            }
            Picker("", selection: $gh.tab) { ForEach(GHTab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            HSplitView {
                ScrollView { controls.padding(.trailing, 8).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(minWidth: 360, idealWidth: 420)
                results.frame(minWidth: 380)
            }
        }
        .padding(22)
        .task { await gh.refreshStatus(); await gh.loadRepos() }
    }

    // MARK: Left column

    @ViewBuilder var controls: some View {
        @Bindable var gh = app.github
        VStack(alignment: .leading, spacing: 14) {
            switch gh.tab {
            case .inbox:
                Text("Review requests, assignments, mentions, your open PRs and recent activity, with a short briefing written on device.")
                    .font(.callout).foregroundStyle(.secondary)
                Stepper("Look back \(gh.digestDays) day\(gh.digestDays == 1 ? "" : "s")", value: $gh.digestDays, in: 1...30)
                runButton("Build Digest", "tray.full") { s in s.digest = try await GitHubWorkflows.digest(days: s.digestDays, onProgress: s.progressHandler()); s.output = s.digest?.summary ?? "" }
                if let d = gh.digest {
                    ForEach(d.sections.filter { !$0.items.isEmpty }) { sec in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sec.title).font(.headline)
                            ForEach(sec.items) { i in
                                Button { gh.itemRef = i.ref; gh.tab = .item } label: {
                                    HStack(alignment: .top) {
                                        Image(systemName: i.isPR ? "arrow.triangle.pull" : "smallcircle.filled.circle").foregroundStyle(i.isPR ? .purple : .green)
                                        VStack(alignment: .leading) {
                                            Text(i.title).lineLimit(2)
                                            Text(i.ref).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            case .item:
                TextField("owner/repo#123 or a GitHub URL", text: $gh.itemRef).textFieldStyle(.roundedBorder)
                let ref = GHRef.parse(gh.itemRef)
                HStack {
                    runButton("Summarize", "text.append") { s in
                        let r = try await GitHubWorkflows.summarize(try Self.ref(s.itemRef), onPartial: s.partialHandler(), onProgress: s.progressHandler()); s.output = r.text
                    }
                    runButton("Triage", "stethoscope") { s in
                        let t = try await GitHubWorkflows.triage(try Self.ref(s.itemRef), onProgress: s.progressHandler()); s.triage = t; s.output = t.json
                    }
                    runButton("Draft PR Text", "text.badge.plus") { s in
                        let d = try await GitHubWorkflows.prDescription(ref: try Self.ref(s.itemRef), onPartial: s.partialHandler(), onProgress: s.progressHandler()); s.prDraft = d; s.output = d.markdown
                    }
                }
                .disabled(ref?.number == nil)
                if let r = ref, let n = r.number {
                    Link("Open \(r.slug)#\(n) on GitHub", destination: URL(string: "https://github.com/\(r.slug)/issues/\(n)")!).font(.callout)
                }
                Text("Draft PR Text works on pull requests. It summarizes every changed file, then writes the description.").font(.caption).foregroundStyle(.secondary)
            case .repo:
                repoPicker
                HStack {
                    runButton("Brief", "doc.text.magnifyingglass") { s in
                        let r = try await GitHubWorkflows.repoBrief(s.repo, onPartial: s.partialHandler(), onProgress: s.progressHandler()); s.output = r.text
                    }
                    runButton("Next Steps", "list.bullet.clipboard") { s in
                        s.issues = try await GitHubWorkflows.nextSteps(s.repo, onProgress: s.progressHandler())
                        s.output = s.issues.isEmpty ? "No suggestions." : ""
                    }
                    runButton("Release Notes", "shippingbox") { s in
                        let r = try await GitHubWorkflows.releaseNotes(slug: s.repo, onProgress: s.progressHandler()); s.output = r.text
                    }
                }
                .disabled(GHRef.parse(gh.repo) == nil)
            case .writeups:
                Text("Works on a local checkout: drafts the PR description for your current branch, or release notes since the last tag.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("Local repo folder", text: $gh.localPath).textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                        if p.runModal() == .OK, let u = p.url { gh.localPath = u.path; remember(u.path) }
                    }
                }
                if !gh.settings.localRepos.isEmpty {
                    Menu("Recent folders") { ForEach(gh.settings.localRepos, id: \.self) { p in Button(p) { gh.localPath = p } } }.fixedSize()
                }
                if let repo = try? LocalRepo(path: gh.localPath) {
                    Text("On \(repo.currentBranch) · default \(repo.defaultBranch)\(repo.githubSlug.map { " · \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
                }
                TextField("Base branch (default: the repo's default)", text: $gh.base).textFieldStyle(.roundedBorder)
                HStack {
                    runButton("Draft PR Description", "text.badge.plus") { s in
                        let d = try await GitHubWorkflows.prDescription(local: try LocalRepo(path: s.localPath), base: s.base.isEmpty ? nil : s.base,
                                                                        onPartial: s.partialHandler(), onProgress: s.progressHandler())
                        s.prDraft = d; s.output = d.markdown
                    }
                    runButton("Release Notes", "shippingbox") { s in
                        let r = try await GitHubWorkflows.releaseNotes(local: try LocalRepo(path: s.localPath), onProgress: s.progressHandler()); s.output = r.text
                    }
                }
                .disabled(gh.localPath.isEmpty)
            case .blog:
                BlogControls()
            case .account:
                AccountControls()
            }
        }
    }

    var repoPicker: some View {
        @Bindable var gh = app.github
        return HStack {
            TextField("owner/repo", text: $gh.repo).textFieldStyle(.roundedBorder)
            Menu("Your repos") {
                ForEach(gh.repos) { r in Button(r.fullName + (r.private ? " (private)" : "")) { gh.repo = r.fullName } }
            }
            .fixedSize()
            .disabled(gh.repos.isEmpty)
        }
    }

    func remember(_ path: String) {
        app.github.settings.remember(localRepo: path)
        app.github.saveSettings()
    }

    static func ref(_ s: String) throws -> GHRef {
        guard let r = GHRef.parse(s), r.number != nil else { throw AFMError(code: "bad_ref", message: "Enter an issue or PR like owner/repo#12.") }
        return r
    }

    func runButton(_ title: String, _ symbol: String, _ op: @escaping @MainActor (GitHubState) async throws -> Void) -> some View {
        Button(title, systemImage: symbol) { app.github.run(op) }
            .disabled(app.github.running || !app.github.status.connected)
    }

    // MARK: Right column

    var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Result").font(.headline)
                if gh.running {
                    ProgressView().controlSize(.small)
                    Text(gh.progress ?? "Working…").font(.caption).foregroundStyle(.secondary)
                    Button("Stop") { gh.task?.cancel() }.controlSize(.small)
                }
                Spacer()
                CopyButton(text: gh.output)
            }
            if let e = gh.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if gh.triage != nil {
                        Text(gh.output).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    } else {
                        MarkdownText(text: gh.output)
                    }
                    if let t = gh.triage, !t.duplicates.isEmpty {
                        Text("Possible duplicates").font(.headline)
                        ForEach(t.duplicates, id: \.issue.id) { d in
                            Link("\(d.issue.ref) \(d.issue.title) (\(Int(d.score * 100))% similar)", destination: URL(string: d.issue.htmlUrl)!)
                        }
                    }
                    if let d = gh.digest, gh.tab == .inbox, gh.output.isEmpty == false {
                        Text("\(d.sections.map(\.items.count).reduce(0, +)) items across \(d.sections.filter { !$0.items.isEmpty }.count) groups").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(gh.issues) { i in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(i.title).font(.headline)
                            if !i.labels.isEmpty { Text(i.labels.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                            MarkdownText(text: i.body)
                            HStack {
                                if let u = i.url { Link("Open Pre-filled Issue", destination: u) }
                                CopyButton(text: "# \(i.title)\n\n\(i.body)", compact: true)
                            }
                        }
                        .padding(12)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay { if gh.output.isEmpty && gh.issues.isEmpty && !gh.running && gh.error == nil {
                ContentUnavailableView("Nothing yet", systemImage: "tray", description: Text("Pick an action on the left."))
            } }
            HStack {
                if let d = gh.prDraft, let u = d.url { Link("Open Pre-filled Pull Request", destination: u) }
                if let b = gh.blogDraft {
                    Button("Reveal Draft") { NSWorkspace.shared.activateFileViewerSelecting([b.savedTo]) }
                    if let u = b.newFileURL { Link("Create on GitHub (you commit)", destination: u) }
                }
                Spacer()
                Text("Nothing is posted for you. Links open GitHub pre-filled so you can review and submit.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct BlogControls: View {
    @Environment(AppState.self) private var app
    @State private var setupRepo = ""
    @State private var topic = ""
    @State private var notes = ""
    @State private var sourceRepo = ""
    @State private var days = 14
    @State private var engine: BlogWriter.Engine = .onDevice
    @State private var setupMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p = app.github.settings.blog {
                Card(title: "Blog: \(p.repo)", symbol: "newspaper") {
                    Text("Posts in \(p.postsPath) on \(p.branch) · by \(p.authorName.isEmpty ? "?" : p.authorName)").font(.callout)
                    Text("Categories: \(p.categories.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                    Button("Change Blog…") { app.github.settings.blog = nil; app.github.saveSettings() }.controlSize(.small)
                }
                TextField("Topic", text: $topic, axis: .vertical).lineLimit(1...3).textFieldStyle(.roundedBorder)
                Text("Notes and facts to build on").font(.caption).foregroundStyle(.secondary)
                InputEditor(text: $notes, placeholder: "Bullet notes, links, error messages, code…", minHeight: 120)
                HStack {
                    TextField("Use recent work from (owner/repo, optional)", text: $sourceRepo).textFieldStyle(.roundedBorder)
                    Stepper("\(days)d", value: $days, in: 1...90).fixedSize()
                }
                Picker("Writer", selection: $engine) { ForEach(BlogWriter.Engine.allCases) { Text($0.title).tag($0) } }
                if engine == .onDevice {
                    Text("On device it plans an outline, then writes each part, which takes a minute or two. It can still get facts wrong, so give it good notes and read the draft. Claude writes noticeably better posts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Draft Post", systemImage: "square.and.pencil") {
                    let req = BlogWriter.Request(topic: topic, notes: notes, sourceRepo: sourceRepo.isEmpty ? nil : sourceRepo, sourceDays: days, engine: engine, profile: p)
                    app.github.run { s in
                        let d = try await BlogWriter.draft(req, onProgress: s.progressHandler())
                        s.blogDraft = d
                        s.output = d.markdown
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(topic.isEmpty || app.github.running || (engine == .claude && ClaudeKeychain.resolve().key == nil))
            } else {
                Text("Point AFM Studio at your blog's repo. It learns where posts live, the author, categories and any writing-style notes. The setup is saved on this Mac only.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("owner/blog-repo", text: $setupRepo).textFieldStyle(.roundedBorder)
                    Button("Learn") {
                        let slug = setupRepo
                        Task {
                            do { app.github.settings.blog = try await BlogWriter.learn(repo: slug); app.github.saveSettings(); setupMessage = nil }
                            catch { setupMessage = AFMError.from(error).fullDescription }
                        }
                    }
                    .disabled(GHRef.parse(setupRepo) == nil)
                }
                if let setupMessage { Text(setupMessage).foregroundStyle(.orange).font(.callout) }
            }
        }
    }
}

struct AccountControls: View {
    @Environment(AppState.self) private var app
    @State private var token = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let r = GitHubAuth.resolve()
            Label(r.token == nil ? "Not signed in." : "Using \(GitHubAuth.sourceDescription): \(KeychainSecret.masked(r.token!))",
                  systemImage: r.token == nil ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle.badge.checkmark")
            Text("A token in the Keychain takes priority. Without one, AFM Studio borrows your `gh` login. A fine-grained, read-only token is the tightest option.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                SecureField("github_pat_…", text: $token).textFieldStyle(.roundedBorder)
                Button("Save to Keychain") {
                    do { try GitHubAuth.save(token); token = ""; message = "Saved." } catch { message = AFMError.from(error).fullDescription }
                    Task { await app.github.refreshStatus() }
                }
                .disabled(token.isEmpty)
            }
            HStack {
                if r.source == .keychain {
                    Button("Remove Token", role: .destructive) { GitHubAuth.delete(); message = "Removed."; Task { await app.github.refreshStatus() } }
                }
                Button("Re-check gh Login") { GitHubAuth.refreshGH(); Task { await app.github.refreshStatus() } }
                Link("Create a fine-grained token", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            Divider()
            Text("Claude can use these too: the afm MCP server includes afm_github_* tools for summaries, triage, digests, PR descriptions, release notes, briefs, next steps and blog drafts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

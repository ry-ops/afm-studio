import Foundation
import AFMKit
import AFMGitHub

let githubHelp = """
\(bold("afm github")) — GitHub, read-only. Everything it writes is a draft for you to review and post.

  afm github status                       Sign-in and blog setup
  afm github auth set | status | rm       Token in the Keychain (wins over your gh login)
  afm github digest [--days N]            What needs you: reviews, assignments, mentions, your PRs
  afm github summarize REF                Summarize an issue or PR (REF: owner/repo#12 or a URL)
  afm github triage REF                   Type, priority, labels from the repo, missing info, duplicates
  afm github pr [PATH] [--base BRANCH]    Draft a PR description for the current branch of a local repo
  afm github pr REF                       Draft a description for an existing PR
  afm github release [PATH|owner/repo] [--from TAG] [--to REF]
  afm github brief owner/repo             Project brief: state, activity, open work, next steps
  afm github next owner/repo [--focus X]  Draft up to five next-step issues with pre-filled links
  afm github blog setup owner/repo        Learn a blog repo's posts folder, author, categories, style
  afm github blog draft "topic" [--notes TEXT|-f FILE] [--from-repo owner/repo] [--days N] [--engine on-device|claude]
"""

func ghArg(_ args: inout [String], _ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func ghProgress() -> GitHubWorkflows.Progress? {
    guard stderrTTY else { return nil }
    return { s in eprint(dim("  … " + s, tty: true)) }
}

func ref(_ s: String?) -> GHRef {
    guard let s, let r = GHRef.parse(s), r.number != nil else { fail("give an issue or PR like owner/repo#12", code: 2) }
    return r
}

func cmdGitHub(_ a: Args) async {
    var args = a.positionals
    let sub = args.isEmpty ? "help" : args.removeFirst()
    do {
        switch sub {
        case "help": out(githubHelp)

        case "auth":
            switch args.first ?? "status" {
            case "set":
                try GitHubAuth.save(readSecret("GitHub token (input hidden): "))
                out(good("✓ Saved to the macOS Keychain.") + dim(" It now takes priority over your gh login."))
            case "rm", "delete": GitHubAuth.delete(); out("Removed. AFM Studio will use your gh login if there is one.")
            default:
                let r = GitHubAuth.resolve()
                out(r.token.map { "Using \(GitHubAuth.sourceDescription): \(KeychainSecret.masked($0))" } ?? warn("Not signed in.") + dim(" Run `gh auth login` or `afm github auth set`."))
            }

        case "status":
            if !IntegrationRegistry.isEnabled(GitHubIntegration.integrationID) {
                out(warn("○ GitHub is turned off.") + dim(" Run `afm integrations enable github`."))
                return
            }
            let st = await GitHubIntegration().status()
            out((st.connected ? good("● ") : warn("○ ")) + st.detail)
            if let b = GitHubSettings.load().blog {
                out(bold("Blog  ") + "\(b.repo) · \(b.postsPath) · author \(b.authorName.isEmpty ? "?" : b.authorName) · \(b.categories.count) categories")
            } else { out(bold("Blog  ") + dim("not set up (afm github blog setup owner/repo)")) }

        case "digest":
            let d = try await GitHubWorkflows.digest(days: Int(ghArg(&args, "--days") ?? "1") ?? 1, source: "cli", onProgress: ghProgress())
            out(d.markdown)

        case "summarize", "summary":
            let printer = streamPrinter()
            let r = try await GitHubWorkflows.summarize(ref(args.first), source: "cli", onPartial: stdoutTTY ? printer : nil, onProgress: ghProgress())
            if stdoutTTY { out("") } else { out(r.text) }

        case "triage":
            out(try await GitHubWorkflows.triage(ref(args.first), source: "cli", onProgress: ghProgress()).markdown)

        case "pr":
            let base = ghArg(&args, "--base")
            let d: PRDraft
            if let first = args.first, GHRef.parse(first)?.number != nil, !FileManager.default.fileExists(atPath: (first as NSString).expandingTildeInPath) {
                d = try await GitHubWorkflows.prDescription(ref: ref(first), source: "cli", onProgress: ghProgress())
            } else {
                d = try await GitHubWorkflows.prDescription(local: try LocalRepo(path: args.first ?? FileManager.default.currentDirectoryPath), base: base, source: "cli", onProgress: ghProgress())
            }
            out(d.markdown)
            if let u = d.url { out("\n" + dim("Open a pre-filled pull request (you submit it): ") + u.absoluteString) }

        case "release":
            let from = ghArg(&args, "--from"), to = ghArg(&args, "--to") ?? "HEAD"
            let target = args.first ?? FileManager.default.currentDirectoryPath
            let isLocal = FileManager.default.fileExists(atPath: (target as NSString).expandingTildeInPath)
            let r = try await GitHubWorkflows.releaseNotes(local: isLocal ? try LocalRepo(path: target) : nil, slug: isLocal ? nil : GHRef.parse(target)?.slug,
                                                           from: from, to: to, source: "cli", onProgress: ghProgress())
            out(r.text)

        case "brief":
            guard let slug = args.first.flatMap(GHRef.parse)?.slug else { fail("give a repo like owner/repo", code: 2) }
            let printer = streamPrinter()
            let r = try await GitHubWorkflows.repoBrief(slug, source: "cli", onPartial: stdoutTTY ? printer : nil, onProgress: ghProgress())
            if stdoutTTY { out("") } else { out(r.text) }

        case "next":
            let focus = ghArg(&args, "--focus")
            guard let slug = args.first.flatMap(GHRef.parse)?.slug else { fail("give a repo like owner/repo", code: 2) }
            let drafts = try await GitHubWorkflows.nextSteps(slug, focus: focus, source: "cli", onProgress: ghProgress())
            if drafts.isEmpty { out("No suggestions.") }
            for (i, d) in drafts.enumerated() {
                out(bold("\(i + 1). \(d.title)") + (d.labels.isEmpty ? "" : dim("  [\(d.labels.joined(separator: ", "))]")))
                out(d.body)
                if let u = d.url { out(dim("Open pre-filled: ") + u.absoluteString) }
                out("")
            }

        case "blog":
            let action = args.isEmpty ? "help" : args.removeFirst()
            switch action {
            case "setup":
                guard let slug = args.first.flatMap(GHRef.parse)?.slug else { fail("give the blog repo, like owner/repo", code: 2) }
                let p = try await BlogWriter.learn(repo: slug)
                var s = GitHubSettings.load(); s.blog = p; s.save()
                out(good("✓ Blog set up") + " (saved in local settings only)")
                out("  Posts      \(p.repo)/\(p.postsPath) on \(p.branch)")
                out("  Author     \(p.authorName.isEmpty ? "?" : p.authorName)\(p.authorAvatar.map { " · \($0)" } ?? "")")
                out("  Categories \(p.categories.joined(separator: ", "))")
                out("  Style      \(p.styleGuide.replacingOccurrences(of: "\n", with: " ").prefix(140))…")
            case "draft":
                guard let profile = GitHubSettings.load().blog else { fail("no blog set up", hint: "Run `afm github blog setup owner/repo` first.", code: 2) }
                let fromRepo = ghArg(&args, "--from-repo"), days = Int(ghArg(&args, "--days") ?? "14") ?? 14
                let engine = BlogWriter.Engine(rawValue: ghArg(&args, "--engine") ?? "on-device") ?? .onDevice
                let notes = ghArg(&args, "--notes") ?? a.file.map(readFileArg) ?? readStdin() ?? ""
                let topic = args.joined(separator: " ")
                if topic.isEmpty { fail("give a topic", code: 2) }
                let d = try await BlogWriter.draft(.init(topic: topic, notes: notes, sourceRepo: fromRepo, sourceDays: days, engine: engine, profile: profile),
                                                   source: "cli", onProgress: ghProgress())
                out(d.markdown)
                out(dim(String(format: "Saved %@ (%.0fs, %@)", d.savedTo.path, d.seconds, d.engine.title)))
                if let u = d.newFileURL { out(dim("Create it on GitHub yourself (pre-filled): ") + u.absoluteString) }
            default:
                out(githubHelp)
            }

        default:
            fail("unknown github command \(sub)", hint: "Run `afm github help`.", code: 2)
        }
    } catch { fail(error) }
}

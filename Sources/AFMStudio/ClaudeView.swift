import SwiftUI
import AFMKit

@Observable @MainActor
final class ClaudeState {
    var keySource: ClaudeKeychain.Source = .none
    var maskedKey: String?
    var keyMessage: String?
    var hook = ClaudeHook.Status(claudeCLIFound: false, claudeCodeHooked: false, claudeCodePath: nil, desktopHooked: false, desktopPath: nil)
    var hookMessage: String?
    var syncing = false

    func refreshKey() {
        let r = ClaudeKeychain.resolve()
        keySource = r.source
        maskedKey = r.key.map(ClaudeKeychain.masked)
    }

    func refreshHook() async {
        let s = await Task.detached { ClaudeHook.status() }.value
        hook = s
    }

    /// Links ~/.local/bin/afm to the bundled CLI and registers it with Claude. Only runs from a built .app,
    /// so development builds never rewrite your Claude configs.
    func sync(settings: AFMSettings, force: Bool = false) async {
        guard Bundle.main.bundleURL.pathExtension == "app", let bundled = CLILocator.bundled else {
            if force { hookMessage = "Run the built app (bash scripts/build-app.sh) to hook Claude automatically." }
            return
        }
        syncing = true
        let code = settings.autoHookClaudeCode || force
        let desktop = settings.autoHookClaudeDesktop || force
        let msg: String = await Task.detached {
            var lines: [String] = []
            do { try ClaudeHook.linkCLI(to: bundled) } catch { lines.append("CLI link: \(AFMError.from(error).message)") }
            let path = ClaudeHook.stableCLIPath
            if code { do { lines.append("Claude Code: " + (try ClaudeHook.hookClaudeCode(cliPath: path))) } catch { lines.append("Claude Code: " + AFMError.from(error).message) } }
            if desktop { do { lines.append("Claude Desktop: " + (try ClaudeHook.hookDesktop(cliPath: path))) } catch { lines.append("Claude Desktop: " + AFMError.from(error).message) } }
            return lines.joined(separator: "\n")
        }.value
        hookMessage = msg
        syncing = false
        await refreshHook()
    }
}

struct ClaudeView: View {
    @Environment(AppState.self) private var app
    @ViewState private var keyInput = ""
    @ViewState private var prompt = "Explain the difference between a mutex and a semaphore in three sentences."
    @ViewState private var localText = ""
    @ViewState private var claudeText = ""
    @ViewState private var local: GenerationResult?
    @ViewState private var remote: ClaudeResult?
    @ViewState private var localError: String?
    @ViewState private var claudeError: String?
    @ViewState private var running = false
    @ViewState private var task: Task<Void, Never>?

    var claude: ClaudeState { app.claude }
    var model: ClaudeModel { ClaudeModel.find(app.settings.claudeModel) }

    var body: some View {
        @Bindable var app = app
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader(title: "Claude", subtitle: "Your Anthropic API key, Claude models, and the MCP wiring that lets Claude call the on-device model.", symbol: "brain")

                Card(title: "API key", symbol: "key") {
                    HStack {
                        Image(systemName: claude.keySource == .none ? "key.slash" : "checkmark.shield.fill")
                            .foregroundStyle(claude.keySource == .none ? Color.secondary : Color.green)
                        switch claude.keySource {
                        case .keychain: Text("Stored in your macOS Keychain: \(claude.maskedKey ?? "")")
                        case .environment: Text("Using ANTHROPIC_API_KEY from the environment: \(claude.maskedKey ?? "")")
                        case .none: Text("No key yet. It stays on this Mac, in the Keychain, and is never written to the repo or any file.")
                        }
                        Spacer()
                    }
                    HStack {
                        SecureField("sk-ant-…", text: $keyInput).textFieldStyle(.roundedBorder)
                        Button("Save to Keychain") {
                            do { try ClaudeKeychain.save(keyInput); keyInput = ""; claude.keyMessage = "Saved."; claude.refreshKey() }
                            catch { claude.keyMessage = AFMError.from(error).fullDescription }
                        }
                        .disabled(keyInput.isEmpty)
                        Button("Verify") { verify() }.disabled(claude.keySource == .none)
                        if claude.keySource == .keychain {
                            Button("Remove", role: .destructive) { ClaudeKeychain.delete(); claude.refreshKey(); claude.keyMessage = "Removed from the Keychain." }
                        }
                    }
                    if let m = claude.keyMessage { Text(m).font(.callout).foregroundStyle(.secondary) }
                    HStack(spacing: 16) {
                        Picker("Model", selection: $app.settings.claudeModel) {
                            ForEach(ClaudeModel.all) { m in Text("\(m.name)  ·  $\(fmt(m.inputPerMTok)) / $\(fmt(m.outputPerMTok)) per MTok").tag(m.id) }
                        }
                        .frame(maxWidth: 420)
                        Picker("Effort", selection: $app.settings.claudeEffort) {
                            ForEach(ClaudeClient.efforts, id: \.self) { Text($0).tag($0) }
                        }
                        .frame(maxWidth: 200)
                    }
                    Text("The CLI uses the same key: `afm claude \"…\"`. Refusal fallbacks are on for models that support them.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Card(title: "MCP auto-hook", symbol: "point.3.connected.trianglepath.dotted") {
                    Text("Keeps the afm MCP server registered in Claude so it can hand text work to the on-device model. Re-checked every time AFM Studio opens, so the registration follows the app if you move it.")
                        .font(.callout).foregroundStyle(.secondary)
                    hookRow("Claude Code", on: $app.settings.autoHookClaudeCode, found: claude.hook.claudeCLIFound,
                            hooked: claude.hook.claudeCodeHooked, path: claude.hook.claudeCodePath,
                            missing: "The `claude` command wasn't found.")
                    hookRow("Claude Desktop", on: $app.settings.autoHookClaudeDesktop, found: true,
                            hooked: claude.hook.desktopHooked, path: claude.hook.desktopPath, missing: "")
                    HStack {
                        Button(claude.syncing ? "Syncing…" : "Sync Now") { Task { await claude.sync(settings: app.settings, force: true) } }
                            .disabled(claude.syncing)
                        Button("Remove from Claude") {
                            Task.detached {
                                let a = ClaudeHook.unhookClaudeCode()
                                let b = (try? ClaudeHook.unhookDesktop()) ?? ""
                                await MainActor.run { app.claude.hookMessage = "Claude Code: \(a)\nClaude Desktop: \(b)" }
                                await app.claude.refreshHook()
                            }
                        }
                        Button("Refresh") { Task { await claude.refreshHook() } }
                    }
                    if let m = claude.hookMessage { Text(m).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                }

                Card(title: "Side by side", symbol: "rectangle.split.2x1") {
                    TextField("Prompt", text: $prompt, axis: .vertical).lineLimit(2...6).textFieldStyle(.roundedBorder)
                    HStack {
                        if running {
                            ProgressView().controlSize(.small)
                            Button("Stop", systemImage: "stop.fill") { task?.cancel() }
                        } else {
                            Button("Compare", systemImage: "play.fill") { compare(withLocal: true) }
                                .buttonStyle(.borderedProminent)
                                .disabled(prompt.isEmpty || claude.keySource == .none)
                            Button("Claude only") { compare(withLocal: false) }.disabled(prompt.isEmpty || claude.keySource == .none)
                        }
                        Spacer()
                        if claude.keySource == .none { Text("Add an API key to compare.").font(.caption).foregroundStyle(.secondary) }
                    }
                    HStack(alignment: .top, spacing: 14) {
                        column("On-device", "cpu", localText, localError,
                               local.map { String(format: "%.1fs · %d tokens · free, private", $0.seconds, $0.outputTokens ?? 0) })
                        column(model.name, "brain", claudeText, claudeError,
                               remote.map { String(format: "%.1fs · %d in / %d out · $%.4f", $0.seconds, $0.inputTokens, $0.outputTokens, $0.cost(model)) })
                    }
                }
            }
            .padding(22)
        }
        .onAppear { claude.refreshKey(); Task { await claude.refreshHook() } }
        .onChange(of: app.settings) { app.saveSettings() }
    }

    func fmt(_ d: Double) -> String { d < 1 ? String(format: "%.2f", d) : String(format: "%.0f", d) }

    func hookRow(_ name: String, on: Binding<Bool>, found: Bool, hooked: Bool, path: String?, missing: String) -> some View {
        HStack {
            Toggle(isOn: on) { Text(name).bold() }.toggleStyle(.switch).frame(width: 190, alignment: .leading)
            if !found {
                Label(missing, systemImage: "questionmark.circle").foregroundStyle(.secondary)
            } else if hooked {
                Label("Registered → \(path ?? "?")", systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1).truncationMode(.middle)
            } else {
                Label("Not registered", systemImage: "circle.dashed").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.callout)
    }

    func column(_ title: String, _ symbol: String, _ text: String, _ error: String?, _ stats: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Label(title, systemImage: symbol).font(.headline); Spacer(); CopyButton(text: text, compact: true) }
            ScrollView {
                Group {
                    if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    else { MarkdownText(text: text) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 180)
            if let stats { Text(stats).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
    }

    func verify() {
        let m = app.settings.claudeModel
        Task {
            do {
                let name = try await ClaudeClient.fromStoredKey(model: m).verify()
                claude.keyMessage = "✓ Key works. \(name) is available."
            } catch { claude.keyMessage = AFMError.from(error).fullDescription }
        }
    }

    func compare(withLocal: Bool) {
        running = true
        localText = ""; claudeText = ""; local = nil; remote = nil; localError = nil; claudeError = nil
        let p = prompt, m = app.settings.claudeModel, e = app.settings.claudeEffort
        task = Task {
            async let cloud: Void = runClaude(p, model: m, effort: e)
            if withLocal {
                do {
                    let r = try await AFM.run(GenerationRequest(prompt: p), onPartial: { s in Task { @MainActor in localText = s } })
                    local = r
                    localText = r.text
                } catch { if !Task.isCancelled { localError = AFMError.from(error).fullDescription } }
            }
            await cloud
            running = false
        }
    }

    /// The Claude half of a comparison. It is main-actor isolated like the rest of the view,
    /// so it can write view state, and it still runs alongside the local model through `async let`.
    @MainActor
    private func runClaude(_ p: String, model m: String, effort e: String) async {
        do {
            let r = try await ClaudeClient.fromStoredKey(model: m, effort: e).stream(p, onText: { s in Task { @MainActor in claudeText = s } })
            remote = r
            claudeText = r.text
            History.append(HistoryEntry(source: "studio", kind: "claude", title: r.model, input: p, output: r.text, seconds: r.seconds, outputTokens: r.outputTokens))
        } catch { if !Task.isCancelled { claudeError = AFMError.from(error).fullDescription } }
    }
}

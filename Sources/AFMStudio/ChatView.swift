import SwiftUI
import FoundationModels
import AFMKit

@Observable @MainActor
final class ChatViewModel {
    let engine: ChatEngine
    weak var app: AppState?
    var messages: [ChatMessage]
    var draft = ""
    var streaming: String?
    var liveTools: [String] = []
    var busy = false
    var error: String?
    var used = 0
    var total = 4096
    var notice: String?
    private var task: Task<Void, Never>?

    // Editable copies of the record's settings
    var instructions: String
    var options: GenOptions
    var config: ModelConfig
    var tools: Set<ToolKind>

    init(engine: ChatEngine, app: AppState) {
        self.engine = engine
        self.app = app
        messages = engine.record.messages
        instructions = engine.record.instructions
        options = engine.record.options
        config = engine.record.config
        tools = Set(engine.record.tools)
        Task { await refreshUsage() }
    }

    var title: String { engine.record.title }
    var source: String { engine.record.source }

    func reloadIfChanged(_ r: ChatSessionRecord) {
        guard !busy, r.messages != messages else { return }
        engine.update { $0 = r }
        messages = r.messages
    }

    func applySettings() {
        let i = instructions, o = options, c = config, t = ToolKind.allCases.filter { tools.contains($0) }
        engine.update { r in r.instructions = i; r.options = o; r.config = c; r.tools = t }
        Task { await refreshUsage() }
    }

    func refreshUsage() async {
        let u = await engine.contextUsage()
        used = u.used
        total = u.total
    }

    func send(_ override: String? = nil) {
        let text = (override ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        draft = ""
        error = nil
        busy = true
        streaming = ""
        liveTools = []
        messages.append(ChatMessage(role: .user, text: text))
        task = Task {
            do {
                _ = try await engine.send(text,
                    onPartial: { s in Task { @MainActor in self.streaming = s } },
                    onTool: { t in Task { @MainActor in self.liveTools.append(t) } },
                    onNotice: { n in Task { @MainActor in self.notice = n } })
            } catch is CancellationError {
            } catch {
                self.error = AFMError.from(error).fullDescription
                if self.draft.isEmpty { self.draft = text }
            }
            self.messages = engine.record.messages
            self.streaming = nil
            self.busy = false
            self.app?.reloadSessions()
            await self.refreshUsage()
        }
    }

    func stop() { task?.cancel() }

    func reset() {
        stop()
        engine.reset()
        messages = []
        Task { await refreshUsage() }
    }

    func compact() {
        busy = true
        Task {
            do { try await engine.compact() } catch { self.error = AFMError.from(error).fullDescription }
            self.messages = engine.record.messages
            self.busy = false
            await self.refreshUsage()
        }
    }

    func feedback(positive: Bool, issue: LanguageModelFeedback.Issue.Category?) {
        if let url = engine.feedbackAttachment(positive: positive, issue: issue) {
            notice = "Feedback saved. Attach it in Feedback Assistant."
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            notice = "Send a message in this window first, then leave feedback."
        }
    }
}

struct ChatView: View {
    @Environment(AppState.self) private var app
    @Bindable var vm: ChatViewModel
    @State private var showInspector = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if vm.messages.isEmpty && vm.streaming == nil {
                            ChatEmptyState { vm.send($0) }
                        }
                        ForEach(vm.messages) { m in
                            MessageRow(message: m, onFeedback: m.role == .assistant ? { vm.feedback(positive: $0, issue: $1) } : nil)
                        }
                        if let s = vm.streaming {
                            MessageRow(message: ChatMessage(role: .assistant, text: s.isEmpty ? "" : s, tools: vm.liveTools), live: true)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 28).padding(.vertical, 20)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: vm.streaming) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: vm.messages.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if let e = vm.error {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .padding(.horizontal, 20).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let n = vm.notice {
                Label(n, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.bottom, 4)
                    .task { try? await Task.sleep(for: .seconds(5)); vm.notice = nil }
            }
            composer
        }
        .navigationTitle(vm.title)
        .navigationSubtitle(vm.source == "mcp" ? "Started by Claude via MCP" : vm.source == "cli" ? "Started in Terminal" : "On-device, private")
        .toolbar {
            ToolbarItemGroup {
                TokenGauge(used: vm.used, total: vm.total)
                Menu {
                    Button("Copy as Markdown", systemImage: "doc.on.doc") { Pasteboard.copy(vm.engine.markdownExport()) }
                    Button("Export Markdown…", systemImage: "square.and.arrow.up") {
                        FileLoader.save(vm.engine.markdownExport(), name: "\(vm.title).md", type: .plainText)
                    }
                    Divider()
                    Button("Summarize older turns now", systemImage: "arrow.down.right.and.arrow.up.left") { vm.compact() }
                    Button("Clear conversation", systemImage: "trash", role: .destructive) { vm.reset() }
                } label: { Label("More", systemImage: "ellipsis.circle") }
                Button { showInspector.toggle() } label: { Label("Settings", systemImage: "sidebar.trailing") }
            }
        }
        .inspector(isPresented: $showInspector) {
            ChatInspector(vm: vm).inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .onAppear { focused = true }
    }

    var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message the on-device model…", text: $vm.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit { vm.send() }
                .padding(.vertical, 10).padding(.horizontal, 14)
                .background(.background, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.separator))
            if vm.busy {
                Button { vm.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 28)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Stop")
            } else {
                Button { vm.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 28)) }
                    .buttonStyle(.plain).foregroundStyle(vm.draft.isEmpty ? Color.secondary : Color.accentColor)
                    .disabled(vm.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (Return)")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
    }
}

struct MessageRow: View {
    let message: ChatMessage
    var live = false
    var onFeedback: ((Bool, LanguageModelFeedback.Issue.Category?) -> Void)?
    @State private var hover = false

    var body: some View {
        switch message.role {
        case .notice:
            HStack {
                Spacer()
                Label(message.text, systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 16))
            }
        case .assistant:
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(LinearGradient(colors: [.indigo, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                VStack(alignment: .leading, spacing: 8) {
                    if !message.tools.isEmpty {
                        HStack(spacing: 6) { ForEach(message.tools, id: \.self) { StatChip(symbol: "wrench.and.screwdriver", text: $0) } }
                    }
                    if message.text.isEmpty && live {
                        ProgressView().controlSize(.small)
                    } else {
                        MarkdownText(text: message.text)
                    }
                    if !live {
                        HStack(spacing: 10) {
                            if let s = message.seconds { Text(String(format: "%.1fs", s)) }
                            if let t = message.tokens { Text("\(t) tokens") }
                            CopyButton(text: message.text, compact: true)
                            if let onFeedback {
                                Menu {
                                    Button("Good response", systemImage: "hand.thumbsup") { onFeedback(true, nil) }
                                    Divider()
                                    ForEach(LanguageModelFeedback.Issue.Category.allCases, id: \.self) { c in
                                        Button(Self.label(c)) { onFeedback(false, c) }
                                    }
                                } label: { Image(systemName: "hand.thumbsup") }
                                .menuStyle(.borderlessButton).fixedSize()
                                .help("Save Apple feedback for this response")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .opacity(hover ? 1 : 0.55)
                    }
                }
                Spacer(minLength: 40)
            }
            .onHover { hover = $0 }
        }
    }

    static func label(_ c: LanguageModelFeedback.Issue.Category) -> String {
        switch c {
        case .unhelpful: "Unhelpful"
        case .tooVerbose: "Too verbose"
        case .didNotFollowInstructions: "Didn't follow instructions"
        case .incorrect: "Incorrect"
        case .stereotypeOrBias: "Stereotype or bias"
        case .suggestiveOrSexual: "Suggestive or sexual"
        case .vulgarOrOffensive: "Vulgar or offensive"
        case .triggeredGuardrailUnexpectedly: "Blocked unexpectedly"
        @unknown default: "Other"
        }
    }
}

struct ChatEmptyState: View {
    let pick: (String) -> Void
    let ideas = [
        ("lightbulb", "Give me three ideas for a rainy Saturday."),
        ("function", "What's 18% tip on $86.40, split four ways?"),
        ("calendar", "What day of the week is it, and how many days until New Year's?"),
        ("text.quote", "Rewrite: 'pls send the deck asap, need it 4 the call' in a polite tone."),
    ]

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(
                LinearGradient(colors: [.indigo, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("Private chat with Apple's on-device model").font(.title2.bold())
            Text("Runs entirely on this Mac. Free, offline, and nothing leaves the device.")
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(ideas, id: \.1) { idea in
                    Button { pick(idea.1) } label: {
                        Label(idea.1, systemImage: idea.0).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 620)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

struct ChatInspector: View {
    @Bindable var vm: ChatViewModel

    var body: some View {
        Form {
            Section("Instructions") {
                TextEditor(text: $vm.instructions)
                    .font(.callout)
                    .frame(minHeight: 110)
                Button("Apply") { vm.applySettings() }
                    .disabled(vm.instructions == vm.engine.record.instructions)
            }
            Section("Model & sampling") {
                OptionsEditor(options: $vm.options, config: $vm.config)
            }
            .onChange(of: vm.options) { vm.applySettings() }
            .onChange(of: vm.config) { vm.applySettings() }
            Section("Tools the model can call") {
                ForEach(ToolKind.allCases) { t in
                    Toggle(isOn: Binding(get: { vm.tools.contains(t) }, set: { on in
                        if on { vm.tools.insert(t) } else { vm.tools.remove(t) }
                        vm.applySettings()
                    })) {
                        Label { VStack(alignment: .leading) { Text(t.title); Text(t.summary).font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: t.symbol) }
                    }
                }
            }
            Section("Context") {
                Gauge(value: Double(vm.used), in: 0...Double(max(vm.total, 1))) {
                    Text("Context window")
                } currentValueLabel: {
                    Text("\(vm.used) / \(vm.total) tokens")
                }
                Text("When the context fills up, older turns are summarized automatically so the chat can keep going.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

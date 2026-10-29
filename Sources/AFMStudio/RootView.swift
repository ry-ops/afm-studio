import SwiftUI
import AFMKit

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            @Bindable var term = app.terminal
            GeometryReader { geo in
                VStack(spacing: 0) {
                    if !(app.terminal.visible && app.terminal.maximized) {
                        // Panes are designed to fit 520 × 400 points. Below that they scroll rather than overlap.
                        paneContent.scrollsWhenSmallerThan(width: 520, height: 400)
                    }
                    if app.terminal.visible {
                        if !app.terminal.maximized {
                            PanelResizeHandle(height: $term.height, maxHeight: geo.size.height - 160)
                        }
                        TerminalPanel()
                            .frame(height: app.terminal.maximized ? nil : min(app.terminal.height, max(120, geo.size.height - 160)))
                            .frame(maxHeight: app.terminal.maximized ? .infinity : nil)
                    }
                }
            }
            .sheet(isPresented: Bindable(app.updates).showSheet) { UpdateSheet().environment(app) }
            .onAppear { app.openWindow = openWindow }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { app.terminal.toggle() } label: {
                        Label("Terminal", systemImage: app.terminal.visible ? "terminal.fill" : "terminal")
                    }
                    .help("Show or hide the terminal (⌃`)")
                }
            }
        }
    }

    @ViewBuilder private var paneContent: some View {
        if !app.status.available, app.pane != .model, app.pane != .integrations, app.pane != .claude, app.pane != .github, app.pane != .integrationsHub {
            UnavailableView(status: app.status)
        } else {
            switch app.pane {
            case .chat(let id): ChatView(vm: app.chatModel(id)).id(id)
            case .recipes: RecipesView()
            case .structured: StructuredView()
            case .batch: BatchView()
            case .compare: CompareView()
            case .tokens: TokensView()
            case .bench: BenchView()
            case .history: HistoryView()
            case .model: ModelView()
            case .claude: ClaudeView()
            case .github: GitHubView()
            case .integrationsHub: IntegrationsHubView()
            case .integrations: IntegrationsView()
            case nil: RecipesView()
            }
        }
    }
}

struct Sidebar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: $app.pane) {
            Section {
                ForEach(app.sessions) { s in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title.isEmpty ? "Untitled" : s.title).lineLimit(1)
                            Text(subtitle(s)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: icon(s.source))
                    }
                    .tag(Pane.chat(s.id))
                    .contextMenu {
                        Button("Delete Chat", systemImage: "trash", role: .destructive) { app.deleteChat(s.id) }
                    }
                }
            } header: {
                HStack {
                    Text("Chats")
                    Spacer()
                    Button { app.newChat() } label: { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.borderless).help("New chat (⌘N)")
                }
            }
            Section("Workbench") {
                Label("Recipes", systemImage: "wand.and.stars").tag(Pane.recipes)
                Label("Structured Output", systemImage: "curlybraces.square").tag(Pane.structured)
                Label("Batch", systemImage: "square.stack.3d.up").tag(Pane.batch)
                Label("Compare", systemImage: "rectangle.split.3x1").tag(Pane.compare)
                Label("Tokens", systemImage: "number.square").tag(Pane.tokens)
            }
            Section("Insights") {
                Label("Benchmark", systemImage: "speedometer").tag(Pane.bench)
                Label("History", systemImage: "clock.arrow.circlepath").tag(Pane.history)
            }
            Section("Integrations") {
                Label("All Integrations", systemImage: "puzzlepiece.extension").tag(Pane.integrationsHub)
                if app.settings.integrationPrefs["github"]?.enabled == true {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right").tag(Pane.github)
                }
            }
            Section("System") {
                Label("Model", systemImage: "cpu").tag(Pane.model)
                Label("Claude", systemImage: "brain").tag(Pane.claude)
                Label("CLI & API", systemImage: "terminal").tag(Pane.integrations)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                UpdateBadge()
                HStack(spacing: 8) {
                    Circle().fill(app.status.available ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(app.status.available ? "On-device model ready" : "Model unavailable").font(.caption)
                    Spacer()
                    if app.server.running {
                        Label("API", systemImage: "antenna.radiowaves.left.and.right").font(.caption).foregroundStyle(.secondary)
                            .help("OpenAI-compatible server is running")
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.bar)
        }
    }

    func icon(_ source: String) -> String {
        switch source {
        case "mcp": "point.3.connected.trianglepath.dotted"
        case "cli": "terminal"
        case "siri": "waveform"
        default: "bubble.left.and.text.bubble.right"
        }
    }

    func subtitle(_ s: ChatSessionRecord) -> String {
        let n = s.messages.filter { $0.role != .notice }.count
        let src = s.source == "mcp" ? "Claude" : s.source == "cli" ? "Terminal" : s.source == "siri" ? "Siri" : "Studio"
        return "\(src) · \(n) message\(n == 1 ? "" : "s") · \(s.updated.formatted(.relative(presentation: .named)))"
    }
}

struct UnavailableView: View {
    let status: ModelStatus
    var body: some View {
        ContentUnavailableView {
            Label("Apple's on-device model is unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(status.guidance ?? "The model can't be used right now.")
        } actions: {
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

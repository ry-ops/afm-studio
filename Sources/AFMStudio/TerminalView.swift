import SwiftUI
import AppKit
import SwiftTerm
import AFMKit

// The integrated terminal: a VS Code-style panel under every pane, with tabs.
// Each tab runs your login shell in a real pseudo-terminal (SwiftTerm), so vim, top, ssh and colors all work.

@Observable @MainActor
final class TerminalTab: Identifiable {
    let id = UUID()
    var title: String
    var directory: String?
    let view: LocalProcessTerminalView
    private let bridge = TerminalBridge()

    init(directory: String?, fontSize: CGFloat, onExit: @escaping @MainActor (UUID) -> Void) {
        let shell = TerminalTab.loginShell()
        title = (shell as NSString).lastPathComponent
        self.directory = directory
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.nativeBackgroundColor = TerminalTab.background
        view.nativeForegroundColor = NSColor(red: 0.85, green: 0.85, blue: 0.86, alpha: 1)
        view.caretColor = .controlAccentColor
        view.optionAsMetaKey = false     // like Terminal.app: Option types special characters
        bridge.tab = self
        bridge.onExit = onExit
        view.processDelegate = bridge
        view.startProcess(executable: shell, args: [], environment: TerminalTab.environment(shell: shell),
                          execName: "-" + (shell as NSString).lastPathComponent,   // leading "-" makes it a login shell
                          currentDirectory: directory ?? NSHomeDirectory())
    }

    static let background = NSColor(red: 0.118, green: 0.118, blue: 0.125, alpha: 1)

    var label: String {
        if let d = directory, !d.isEmpty { return (d as NSString).lastPathComponent }
        return title
    }

    func setFontSize(_ size: CGFloat) { view.font = .monospacedSystemFont(ofSize: size, weight: .regular) }

    func terminate() { view.terminate() }

    /// The selection if there is one, otherwise the last `lines` non-empty lines of output.
    func textForModel(lines: Int = 80) -> (text: String, isSelection: Bool) {
        if let sel = view.getSelection(), !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (sel, true)
        }
        let all = String(decoding: view.getBufferAsData(), as: UTF8.self)
        let kept = all.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
            .suffix(lines)
        return (kept.joined(separator: "\n"), false)
    }

    static func loginShell() -> String {
        if let s = ProcessInfo.processInfo.environment["SHELL"], FileManager.default.isExecutableFile(atPath: s) { return s }
        if let pw = getpwuid(getuid()), let p = pw.pointee.pw_shell {
            let s = String(cString: p)
            if FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        return "/bin/zsh"
    }

    /// A clean environment, like Terminal.app's: the login shell's own startup files fill in the rest.
    static func environment(shell: String) -> [String] {
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        let home = NSHomeDirectory()
        env.append("PATH=\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        env.append("SHELL=\(shell)")
        env.append("TERM_PROGRAM=AFMStudio")
        env.append("TERM_PROGRAM_VERSION=\(AFMVersion.string)")
        let pe = ProcessInfo.processInfo.environment
        for key in ["TMPDIR", "SSH_AUTH_SOCK", "AFM_HOME", "AFM_ALLOWED_PATHS", "__CF_USER_TEXT_ENCODING"] {
            if let v = pe[key] { env.append("\(key)=\(v)") }
        }
        return env
    }
}

/// SwiftTerm's delegate callbacks, forwarded to the tab on the main actor.
final class TerminalBridge: LocalProcessTerminalViewDelegate {
    weak var tab: TerminalTab?
    var onExit: (@MainActor (UUID) -> Void)?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak self] in
            if !title.isEmpty { self?.tab?.title = title }
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        Task { @MainActor [weak self] in
            guard let d = directory, !d.isEmpty else { return }
            self?.tab?.directory = URL(string: d)?.path ?? d    // OSC 7 sends a file:// URL
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            guard let self, let id = self.tab?.id else { return }
            self.onExit?(id)
        }
    }
}

@Observable @MainActor
final class TerminalStore {
    var tabs: [TerminalTab] = []
    var selected: UUID?
    var visible = false
    var maximized = false
    /// Panel height, remembered between launches.
    var height: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "terminal.height")
        return v >= 120 ? v : 300
    }() {
        didSet { UserDefaults.standard.set(Double(height), forKey: "terminal.height") }
    }
    var fontSize: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "terminal.fontSize")
        return v >= 9 ? v : 13
    }()

    // On-device explanations of terminal output.
    var explainOpen = false
    var explainText = ""
    var explainSource = ""
    var explainBusy = false
    var question = ""
    private var explainTask: Task<Void, Never>?

    var current: TerminalTab? { tabs.first { $0.id == selected } ?? tabs.first }

    func toggle() {
        if visible { visible = false; return }
        if tabs.isEmpty { newTab() }
        visible = true
    }

    func newTab(in directory: String? = nil) {
        let tab = TerminalTab(directory: directory, fontSize: fontSize) { [weak self] id in self?.closed(id) }
        tabs.append(tab)
        selected = tab.id
        visible = true
    }

    func newTabInFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open Terminal Here"
        if panel.runModal() == .OK, let url = panel.url { newTab(in: url.path) }
    }

    func close(_ id: UUID) {
        tabs.first { $0.id == id }?.terminate()
        closed(id)
    }

    /// A tab whose shell exited goes away, like in VS Code.
    private func closed(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: i)
        if selected == id { selected = tabs.isEmpty ? nil : tabs[max(0, i - 1)].id }
        if tabs.isEmpty { visible = false; maximized = false }
    }

    func changeFont(by delta: CGFloat) {
        fontSize = min(28, max(9, fontSize + delta))
        UserDefaults.standard.set(Double(fontSize), forKey: "terminal.fontSize")
        for t in tabs { t.setFontSize(fontSize) }
    }

    func clear() { current?.view.send(txt: "\u{0C}") }   // Ctrl-L: the shell redraws a clean screen

    func explain() {
        guard let tab = current else { return }
        let (raw, isSelection) = tab.textForModel()
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            explainOpen = true
            explainText = "There's no output to explain yet."
            return
        }
        // Keep the newest output that fits comfortably in the 4K context, leaving room for the answer.
        var text = raw
        while Chunker.estimate(text) > 2200, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        let ask = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = (ask.isEmpty ? "Explain this terminal output." : ask) + "\n\nTerminal output:\n```\n\(text)\n```"
        let instructions = """
        You help a Mac user understand their terminal. Use only what is in the output. \
        Say briefly what happened. If there is an error, name the most likely cause and the command that fixes it. \
        If you aren't sure, say so. Keep it short.
        """
        explainSource = isSelection ? "Selection" : "Last \(text.split(separator: "\n").count) lines"
        explainOpen = true
        explainBusy = true
        explainText = ""
        explainTask?.cancel()
        explainTask = Task { [weak self] in
            do {
                // Permissive guardrails: this is the user's own text being explained, not new content.
                let req = GenerationRequest(prompt: prompt, instructions: instructions,
                                            options: GenOptions(temperature: 0.2),
                                            config: ModelConfig(guardrails: .permissive))
                let result = try await AFM.run(req, onPartial: { partial in
                    Task { @MainActor in self?.explainText = partial }
                })
                if !Task.isCancelled { self?.explainText = result.text }
            } catch {
                if !Task.isCancelled { self?.explainText = AFMError.from(error).fullDescription }
            }
            self?.explainBusy = false
        }
    }

    func stopExplaining() { explainTask?.cancel(); explainBusy = false }
}

// MARK: - Views

struct TerminalPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let term = app.terminal
        VStack(spacing: 0) {
            TerminalTabBar()
            Divider()
            HStack(spacing: 0) {
                if let tab = term.current {
                    TerminalHost(tab: tab).id(tab.id)
                } else {
                    Color(nsColor: TerminalTab.background)
                }
                if term.explainOpen {
                    Divider()
                    ExplainSidebar().frame(width: 320)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct TerminalTabBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var term = app.terminal
        HStack(spacing: 6) {
            Label("Terminal", systemImage: "terminal").font(.caption.bold()).foregroundStyle(.secondary)
                .padding(.trailing, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(term.tabs) { tab in
                        TabChip(tab: tab, selected: tab.id == term.current?.id,
                                select: { term.selected = tab.id }, close: { term.close(tab.id) })
                    }
                }
            }
            Spacer(minLength: 8)
            Group {
                Button { term.newTab() } label: { Image(systemName: "plus") }
                    .help("New terminal (⌃⇧`)")
                Button { term.newTabInFolder() } label: { Image(systemName: "folder.badge.plus") }
                    .help("New terminal in a folder…")
                Divider().frame(height: 14)
                Button { term.changeFont(by: -1) } label: { Image(systemName: "textformat.size.smaller") }
                    .help("Smaller text")
                Button { term.changeFont(by: 1) } label: { Image(systemName: "textformat.size.larger") }
                    .help("Larger text")
                Button { term.clear() } label: { Image(systemName: "eraser") }
                    .help("Clear (⌃L)")
                Divider().frame(height: 14)
                Button { term.explain() } label: { Label("Explain", systemImage: "sparkles") }
                    .disabled(!app.status.available || term.current == nil)
                    .help(app.status.available ? "Explain the selection, or the latest output, with the on-device model (⇧⌘E)"
                                               : "The on-device model is unavailable")
                Divider().frame(height: 14)
                Button { term.maximized.toggle() } label: {
                    Image(systemName: term.maximized ? "chevron.down" : "chevron.up")
                }
                .help(term.maximized ? "Restore panel size" : "Maximize panel")
                Button { term.visible = false } label: { Image(systemName: "xmark") }
                    .help("Hide the panel (⌃`). Shells keep running.")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.bar)
    }
}

struct TabChip: View {
    let tab: TerminalTab
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @ViewState private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "apple.terminal").font(.caption2)
            Text(tab.label).font(.caption).lineLimit(1)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.borderless)
                .opacity(hover || selected ? 1 : 0)
                .help("Kill this terminal")
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(selected ? Color.accentColor.opacity(0.22) : (hover ? Color.secondary.opacity(0.12) : .clear),
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hover = $0 }
        .help(tab.directory ?? tab.title)
    }
}

struct ExplainSidebar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var term = app.terminal
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("On-device explanation", systemImage: "sparkles").font(.caption.bold())
                Spacer()
                Button { term.explainOpen = false; term.stopExplaining() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            if !term.explainSource.isEmpty {
                Text(term.explainSource).font(.caption2).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(term.explainText.isEmpty && term.explainBusy ? "Reading the output…" : term.explainText)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                TextField("Ask about this output…", text: $term.question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { term.explain() }
                if term.explainBusy {
                    Button { term.stopExplaining() } label: { Image(systemName: "stop.fill") }.help("Stop")
                } else {
                    Button { term.explain() } label: { Image(systemName: "arrow.up") }.help("Ask")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(term.explainText, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .help("Copy the explanation")
                .disabled(term.explainText.isEmpty)
            }
            .buttonStyle(.borderless)
            Text("Runs on this Mac. It can be wrong, so check commands before you run them.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.background)
    }
}

/// The drag bar above the panel, like VS Code's sash.
struct PanelResizeHandle: View {
    @Binding var height: CGFloat
    let maxHeight: CGFloat
    @ViewState private var start: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    if start == nil { start = height }
                    height = min(max(120, (start ?? height) - g.translation.height), max(120, maxHeight))
                }
                .onEnded { _ in start = nil })
            .help("Drag to resize the terminal")
    }
}

/// Hosts a tab's long-lived terminal view. The view outlives this wrapper, so hiding
/// the panel or switching tabs never kills a shell.
struct TerminalHost: NSViewRepresentable {
    let tab: TerminalTab

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = TerminalTab.background.cgColor
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if tab.view.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        let v = tab.view
        v.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        // A little breathing room around the text, like VS Code.
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            v.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
    }
}

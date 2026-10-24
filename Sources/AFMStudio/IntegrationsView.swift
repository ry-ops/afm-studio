import SwiftUI
import AFMKit
import AFMServer

enum CLILocator {
    static var installedLink: String { (("~/.local/bin/afm") as NSString).expandingTildeInPath }

    /// The afm binary that ships with this build of the app.
    static var bundled: String? {
        let fm = FileManager.default
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/afm").path,
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("afm").path,
        ].compactMap { $0 }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: installedLink) }

    /// The path Claude should launch: the stable symlink if installed, else the bundled binary.
    static var preferred: String? { isInstalled ? installedLink : bundled }

    static func install() throws {
        guard let src = bundled else { throw AFMError(code: "no_cli", message: "This build doesn't include the afm command.") }
        let fm = FileManager.default
        let dir = (installedLink as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: installedLink)) != nil || fm.fileExists(atPath: installedLink) {
            try fm.removeItem(atPath: installedLink)
        }
        try fm.createSymbolicLink(atPath: installedLink, withDestinationPath: src)
    }
}

enum Shell {
    /// Runs a command through a login shell so the user's PATH (e.g. for `claude`) is available.
    static func run(_ command: String) async -> (Int32, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", command]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch { cont.resume(returning: (-1, error.localizedDescription)); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

struct IntegrationsView: View {
    @Environment(AppState.self) private var app
    @State private var cliMessage: String?
    @State private var claudeCodeMessage: String?
    @State private var desktopMessage: String?
    @State private var port = "11535"
    @State private var token = ""
    @State private var sample = 0
    @State private var working = false

    var cliPath: String { CLILocator.preferred ?? "/path/to/afm" }
    var claudeCommand: String { "claude mcp add --scope user afm -- \"\(cliPath)\" mcp" }
    var desktopJSON: String { JSONSchemaConverter.jsonText(["mcpServers": ["afm": ["command": cliPath, "args": ["mcp"]]]]) }
    var desktopConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader(title: "CLI & API", subtitle: "Use the on-device model from Terminal, Claude and any OpenAI-compatible tool.", symbol: "point.3.connected.trianglepath.dotted")

                Card(title: "Command line", symbol: "terminal") {
                    HStack {
                        Image(systemName: CLILocator.isInstalled ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(CLILocator.isInstalled ? .green : .secondary)
                        Text(CLILocator.isInstalled ? "`afm` is installed at ~/.local/bin/afm" : "Install the `afm` command to use it in Terminal and with Claude.")
                        Spacer()
                        Button(CLILocator.isInstalled ? "Reinstall" : "Install afm") {
                            do { try CLILocator.install(); cliMessage = "Installed. Make sure ~/.local/bin is on your PATH." }
                            catch { cliMessage = AFMError.from(error).fullDescription }
                        }
                        .disabled(CLILocator.bundled == nil)
                    }
                    if let cliMessage { Text(cliMessage).font(.callout).foregroundStyle(.secondary) }
                    code("afm \"Explain DNS like I'm new to networking\"\ngit diff | afm run commit-message\npbpaste | afm run summarize -p style=\"a one-line TL;DR\"\nafm chat --session ideas")
                }

                Card(title: "Claude Code & Claude Desktop", symbol: "brain") {
                    Text("AFM Studio registers the afm MCP server with Claude automatically. Manage it, and your Anthropic API key, in the Claude section.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open Claude Settings") { app.pane = .claude }
                }

                Card(title: "OpenAI-compatible API", symbol: "antenna.radiowaves.left.and.right") {
                    Text("A local server on 127.0.0.1 that speaks the OpenAI Chat Completions API, with streaming and JSON Schema output. Point editors, scripts and SDKs at it.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        TextField("Port", text: $port).frame(width: 80).textFieldStyle(.roundedBorder)
                        SecureField("Bearer token (optional)", text: $token).frame(width: 220).textFieldStyle(.roundedBorder)
                        Toggle("Running", isOn: Binding(get: { app.server.running }, set: { on in
                            if on { app.server.start(port: Int(port) ?? 11535, token: token.isEmpty ? nil : token) } else { app.server.stop() }
                        }))
                        .toggleStyle(.switch)
                        Spacer()
                        if app.server.running { Label("http://127.0.0.1:\(port)/v1", systemImage: "circle.fill").foregroundStyle(.green).font(.callout) }
                    }
                    if let e = app.server.error { Text(e).foregroundStyle(.orange).font(.callout) }
                    Picker("", selection: $sample) { Text("curl").tag(0); Text("Python").tag(1); Text("JavaScript").tag(2) }
                        .pickerStyle(.segmented).frame(width: 300)
                    code(sampleCode)
                    if !app.server.log.isEmpty {
                        DisclosureGroup("Request log (\(app.server.log.count))") {
                            ScrollView {
                                Text(app.server.log.suffix(60).joined(separator: "\n")).font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 140)
                        }
                    }
                }
            }
            .padding(22)
        }
        .onAppear { port = String(app.settings.serverPort) }
    }

    var sampleCode: String {
        let base = "http://127.0.0.1:\(port)/v1"
        let auth = token.isEmpty ? "" : " -H 'Authorization: Bearer \(token)'"
        switch sample {
        case 1:
            return """
            from openai import OpenAI
            client = OpenAI(base_url="\(base)", api_key="\(token.isEmpty ? "unused" : token)")
            r = client.chat.completions.create(
                model="apple-foundation-model",
                messages=[{"role": "user", "content": "Give me a haiku about Swift."}],
            )
            print(r.choices[0].message.content)
            """
        case 2:
            return """
            import OpenAI from "openai";
            const client = new OpenAI({ baseURL: "\(base)", apiKey: "\(token.isEmpty ? "unused" : token)" });
            const r = await client.chat.completions.create({
              model: "apple-foundation-model",
              messages: [{ role: "user", content: "Give me a haiku about Swift." }],
            });
            console.log(r.choices[0].message.content);
            """
        default:
            return """
            curl \(base)/chat/completions\(auth) -H 'Content-Type: application/json' -d '{
              "model": "apple-foundation-model",
              "messages": [{"role": "user", "content": "Give me a haiku about Swift."}],
              "stream": true
            }'
            """
        }
    }

    func code(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(10)
            }
            CopyButton(text: s, compact: true).padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

}

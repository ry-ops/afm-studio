import Foundation
import AFMKit
import AFMServer
import AFMGitHub

// MARK: - Arguments

struct Args {
    var positionals: [String] = []
    var system: String?
    var temperature: Double?
    var maxTokens: Int?
    var sampling: SamplingKind = .automatic
    var topK = 40
    var topP = 0.9
    var seed: UInt64?
    var permissive = false
    var tagging = false
    var stream: Bool?
    var json = false
    var file: String?
    var tools: [ToolKind] = []
    var schema: String?
    var fields: String?
    var session: String?
    var params: [String: String] = [:]
    var port: Int?
    var token: String?
    var rounds = 1
    var limit = 20
    var stats = false
    var help = false

    var options: GenOptions { GenOptions(temperature: temperature, maxTokens: maxTokens, sampling: sampling, topK: topK, topP: topP, seed: seed) }
    var config: ModelConfig {
        var c = AFMSettings.load().defaultConfig
        if permissive { c.guardrails = .permissive }
        if tagging { c.useCase = .tagging }
        return c
    }
}

func parsed<T>(_ v: T?, _ what: String) -> T {
    guard let v else { fail("bad \(what)", code: 2) }
    return v
}

func parseArgs(_ raw: [String]) -> Args {
    var a = Args()
    var it = raw.makeIterator()
    func value(_ flag: String) -> String {
        guard let v = it.next() else { fail("\(flag) needs a value", code: 2) }
        return v
    }
    var flagsDone = false
    while let arg = it.next() {
        if flagsDone || !arg.hasPrefix("-") || arg == "-" { a.positionals.append(arg); continue }
        switch arg {
        case "--": flagsDone = true
        case "-h", "--help": a.help = true
        case "-s", "--system", "--instructions": a.system = value(arg)
        case "-t", "--temp", "--temperature": a.temperature = parsed(Double(value(arg)), "temperature")
        case "-m", "--max-tokens": a.maxTokens = parsed(Int(value(arg)), "max tokens")
        case "--greedy": a.sampling = .greedy
        case "--top-k": a.sampling = .topK; a.topK = Int(value(arg)) ?? 40
        case "--top-p": a.sampling = .topP; a.topP = Double(value(arg)) ?? 0.9
        case "--seed": a.seed = UInt64(value(arg))
        case "--permissive": a.permissive = true
        case "--tagging": a.tagging = true
        case "--stream": a.stream = true
        case "--no-stream": a.stream = false
        case "--json": a.json = true
        case "-f", "--file": a.file = value(arg)
        case "--tool":
            let v = value(arg)
            if v == "all" { a.tools = ToolKind.allCases }
            else if v == "safe" { a.tools = ToolKind.safe }
            else { for part in v.split(separator: ",") { guard let k = ToolKind(rawValue: String(part)) else { fail("unknown tool \(part)", hint: "Run `afm tools` to list them.", code: 2) }; a.tools.append(k) } }
        case "--tools": a.tools = ToolKind.safeDefaults
        case "--schema": a.schema = value(arg)
        case "--fields": a.fields = value(arg)
        case "--session": a.session = value(arg)
        case "-p", "--param":
            let kv = value(arg)
            guard let i = kv.firstIndex(of: "=") else { fail("--param needs key=value", code: 2) }
            a.params[String(kv[..<i])] = String(kv[kv.index(after: i)...])
        case "--port": a.port = Int(value(arg))
        case "--token": a.token = value(arg)
        case "--rounds", "--runs": a.rounds = Int(value(arg)) ?? 1
        case "-n", "--limit": a.limit = Int(value(arg)) ?? 20
        case "--stats", "-v": a.stats = true
        case "--version": a.positionals.insert("version", at: 0)
        case "--chat", "--claude", "--model", "--effort", "--base", "--from", "--to", "--focus", "--notes", "--from-repo", "--days", "--engine":
            a.positionals.append(arg); a.positionals.append(value(arg))
        default:
            fail("unknown option \(arg)", hint: "Run `afm --help`.", code: 2)
        }
    }
    if let w = ToolKind.riskWarning(a.tools) { eprint(paint("afm: warning: ", "33", tty: stderrTTY) + w) }
    return a
}

func readStdin() -> String? {
    var st = stat()
    fstat(0, &st)
    let t = st.st_mode & S_IFMT
    guard t == S_IFIFO || t == S_IFREG else { return nil }
    guard let d = try? FileHandle.standardInput.readToEnd(), let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
    return s
}

func readFileArg(_ path: String) -> String {
    let p = (path as NSString).expandingTildeInPath
    guard let s = try? String(contentsOfFile: p, encoding: .utf8) else { fail("can't read \(path)") }
    return s
}

/// Positional text, then --file, then stdin, joined.
func gatherInput(_ a: Args, positionals: [String]) -> String {
    var parts: [String] = []
    let p = positionals.joined(separator: " ")
    if !p.isEmpty { parts.append(p) }
    if let f = a.file { parts.append(readFileArg(f)) }
    if let s = readStdin() { parts.append(s) }
    return parts.joined(separator: "\n\n")
}

func requireModel() {
    let s = ModelStatus.current()
    if !s.available { fail("Apple's on-device model is unavailable (\(s.reason ?? "unknown")).", hint: s.guidance, code: 3) }
}

func printResult(_ r: GenerationResult, a: Args, streamed: Bool) {
    if a.json {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let d = try? enc.encode(r) { out(String(decoding: d, as: UTF8.self)) }
        return
    }
    if !streamed { out(r.text) }
    if a.stats { eprint(dim(r.statsLine, tty: stderrTTY)) }
}

/// Streams by default when writing to a terminal.
func shouldStream(_ a: Args) -> Bool { !a.json && (a.stream ?? stdoutTTY) }

func streamPrinter() -> @Sendable (String) -> Void {
    let state = PrintState()
    return { text in state.emit(text) }
}

final class PrintState: @unchecked Sendable {
    let lock = NSLock()
    var printed = ""
    func emit(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        if text.hasPrefix(printed) {
            out(String(text.dropFirst(printed.count)), terminator: "")
        } else {
            out("\n" + text, terminator: "")
        }
        printed = text
    }
}

// MARK: - Commands

let help = """
\(bold("afm")) — Apple's on-device foundation model from your terminal, Claude and any OpenAI client.

\(bold("USAGE"))
  afm [ask] "prompt"              One-shot prompt (stdin is added as context)
  afm chat [--session NAME]       Interactive chat, saved and resumable
  afm run RECIPE [text]           Run a recipe on text, --file or stdin
  afm recipes                     List recipes
  afm extract --fields SPEC       JSON extraction, e.g. --fields "name:string, total:number"
  afm extract --schema FILE       JSON extraction with a JSON Schema file
  afm tokens [text]               Count tokens with the on-device tokenizer
  afm status                      Model availability, context size, languages
  afm bench [--rounds N]          Measure first-token latency and tokens/sec
  afm sessions [show|rm|export ID]
  afm history [-n N]              Recent runs from every surface
  afm tools                       Tools the model can call
  afm mcp                         Run the MCP server on stdio (for Claude)
  afm mcp config                  Print the commands to register it with Claude
  afm serve [--port 11535]        OpenAI-compatible server on 127.0.0.1
  afm studio                      Open the AFM Studio app
  afm claude ...                  Claude via your API key, compare, MCP hook (afm claude help)
  afm integrations                List integrations and turn them on or off (all start off)
  afm github ...                  Digests, summaries, triage, PR text, release notes, blog drafts (afm github help)

\(bold("OPTIONS"))
  -s, --system TEXT     Instructions (system prompt)
  -t, --temp N          Temperature            -m, --max-tokens N   Response limit
  --greedy | --top-k N | --top-p N   Sampling  --seed N             Reproducible sampling
  --permissive          Looser guardrails for transforming your own text
  --tagging             Content-tagging model
  --tool NAME[,NAME]    Let the model call tools (safe, all, datetime, calculator, ...)
  -f, --file PATH       Read input from a file -p, --param K=V      Recipe parameter
  --json                Machine-readable output --stats             Timing and token stats
  --stream / --no-stream (streams by default in a terminal)

\(bold("EXAMPLES"))
  afm "Explain DNS like I'm new to networking"
  git diff | afm run commit-message
  afm run summarize -f report.md -p style="an executive summary"
  pbpaste | afm run translate -p language=Japanese
  afm extract --fields "vendor:string, total:number, items:[string]" < receipt.txt
  afm --tool safe "What's 17.5% of 2,340, and what day is it?"
"""

func cmdAsk(_ a: Args) async {
    let prompt = gatherInput(a, positionals: a.positionals)
    if prompt.isEmpty { out(help); exit(2) }
    requireModel()
    let streaming = shouldStream(a)
    let printer = streamPrinter()
    do {
        let partial: (@Sendable (String) -> Void)? = streaming ? printer : nil
        var toolLog: (@Sendable (String) -> Void)? = nil
        if a.stats { toolLog = { line in eprint(dim("  ⚙︎ " + line, tty: stderrTTY)) } }
        let req = GenerationRequest(prompt: prompt, instructions: a.system, options: a.options, config: a.config, tools: a.tools)
        let r = try await AFM.run(req, onPartial: partial, onTool: toolLog)
        if streaming { out("") }
        printResult(r, a: a, streamed: streaming)
        History.append(HistoryEntry(source: "cli", kind: "ask", title: String(prompt.prefix(60)), input: prompt, output: r.text, seconds: r.seconds, outputTokens: r.outputTokens))
    } catch { if streaming { out("") }; fail(error) }
}

func cmdRun(_ a: Args) async {
    guard let id = a.positionals.first else {
        fail("which recipe?", hint: "Run `afm recipes` to list them.", code: 2)
    }
    guard let recipe = RecipeBook.shared.find(id) else { fail("no recipe named \(id)", hint: "Run `afm recipes`.", code: 2) }
    let input = gatherInput(a, positionals: Array(a.positionals.dropFirst()))
    if input.isEmpty && recipe.template.contains("{{input}}") { fail("no input", hint: "Pass text, --file PATH, or pipe into afm.", code: 2) }
    requireModel()
    let streaming = shouldStream(a)
    let printer = streamPrinter()
    var cfg = a.config
    if a.permissive { cfg.guardrails = .permissive }
    do {
        let partial: (@Sendable (String) -> Void)? = streaming ? printer : nil
        var progress: (@Sendable (RecipeRunner.Progress) -> Void)? = nil
        if stderrTTY { progress = { p in eprint(dim("  … \(p.stage)", tty: true)) } }
        let r = try await RecipeRunner.run(recipe, input: input, params: a.params, options: a.options, config: cfg,
                                           onPartial: partial, onProgress: progress)
        if streaming { out("") }
        printResult(r, a: a, streamed: streaming)
        History.append(HistoryEntry(source: "cli", kind: "recipe", title: recipe.title, input: input, output: r.text, seconds: r.seconds, outputTokens: r.outputTokens))
    } catch { if streaming { out("") }; fail(error) }
}

func cmdExtract(_ a: Args) async {
    let schemaText: String
    if let s = a.schema { schemaText = readFileArg(s) }
    else if let f = a.fields {
        do { schemaText = JSONSchemaConverter.jsonText(try JSONSchemaConverter.jsonSchema(fromFields: f, title: "Extraction")) } catch { fail(error) }
    } else { fail("give --fields SPEC or --schema FILE", code: 2) }
    let input = gatherInput(a, positionals: a.positionals)
    if input.isEmpty { fail("no input text", hint: "Pass text, --file PATH, or pipe into afm.", code: 2) }
    requireModel()
    let recipe = Recipe(id: "_extract", title: "Extract", summary: "",
                        instructions: a.system ?? "You extract information from text into the requested fields. Use only information in the text. Use an empty string or empty list when something isn't present.",
                        template: "Extract the requested fields from this text.\n\nText:\n\"\"\"\n{{input}}\n\"\"\"",
                        schema: schemaText, temperature: 0.1, permissive: true, long: .merge)
    do {
        let r = try await RecipeRunner.run(recipe, input: input, options: a.options, config: a.config)
        printResult(r, a: a, streamed: false)
        History.append(HistoryEntry(source: "cli", kind: "extract", title: "Extract", input: input, output: r.text, seconds: r.seconds, outputTokens: r.outputTokens))
    } catch { fail(error) }
}

func cmdRecipes(_ a: Args) {
    let all = RecipeBook.shared.all()
    if a.json {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        out(String(decoding: (try? enc.encode(all)) ?? Data(), as: UTF8.self)); return
    }
    for cat in ["Understand", "Write", "Extract", "Code"] + Array(Set(all.map(\.category))).filter({ !["Understand", "Write", "Extract", "Code"].contains($0) }).sorted() {
        let rs = all.filter { $0.category == cat }
        if rs.isEmpty { continue }
        out(bold(cat))
        for r in rs {
            let id = r.id.padding(toLength: 16, withPad: " ", startingAt: 0)
            var line = "  \(accent(id)) \(r.summary)"
            if r.isStructured { line += dim(" [json]") }
            if !r.isBuiltin { line += dim(" [yours]") }
            out(line)
            for p in r.params {
                let choices = p.choices.map { " (" + $0.joined(separator: " | ") + ")" } ?? ""
                out(dim("                   -p \(p.key)=\"\(p.defaultValue)\"\(choices)"))
            }
        }
        out("")
    }
    out(dim("Your recipes live in \(RecipeBook.shared.userDirectory.path). Drop a JSON file there to add one."))
}

func cmdTokens(_ a: Args) async {
    let text = gatherInput(a, positionals: a.positionals)
    let n = await AFM.tokenCount(text, config: a.config)
    let ctx = AFM.contextSize
    if a.json { out(JSONSchemaConverter.jsonText(["tokens": n, "context_size": ctx, "characters": text.count])); return }
    let pct = Double(n) / Double(ctx)
    let width = 30
    let filled = min(width, Int(pct * Double(width)))
    let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    out("\(bold(String(n))) tokens  \(pct > 0.85 ? warn(bar) : good(bar))  \(Int(pct * 100))% of \(ctx)")
    if pct > 0.85 { out(dim("Recipes split text this long into chunks automatically.")) }
}

func cmdStatus(_ a: Args) {
    let s = ModelStatus.current()
    if a.json {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        out(String(decoding: (try? enc.encode(s)) ?? Data(), as: UTF8.self)); return
    }
    out(s.available ? good("● available") : warn("● unavailable (\(s.reason ?? "unknown"))"))
    if let g = s.guidance { out("  " + g) }
    out("  Context window   \(s.contextSize) tokens")
    out("  Content tagging  \(s.taggingAvailable ? "available" : "unavailable")")
    out("  macOS            \(s.osVersion)")
    out("  Languages        \(s.languages.count): " + s.languages.map(ModelStatus.languageName).joined(separator: ", "))
    out("  Data folder      \(AFMPaths.root.path)")
}

func cmdBench(_ a: Args) async {
    requireModel()
    out(bold("Benchmark") + dim("  greedy sampling, \(Bench.tasks.count) tasks × \(a.rounds) round(s)"))
    out(dim("  task           first token   total    tokens   tok/s"))
    do {
        let runs = try await Bench.run(rounds: a.rounds, config: a.config) { r in
            out(String(format: "  %@ %8.2fs %9.2fs %8d %7.1f", r.task.padding(toLength: 14, withPad: " ", startingAt: 0), r.firstToken, r.total, r.outputTokens, r.tokensPerSecond))
        }
        let tps = runs.map(\.tokensPerSecond).reduce(0, +) / Double(max(runs.count, 1))
        let ttft = runs.map(\.firstToken).sorted()[runs.count / 2]
        out(bold(String(format: "  median first token %.2fs · mean %.1f tok/s", ttft, tps)))
        if a.json {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
            out(String(decoding: (try? enc.encode(runs)) ?? Data(), as: UTF8.self))
        }
    } catch { fail(error) }
}

func cmdTools(_ a: Args) {
    for t in ToolKind.allCases {
        out("  \(accent(t.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0))) \(t.summary)\(t.isSensitive ? dim(" [opt-in]") : "")")
    }
    out(dim("\nUse --tool safe (datetime, calculator, system_info), --tool all, or --tool read_file,fetch_url."))
}

func cmdSessions(_ a: Args) {
    let sub = a.positionals.first ?? "list"
    let store = SessionStore.shared
    switch sub {
    case "list":
        let all = store.list()
        if a.json {
            out(JSONSchemaConverter.jsonText(all.map { ["id": $0.id, "title": $0.title, "messages": $0.messages.count, "source": $0.source, "updated": ISO8601DateFormatter().string(from: $0.updated)] }))
            return
        }
        if all.isEmpty { out(dim("No saved chats yet. Start one with `afm chat`.")); return }
        let f = RelativeDateTimeFormatter()
        for s in all.prefix(a.limit) {
            out("  \(accent(s.id.padding(toLength: 22, withPad: " ", startingAt: 0))) \(s.title)  \(dim("\(s.messages.filter { $0.role != .notice }.count) msgs · \(s.source) · \(f.localizedString(for: s.updated, relativeTo: Date()))"))")
        }
    case "show", "export":
        guard a.positionals.count > 1, let r = store.load(a.positionals[1]) else { fail("no session with that id", code: 2) }
        out(ChatEngine(record: r, persist: false).markdownExport())
    case "rm", "delete":
        guard a.positionals.count > 1 else { fail("which session?", code: 2) }
        store.delete(a.positionals[1]); out("Deleted \(a.positionals[1]).")
    default:
        fail("unknown sessions command \(sub)", hint: "Use list, show ID, export ID or rm ID.", code: 2)
    }
}

func cmdHistory(_ a: Args) {
    let items = History.load(limit: a.limit)
    if a.json {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]; enc.dateEncodingStrategy = .iso8601
        out(String(decoding: (try? enc.encode(items)) ?? Data(), as: UTF8.self)); return
    }
    if items.isEmpty { out(dim("No history yet.")); return }
    let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"
    for h in items {
        let first = h.output.split(separator: "\n").first.map(String.init) ?? ""
        out("\(dim(f.string(from: h.date))) \(accent(h.source.padding(toLength: 6, withPad: " ", startingAt: 0))) \(h.kind.padding(toLength: 14, withPad: " ", startingAt: 0)) \(h.ok ? "" : warn("✗ "))\(String(first.prefix(70)))")
    }
}

func executablePath() -> String {
    let arg0 = CommandLine.arguments[0]
    let path = arg0.contains("/") ? arg0 : (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(arg0)" }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? arg0
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

func cmdMCP(_ a: Args) async {
    if a.positionals.first == "config" {
        let path = executablePath()
        out(bold("Claude Code") + dim("  (available in every project)"))
        out("  claude mcp add --scope user afm -- \"\(path)\" mcp\n")
        out(bold("Claude Desktop") + dim("  ~/Library/Application Support/Claude/claude_desktop_config.json"))
        out(JSONSchemaConverter.jsonText(["mcpServers": ["afm": ["command": path, "args": ["mcp"]]]]))
        if path.contains("/.build/") { out(warn("\nThis binary is inside .build. Install it first (bash scripts/install.sh) so the path stays stable.")) }
        return
    }
    await MCPServer().run()
}

func cmdServe(_ a: Args) async {
    requireModel()
    let port = UInt16(a.port ?? AFMSettings.load().serverPort)
    let server = OpenAIServer(port: port, token: a.token)
    server.onLog = { line in eprint(dim("[\(ISO8601DateFormatter().string(from: Date()))] \(line)", tty: stderrTTY)) }
    do { try server.start() } catch { fail(error) }
    out(bold("AFM OpenAI-compatible server") + "  \(accent(server.baseURL))")
    out(dim("Models: " + OpenAIServer.models.joined(separator: ", ")))
    out(dim("""
    Try:
      curl \(server.baseURL)/chat/completions -H 'Content-Type: application/json' \\
        -d '{"model":"apple-foundation-model","messages":[{"role":"user","content":"Hello!"}]}'
    Press Ctrl-C to stop.
    """))
    while true { try? await Task.sleep(for: .seconds(3600)) }
}

func cmdStudio() {
    let fm = FileManager.default
    let exe = URL(fileURLWithPath: executablePath())
    var candidates = [
        exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path, // inside .app/Contents/Helpers
        "/Applications/AFM Studio.app",
        (("~/Applications/AFM Studio.app") as NSString).expandingTildeInPath,
    ]
    candidates = candidates.filter { $0.hasSuffix(".app") && fm.fileExists(atPath: $0) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = candidates.first.map { [$0] } ?? ["-b", "dev.ry-ops.afm-studio"]
    do { try p.run(); p.waitUntilExit() } catch { fail(error) }
    if p.terminationStatus != 0 { fail("AFM Studio isn't installed", hint: "Build it with: bash scripts/build-app.sh --install") }
}

func cmdChat(_ a: Args) async {
    requireModel()
    let id = a.session ?? "cli-" + String(UUID().uuidString.prefix(8)).lowercased()
    let engine = ChatEngine.open(id: id, source: "cli")
    engine.update { r in
        if let s = a.system { r.instructions = s }
        if !a.tools.isEmpty { r.tools = a.tools }
        r.options = a.options
        r.config = a.config
    }
    let resumed = engine.record.messages.contains { $0.role == .user }
    out(bold("afm chat") + dim("  session \(id)\(resumed ? " (resumed, \(engine.record.messages.count) messages)" : "")  ·  /help for commands"))
    while true {
        out(accent("› "), terminator: "")
        guard let line = readLine() else { out(""); break }
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { continue }
        if text.hasPrefix("/") {
            let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
            switch parts[0] {
            case "/exit", "/quit", "/q": return
            case "/help":
                out(dim("""
                /reset            clear the conversation
                /system TEXT      set instructions
                /tokens           context usage
                /compact          summarize older turns now
                /tools            list enabled tools
                /export           print the chat as Markdown
                /exit             leave (the chat is saved; resume with --session \(id))
                """))
            case "/reset": engine.reset(); out(dim("Cleared."))
            case "/system":
                engine.update { $0.instructions = parts.count > 1 ? parts[1] : ChatSessionRecord.defaultInstructions }
                out(dim("Instructions updated."))
            case "/tokens":
                let u = await engine.contextUsage()
                out(dim("\(u.used) of \(u.total) tokens used"))
            case "/compact":
                do { try await engine.compact(); out(dim("Compacted.")) } catch { eprint(AFMError.from(error).fullDescription) }
            case "/tools": out(dim(engine.record.tools.map(\.rawValue).joined(separator: ", ")))
            case "/export": out(engine.markdownExport())
            default: out(dim("Unknown command. /help lists them."))
            }
            continue
        }
        let printer = streamPrinter()
        do {
            let msg = try await engine.send(text, onPartial: printer,
                                            onTool: { eprint(dim("  ⚙︎ \($0)", tty: stderrTTY)) },
                                            onNotice: { eprint(dim("  ↺ \($0)", tty: stderrTTY)) })
            out("")
            if a.stats { eprint(dim(String(format: "  %.1fs · %d tokens", msg.seconds ?? 0, msg.tokens ?? 0), tty: stderrTTY)) }
        } catch {
            out("")
            let e = AFMError.from(error)
            eprint(warn(e.message) + (e.suggestion.map { " " + dim($0) } ?? ""))
        }
    }
}

// MARK: - Main

IntegrationRegistry.install([GitHubIntegration()])
var args = parseArgs(Array(CommandLine.arguments.dropFirst()))
let commands: Set<String> = ["ask", "chat", "run", "recipes", "extract", "tokens", "status", "bench", "sessions", "history", "tools", "mcp", "serve", "studio", "claude", "github", "gh", "integrations", "help", "version"]
var command = "ask"
if let first = args.positionals.first, commands.contains(first) {
    command = first
    args.positionals.removeFirst()
}
if args.help || command == "help" { out(help); exit(0) }

switch command {
case "version": out("afm \(AFMVersion.string)")
case "ask": await cmdAsk(args)
case "chat": await cmdChat(args)
case "run": await cmdRun(args)
case "recipes": cmdRecipes(args)
case "extract": await cmdExtract(args)
case "tokens": await cmdTokens(args)
case "status": cmdStatus(args)
case "bench": await cmdBench(args)
case "sessions": cmdSessions(args)
case "history": cmdHistory(args)
case "tools": cmdTools(args)
case "mcp": await cmdMCP(args)
case "serve": await cmdServe(args)
case "studio": cmdStudio()
case "claude": await cmdClaude(args)
case "github", "gh": await cmdGitHub(args)
case "integrations": cmdIntegrations(args)
default: out(help)
}

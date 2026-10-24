import Foundation
import AFMKit

let claudeHelp = """
\(bold("afm claude")) — the cloud side: Claude via your Anthropic API key, plus Claude MCP wiring.

  afm claude "prompt"            Ask Claude (key from the Keychain, or ANTHROPIC_API_KEY)
  afm claude compare "prompt"    Same prompt on-device and on Claude, side by side with cost
  afm claude key set             Store your API key in the macOS Keychain (paste or pipe it in)
  afm claude key status          Show where the key comes from (masked)
  afm claude key rm              Delete the key from the Keychain
  afm claude hook                Register afm as an MCP server in Claude Code and Claude Desktop
  afm claude unhook              Remove those registrations
  afm claude status              Key, model and MCP registration status

  --model ID     claude-opus-5-5 (default), claude-sonnet-5-5, claude-haiku-5-5, claude-fable-5-1
  --effort E     low, medium (default), high, xhigh, max
"""

func readSecret(_ prompt: String) -> String {
    if let s = readStdin() { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard let p = getpass(prompt) else { return "" }
    return String(cString: p)
}

func cmdClaude(_ a: Args) async {
    var args = a.positionals
    var model = AFMSettings.load().claudeModel
    var effort = AFMSettings.load().claudeEffort
    // --model / --effort are parsed loosely here so the main parser stays simple.
    if let i = args.firstIndex(of: "--model"), i + 1 < args.count { model = args[i + 1]; args.removeSubrange(i...(i + 1)) }
    if let i = args.firstIndex(of: "--effort"), i + 1 < args.count { effort = args[i + 1]; args.removeSubrange(i...(i + 1)) }
    let sub = args.first ?? "help"

    switch sub {
    case "help":
        out(claudeHelp)

    case "key":
        switch args.dropFirst().first ?? "status" {
        case "set":
            let key = readSecret("Anthropic API key (input hidden): ")
            do { try ClaudeKeychain.save(key); out(good("✓ Saved to the macOS Keychain.") + dim(" It is never written to disk or to the repo.")) }
            catch { fail(error) }
        case "rm", "delete":
            ClaudeKeychain.delete(); out("Removed the key from the Keychain.")
        default:
            let r = ClaudeKeychain.resolve()
            switch r.source {
            case .keychain: out("Keychain: \(ClaudeKeychain.masked(r.key!))")
            case .environment: out("ANTHROPIC_API_KEY: \(ClaudeKeychain.masked(r.key!))")
            case .none: out(warn("No key set.") + dim(" Run `afm claude key set`."))
            }
        }

    case "hook":
        let path = ClaudeHook.stableCLIPath
        if !FileManager.default.isExecutableFile(atPath: path) {
            fail("\(path) isn't installed yet.", hint: "Run `bash scripts/install.sh`, or open AFM Studio once.")
        }
        do { out("Claude Code:    " + (try ClaudeHook.hookClaudeCode(cliPath: path))) } catch { eprint("Claude Code:    " + AFMError.from(error).fullDescription) }
        do { out("Claude Desktop: " + (try ClaudeHook.hookDesktop(cliPath: path))) } catch { eprint("Claude Desktop: " + AFMError.from(error).fullDescription) }

    case "unhook":
        out("Claude Code:    " + ClaudeHook.unhookClaudeCode())
        do { out("Claude Desktop: " + (try ClaudeHook.unhookDesktop())) } catch { eprint(AFMError.from(error).fullDescription) }

    case "status":
        let r = ClaudeKeychain.resolve()
        out(bold("API key   ") + (r.key.map { "\(ClaudeKeychain.masked($0)) (\(r.source.rawValue))" } ?? warn("not set")))
        out(bold("Model     ") + "\(model) · effort \(effort)")
        let s = ClaudeHook.status()
        out(bold("Claude Code    ") + (!s.claudeCLIFound ? dim("claude CLI not found") : s.claudeCodeHooked ? good("● afm registered") + dim(" → \(s.claudeCodePath ?? "?")") : warn("○ not registered")))
        out(bold("Claude Desktop ") + (s.desktopHooked ? good("● afm registered") + dim(" → \(s.desktopPath ?? "?")") : warn("○ not registered")))

    case "compare":
        let prompt = gatherInput(a, positionals: Array(args.dropFirst()))
        if prompt.isEmpty { fail("no prompt", code: 2) }
        requireModel()
        do {
            let client = try ClaudeClient.fromStoredKey(model: model, effort: effort)
            out(bold("On-device (Apple Foundation Model)"))
            let local = try await AFM.run(GenerationRequest(prompt: prompt, instructions: a.system, options: a.options, config: a.config))
            out(local.text)
            out(dim(String(format: "%.1fs · %d tokens · free, private", local.seconds, local.outputTokens ?? 0)) + "\n")
            out(bold(ClaudeModel.find(model).name))
            let printer = streamPrinter()
            let r = try await client.stream(prompt, system: a.system, onText: stdoutTTY ? printer : nil)
            if !stdoutTTY { out(r.text) } else { out("") }
            out(dim(String(format: "%.1fs · %d in / %d out tokens · $%.4f", r.seconds, r.inputTokens, r.outputTokens, r.cost(ClaudeModel.find(model)))))
        } catch { fail(error) }

    default:
        let prompt = gatherInput(a, positionals: args)
        if prompt.isEmpty { out(claudeHelp); exit(2) }
        do {
            let client = try ClaudeClient.fromStoredKey(model: model, effort: effort)
            let streaming = shouldStream(a)
            let printer = streamPrinter()
            let r = try await client.stream(prompt, system: a.system, onText: streaming ? printer : nil)
            if streaming { out("") } else if !a.json { out(r.text) }
            if a.json {
                out(JSONSchemaConverter.jsonText(["text": r.text, "model": r.model, "input_tokens": r.inputTokens, "output_tokens": r.outputTokens,
                                                  "seconds": r.seconds, "cost_usd": r.cost(ClaudeModel.find(model))]))
            }
            if a.stats { eprint(dim(String(format: "%@ · %.1fs · %d in / %d out · $%.4f", r.model, r.seconds, r.inputTokens, r.outputTokens, r.cost(ClaudeModel.find(model))), tty: stderrTTY)) }
            History.append(HistoryEntry(source: "cli", kind: "claude", title: r.model, input: prompt, output: r.text, seconds: r.seconds, outputTokens: r.outputTokens))
        } catch { fail(error) }
    }
}

// Self-test for AFMKit and AFMServer. Runs with only the Command Line Tools installed:
//   swift run afm-selftest            (unit checks plus a live model check when available)
//   swift run afm-selftest --offline  (skip the live model check)
import Foundation
import FoundationModels
import AFMKit
import AFMServer
import AFMGitHub

var passed = 0
var failed: [String] = []
var current = ""

func check(_ ok: @autoclosure () throws -> Bool, _ what: String, line: Int = #line) {
    do {
        if try ok() { passed += 1 } else { failed.append("\(current): \(what) (line \(line))") }
    } catch {
        failed.append("\(current): \(what) threw \(error) (line \(line))")
    }
}

func checkThrows(_ what: String, line: Int = #line, _ op: () throws -> Void) {
    do { try op(); failed.append("\(current): \(what) should have thrown (line \(line))") } catch { passed += 1 }
}

@MainActor func suite(_ name: String, _ body: () async throws -> Void) async {
    current = name
    let before = failed.count
    do { try await body() } catch { failed.append("\(name): threw \(error)") }
    print((failed.count == before ? "✓ " : "✗ ") + name)
}

let home = FileManager.default.temporaryDirectory.appendingPathComponent("afm-selftest-\(getpid())")
setenv("AFM_HOME", home.path, 1)

IntegrationRegistry.install([GitHubIntegration()])

await suite("Calculator") {
    check(try Calculator.evaluate("2 + 3 * 4") == 14, "precedence")
    check(try Calculator.evaluate("(2 + 3) * 4") == 20, "parentheses")
    check(try Calculator.evaluate("2 ^ 10") == 1024, "power")
    check(try Calculator.evaluate("-3 + sqrt(16)") == 1, "unary and functions")
    check(try Calculator.evaluate("1,250 * 2") == 2500, "thousands separators")
    check(try Calculator.evaluate("17.5% of 2340") == 409.5, "percent of")
    check(try Calculator.evaluate("200 * 15%") == 30, "trailing percent")
    check(try Calculator.evaluate("10 % 3") == 1, "modulo")
    check(abs(try Calculator.evaluate("$86.40 times 0.18") - 15.552) < 1e-9, "words and currency")
    checkThrows("division by zero") { _ = try Calculator.evaluate("1 / 0") }
    checkThrows("dangling operator") { _ = try Calculator.evaluate("2 +") }
    checkThrows("unknown function") { _ = try Calculator.evaluate("foo(2)") }
}

await suite("JSON Schema") {
    let s = try JSONSchemaConverter.jsonSchema(fromFields: "name:string, age:int, tags:[string], mood:enum(happy|sad), note:string?")
    let props = s["properties"] as! [String: Any]
    check(props.count == 5, "five fields")
    check((s["required"] as! [String]) == ["name", "age", "tags", "mood"], "optional marker")
    check(((props["mood"] as! [String: Any])["enum"] as! [String]) == ["happy", "sad"], "enum values")
    checkThrows("unknown type") { _ = try JSONSchemaConverter.jsonSchema(fromFields: "x:color") }

    let nested = ##"{"type":"object","title":"Order","properties":{"id":{"type":"integer","minimum":1},"items":{"type":"array","maxItems":3,"items":{"type":"object","properties":{"sku":{"type":"string"},"qty":{"type":"integer"}},"required":["sku","qty"]}},"status":{"type":"string","enum":["open","shipped"]},"ref":{"$ref":"#/$defs/Ref"}},"required":["id","items","status"],"$defs":{"Ref":{"type":"object","properties":{"code":{"type":"string"}}}}}"##
    let schema = try JSONSchemaConverter.schema(fromJSON: nested)
    let encoded = String(decoding: try JSONEncoder().encode(schema), as: UTF8.self)
    check(encoded.contains("shipped") && encoded.contains("sku"), "nested schema converts")

    for r in Recipe.builtins where r.schema != nil {
        check((try? JSONSchemaConverter.schema(fromJSON: Recipe.render(r.schema!, r.defaults()))) != nil, "recipe \(r.id) schema compiles")
    }

    let ordered = try JSONSchemaConverter.schema(fromJSON: #"{"type":"object","properties":{"b":{"type":"string"},"a":{"type":"integer"}},"x-order":["b","a"]}"#)
    let content = GeneratedContent(kind: .structure(properties: ["a": GeneratedContent(kind: .number(1)), "b": GeneratedContent(kind: .string("x"))], orderedKeys: ["a", "b"]))
    let out = JSONRender.pretty(SchemaOrder(ordered)!.apply(content))
    check(out.range(of: "\"b\"")!.lowerBound < out.range(of: "\"a\"")!.lowerBound, "schema key order restored")
}

await suite("Text utilities") {
    let text = (1...60).map { "Paragraph \($0). " + String(repeating: "Words go here. ", count: 20) }.joined(separator: "\n\n")
    let chunks = Chunker.split(text, maxChars: 2000)
    check(chunks.count > 1, "splits long text")
    check(chunks.allSatisfy { $0.count <= 2000 }, "chunks respect the limit")
    check(chunks.joined().components(separatedBy: "Paragraph ").count - 1 == 60, "no paragraph lost")

    let merged = JSONMerge.merge([#"{"people":["Ann"],"summary":""}"#, #"{"people":["Ann","Bo"],"summary":"Hi"}"#])
    check(merged.contains("Bo") && merged.components(separatedBy: "Ann").count == 2 && merged.contains("Hi"), "JSON merge")

    check(Recipe.render("{{labels}} / {{labels_json}}", ["labels": "a, b ,c"]) == #"a, b ,c / ["a","b","c"]"#, "template rendering")
    check(WebText.strip("<html><head><title>x</title></head><body><script>bad()</script><p>Hello &amp; welcome</p></body></html>") == "Hello & welcome", "HTML stripping")
    checkThrows("reading /etc is refused") { _ = try FileAccess.resolve("/etc/hosts") }
    checkThrows("path traversal is refused") { _ = try FileAccess.resolve("~/../../etc/hosts") }
    checkThrows("SSH keys are refused") { _ = try FileAccess.resolve("~/.ssh/id_ed25519") }
    checkThrows("SSH folder listing is refused") { _ = try FileAccess.resolve("~/.ssh") }
    checkThrows("AWS credentials are refused") { _ = try FileAccess.resolve("~/.aws/credentials") }
    checkThrows(".env files are refused") { _ = try FileAccess.resolve("~/code/app/.env.local") }
    checkThrows("private keys are refused") { _ = try FileAccess.resolve("~/certs/server.pem") }
    checkThrows("Claude Desktop config is refused") { _ = try FileAccess.resolve("~/Library/Application Support/Claude/claude_desktop_config.json") }
    check((try? FileAccess.resolve("~/Documents/notes.txt")) != nil, "ordinary files still allowed")
    check((try? FileAccess.resolve("~/code/environment.md")) != nil, "names that merely contain env are allowed")

    check(ToolKind.riskWarning([.readFile, .fetchURL]) != nil, "file + fetch warns")
    check(ToolKind.riskWarning([.readFile, .calculator]) == nil, "file alone doesn't warn")
}

await suite("JSON fences") {
    check(JSONRender.unfenced("```json\n{\"a\": 1}\n```") == "{\"a\": 1}", "json fence removed")
    check(JSONRender.unfenced("Here you go:\n```\n[1, 2]\n```\nDone.") == "[1, 2]", "untagged fence with prose")
    check(JSONRender.unfenced("  {\"b\": true} ") == "{\"b\": true}", "no fence is trimmed only")
    check(JSONRender.unfenced("```json\n{\"c\": 3}") == "{\"c\": 3}", "unclosed fence")
}

await suite("Adapters") {
    checkThrows("missing adapter file") { _ = try AdapterInfo.load(path: "/nonexistent/x.fmadapter") }
}

await suite("Network guard") {
    check(NetGuard.isPrivate([127, 0, 0, 1]), "loopback")
    check(NetGuard.isPrivate([10, 1, 2, 3]) && NetGuard.isPrivate([172, 20, 0, 1]) && NetGuard.isPrivate([192, 168, 1, 1]), "RFC 1918")
    check(NetGuard.isPrivate([169, 254, 169, 254]), "cloud metadata / link-local")
    check(NetGuard.isPrivate([100, 64, 0, 1]), "carrier-grade NAT")
    check(!NetGuard.isPrivate([8, 8, 8, 8]) && !NetGuard.isPrivate([172, 32, 0, 1]), "public IPv4")
    check(NetGuard.isPrivate([UInt8](repeating: 0, count: 15) + [1]), "IPv6 loopback")
    check(NetGuard.isPrivate([0xfe, 0x80] + [UInt8](repeating: 0, count: 14)), "IPv6 link-local")
    check(NetGuard.isPrivate([0xfd, 0x12] + [UInt8](repeating: 0, count: 14)), "IPv6 unique local")
    check(NetGuard.isPrivate([UInt8](repeating: 0, count: 10) + [0xff, 0xff, 192, 168, 0, 1]), "IPv4-mapped private")
    check(!NetGuard.isPrivate([0x26, 0x06, 0x47, 0x00] + [UInt8](repeating: 0, count: 11) + [1]), "public IPv6")
    checkThrows("localhost is refused") { try NetGuard.check(URL(string: "http://localhost:8080/")!) }
    checkThrows("127.0.0.1 is refused") { try NetGuard.check(URL(string: "http://127.0.0.1/")!) }
    checkThrows("metadata IP is refused") { try NetGuard.check(URL(string: "http://169.254.169.254/latest/meta-data")!) }
    checkThrows("bare hostnames are refused") { try NetGuard.check(URL(string: "http://router/")!) }
    checkThrows("IPv6 loopback is refused") { try NetGuard.check(URL(string: "http://[::1]/")!) }
    checkThrows("file URLs are refused") { try NetGuard.check(URL(string: "file:///etc/passwd")!) }
}

await suite("Servers") {
    let r = HTTPRequest.parse(Data("POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}".utf8))
    check(r?.method == "POST" && r?.path == "/v1/chat/completions", "HTTP parse")
    check(HTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}".utf8)) == nil, "waits for full body")
    if case .invalid(400, _) = HTTPRequest.inspect(Data("POST / HTTP/1.1\r\nContent-Length: -5\r\n\r\nabc".utf8)) { passed += 1 } else { failed.append("Servers: negative Content-Length is rejected") }
    if case .invalid(400, _) = HTTPRequest.inspect(Data("POST / HTTP/1.1\r\nContent-Length: abc\r\n\r\n".utf8)) { passed += 1 } else { failed.append("Servers: non-numeric Content-Length is rejected") }
    if case .invalid(413, _) = HTTPRequest.inspect(Data("POST / HTTP/1.1\r\nContent-Length: 999999999999\r\n\r\n".utf8)) { passed += 1 } else { failed.append("Servers: huge Content-Length is rejected up front") }
    check(HTTPRequest.isLocalHost("127.0.0.1:11535") && HTTPRequest.isLocalHost("localhost") && HTTPRequest.isLocalHost("[::1]:11535"), "local Host headers")
    check(!HTTPRequest.isLocalHost("attacker.example") && !HTTPRequest.isLocalHost("127.0.0.1.attacker.example:11535"), "DNS-rebinding Host headers")
    check(HTTPRequest.isLocalOrigin(nil) && HTTPRequest.isLocalOrigin("http://localhost:3000"), "local or missing Origin")
    check(!HTTPRequest.isLocalOrigin("https://attacker.example") && !HTTPRequest.isLocalOrigin("null"), "foreign Origin")
    check(HTTPRequest.tokenMatches("Bearer s3cret", "s3cret") && !HTTPRequest.tokenMatches("Bearer s3cre", "s3cret") && !HTTPRequest.tokenMatches(nil, "s3cret"), "token check")

    final class Capture: @unchecked Sendable {
        var lines: [String] = []
        let lock = NSLock()
        func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    }
    let cap = Capture()
    let server = MCPServer(output: cap.add)
    await server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
    await server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    await server.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
    await server.handleLine(#"{"jsonrpc":"2.0","id":3,"method":"nope"}"#)
    await server.handleLine("not json")
    check(cap.lines.count == 4, "one reply per request, none for notifications")
    check(cap.lines[0].contains("2025-03-26"), "protocol version negotiated")
    let list = try JSONSerialization.jsonObject(with: Data(cap.lines[1].utf8)) as! [String: Any]
    let tools = (list["result"] as! [String: Any])["tools"] as! [[String: Any]]
    check(tools.count == 15, "15 MCP tools")
    check(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" }, "tool schemas are objects")
    check(cap.lines[2].contains("-32601"), "unknown method error")
    check(cap.lines[3].contains("-32700"), "parse error")

    SessionStore.shared.save(ChatSessionRecord(id: "studio-private", title: "Private", source: "studio"))
    let before = cap.lines.count
    await server.handleLine(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"afm_chat","arguments":{"session_id":"studio-private","message":"hi"}}}"#)
    check(cap.lines.count == before + 1 && cap.lines[before].contains("chat_not_shared"), "MCP can't continue a chat started in the app")
}

await suite("Claude wiring") {
    // Sandbox HOME so the real Claude Desktop config is never touched.
    let fakeHome = home.appendingPathComponent("home")
    let cfgDir = fakeHome.appendingPathComponent("Library/Application Support/Claude")
    try FileManager.default.createDirectory(at: cfgDir, withIntermediateDirectories: true)
    let cfg = cfgDir.appendingPathComponent("claude_desktop_config.json")
    try Data(#"{"mcpServers":{"other":{"command":"/bin/echo"}},"theme":"dark"}"#.utf8).write(to: cfg)
    let realHome = ProcessInfo.processInfo.environment["HOME"]
    setenv("HOME", fakeHome.path, 1)
    defer { if let realHome { setenv("HOME", realHome, 1) } }
    check(ClaudeHook.desktopConfig.path == cfg.path, "config path follows HOME")
    _ = try ClaudeHook.hookDesktop(cliPath: "/x/afm")
    check(ClaudeHook.desktopStatus() == (true, "/x/afm"), "desktop hook registers afm")
    let text = try String(contentsOf: cfg, encoding: .utf8)
    check(text.contains("\"other\"") && text.contains("\"theme\""), "other settings preserved")
    check(FileManager.default.fileExists(atPath: cfgDir.appendingPathComponent("claude_desktop_config.afm-backup.json").path), "backup written")
    check(try ClaudeHook.hookDesktop(cliPath: "/x/afm") == "Already registered.", "idempotent")
    _ = try ClaudeHook.unhookDesktop()
    check(ClaudeHook.desktopStatus().hooked == false, "unhook removes afm")
    checkThrows("rejects non-Anthropic keys") { try ClaudeKeychain.save("hunter2") }
    check(ClaudeKeychain.masked("sk-ant-api03-abcdefghijklmnop9f2c") == "sk-ant-api…9f2c", "key masking")
    check(ClaudeModel.find("claude-haiku-5-5").supportsFallbacks == false && ClaudeModel.find("nope").id == ClaudeModel.defaultID, "model table")
}

await suite("Integrations") {
    let gh = GitHubIntegration.integrationID
    check(IntegrationRegistry.isEnabled(gh) == false, "GitHub starts off")
    check(IntegrationRegistry.mcpTools.isEmpty, "no integration tools for Claude while off")
    check(IntegrationRegistry.chatEnabled.isEmpty, "no integration tools in chat while off")
    checkThrows("no GitHub client (and no token read) while off") { _ = try GitHubClient.make() }
    check(IntegrationRegistry.isIntegrationTool("afm_github_digest"), "tool belongs to an installed integration")

    final class Cap: @unchecked Sendable { var lines: [String] = []; let l = NSLock(); func add(_ s: String) { l.lock(); lines.append(s); l.unlock() } }
    let cap = Cap()
    let server = MCPServer(output: cap.add)
    await server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"afm_github_digest","arguments":{}}}"#)
    check(cap.lines.first?.contains("turned off") == true && cap.lines.first?.contains("\"isError\":true") == true, "MCP refuses a tool from an integration that's off")

    IntegrationRegistry.setPrefs(gh) { $0.enabled = true }
    check(IntegrationRegistry.mcpTools.filter { $0.name.hasPrefix("afm_github_") }.count == 8, "8 GitHub tools for Claude once on")
    check(IntegrationRegistry.chatEnabled.count == 1, "GitHub chat tools once on")
    await server.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
    let list = try JSONSerialization.jsonObject(with: Data(cap.lines.last!.utf8)) as! [String: Any]
    check(((list["result"] as! [String: Any])["tools"] as! [Any]).count == 23, "MCP lists 15 core + 8 GitHub tools")
    IntegrationRegistry.setPrefs(gh) { $0.claude = false }
    check(IntegrationRegistry.mcpTools.isEmpty && IntegrationRegistry.chatEnabled.count == 1, "Claude switch is separate from chat")
    IntegrationRegistry.setPrefs(gh) { $0 = IntegrationPrefs() }
    check(IntegrationRegistry.isEnabled(gh) == false, "turned back off")

    check(GHRef.parse("ry-ops/afm-studio#12") == GHRef(owner: "ry-ops", repo: "afm-studio", number: 12), "ref: owner/repo#n")
    check(GHRef.parse("https://github.com/a/b/pull/7")?.number == 7, "ref: PR URL")
    check(GHRef.parse("https://github.com/a/b/issues/3")?.description == "a/b#3", "ref: issue URL")
    check(GHRef.parse("git@github.com:a/b.git") == nil || GHRef.parse("github.com/a/b.git")?.slug == "a/b", "ref: .git suffix")
    check(GHRef.parse("nonsense") == nil, "ref: rejects junk")
    let groups = GitHubWorkflows.group(["feat(ui): add dark mode", "fix: crash on launch", "chore: bump deps", "Update README"])
    check(groups.map(\.0) == ["Features", "Fixes", "Maintenance", "Other"] && groups[0].1 == ["add dark mode"], "conventional commit grouping")
    let patches = GitHubWorkflows.filePatches("diff --git a/x.swift b/x.swift\n+one\ndiff --git a/y.md b/y.md\n+two")
    check(patches.map(\.0) == ["x.swift", "y.md"], "diff split per file")
    check(GitHubWorkflows.similarity("App crashes when opening settings", "Crash when opening the settings screen") > 0.25, "duplicate similarity")
    check(BlogWriter.slugify("Building AFM Studio: Apple's model!") == "building-afm-studio-apple-s-model", "blog slug")
}

if !CommandLine.arguments.contains("--offline") {
    if SystemLanguageModel.default.isAvailable {
        await suite("Live model") {
            let r = try await RecipeRunner.run(RecipeBook.shared.find("sentiment")!, input: "I absolutely love this, best purchase all year.")
            check(r.isJSON && r.text.contains("positive"), "structured sentiment")
            let calc = try await AFM.run(GenerationRequest(prompt: "Use the calculator: what is 23 * 47?", tools: [.calculator]))
            check(calc.text.contains("1081") || calc.text.contains("1,081"), "tool calling")
        }
    } else {
        print("– Live model (skipped: Apple Intelligence unavailable)")
    }
}

try? FileManager.default.removeItem(at: home)
print("\n\(passed) checks passed, \(failed.count) failed")
for f in failed { print("  ✗ " + f) }
exit(failed.isEmpty ? 0 : 1)

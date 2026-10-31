// Self-test for AFMKit and AFMServer. Runs with only the Command Line Tools installed:
//   swift run afm-selftest            (unit checks plus a live model check when available)
//   swift run afm-selftest --offline  (skip the live model check)
import Foundation
import FoundationModels
import AFMKit
import AFMServer
import AFMGitHub
import AFMJev

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

IntegrationRegistry.install([GitHubIntegration(), JevIntegration()])

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
    let capped = JSONMerge.merge([#"{"tags":["a","b","c"]}"#, #"{"tags":["d","e","f"]}"#],
                                 schema: #"{"type":"object","properties":{"tags":{"type":"array","maxItems":4,"items":{"type":"string"}}}}"#)
    check(capped.contains("\"d\"") && !capped.contains("\"e\""), "merged arrays keep the schema's maxItems")
    let nested = JSONMerge.merge([#"{"q":[{"t":["x","y"]}]}"#],
                                 schema: #"{"type":"object","properties":{"q":{"type":"array","items":{"type":"object","properties":{"t":{"type":"array","maxItems":1}}}}}}"#)
    check(nested.contains("x") && !nested.contains("y"), "maxItems applies inside array items")

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
    checkThrows("blocked folders ignore case") { _ = try FileAccess.resolve("~/.SSH/config") }
    checkThrows("gh CLI token file is refused") { _ = try FileAccess.resolve("~/.Config/gh/hosts.yml") }
    checkThrows("cargo credentials are refused") { _ = try FileAccess.resolve("~/.cargo/credentials.toml") }
    checkThrows("browser profiles are refused") { _ = try FileAccess.resolve("~/Library/Application Support/Google/Chrome/Default/Login Data") }
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

await suite("Redaction") {
    let text = "Dana Ortiz (dana.ortiz@riverton.gov, 608-555-0142) met Lee Park at 12 Elm Street. Ortiz paid with 4111 1111 1111 1111. SSN 123-45-6789. Call +44 20 7946 0958. Meeting on 2026-10-25, order 1234567."
    let r = Redactor.redact(text, people: ["Dana Ortiz", "Lee Park", "Nobody Here"], addresses: ["12 Elm Street"])
    check(r.text.hasPrefix("[Person 1] ([Email 1], [Phone 1]) met [Person 2] at [Address 1]."), "names, email, phone and address replaced")
    check(r.text.contains("[Person 1] paid"), "a last name alone gets the full name's placeholder")
    check(r.text.contains("[Card 1]") && r.text.contains("[ID 1]") && r.text.contains("[Phone 2]"), "card, SSN and international phone replaced")
    check(r.text.contains("2026-10-25") && r.text.contains("order 1234567"), "dates and short numbers kept")
    check(r.counts["Person"] == 2, "a name not in the text is ignored")
    check(!Redactor.redact("Card 4111 1111 1111 1112", people: [], addresses: []).text.contains("[Card"), "a number failing the card checksum is kept")
    check(Redactor.redact("Same: a@b.co and A@B.CO", people: [], addresses: []).text == "Same: [Email 1] and [Email 1]", "one value keeps one placeholder")
    check(Redactor.redact("Hi Sam", found: "not json").text == "Hi Sam", "bad model output hides nothing and changes nothing")
    let internalError = NSError(domain: "FoundationModels.LanguageModelError", code: -1)
    check(AFMError.isTransientModelError(internalError) && AFMError.from(internalError).code == "model_internal", "the model's unnamed internal error gets a message")
    check(!AFMError.isTransientModelError(NSError(domain: NSCocoaErrorDomain, code: -1)), "other errors aren't treated as transient")
    let recipe = Recipe.builtins.first { $0.id == "redact" }
    check(recipe?.isStructured == false && recipe?.schema != nil, "redact answers in text though it uses a schema")
}

await suite("Prose cleanup") {
    check(TextCleanup.tidy("\"\"\"\nThey're here.\n\"\"\"") == "They're here.", "recipe quote delimiters removed")
    check(TextCleanup.tidy("```markdown\n# Title\n- a\n```") == "# Title\n- a", "markdown fence around the answer removed")
    check(TextCleanup.tidy("```md\n## Summary\nx\n```") == "## Summary\nx", "md fence removed")
    check(TextCleanup.tidy("```\n^v?\\d+$\n```\nMatches a version.") == "```\n^v?\\d+$\n```\nMatches a version.", "code fence with prose kept")
    check(TextCleanup.tidy("```swift\nlet a = 1\n```") == "```swift\nlet a = 1\n```", "code fence kept")
    check(TextCleanup.tidy("```markdown\nA\n```\nand\n```markdown\nB\n```") .hasPrefix("```markdown\nA"), "two separate fences kept")
    check(TextCleanup.tidy("  Plain answer.  ") == "Plain answer.", "plain text is trimmed only")
    check(TextCleanup.tidy("Subject: Hello\n\nDear Ryan,\nHi.", input: "Hi Ryan, hi.") == "Dear Ryan,\nHi.", "invented subject line dropped")
    check(TextCleanup.tidy("Subject: Hello\n\nHi.", input: "Subject: Hello\nhi") == "Subject: Hello\n\nHi.", "subject line from the input kept")
    let list = "Summary:\n- one\n  - detail\n- two\n* three\n1. four\n2) five\n- six\n\nTrailing note."
    check(TextCleanup.bulletCount(list) == 6, "top-level bullets and numbered items counted, sub-bullets not")
    check(TextCleanup.firstBullets(list, 2) == "Summary:\n- one\n  - detail\n- two", "first bullets kept with their header and sub-lines")
    check(TextCleanup.firstBullets(list, 10) == list, "a list within the limit is unchanged")
    check(TextCleanup.bulletCount("2026 was a year.\n-1 is negative.") == 0, "a year or a minus sign is not a bullet")
    let summarize = Recipe.builtins.first { $0.id == "summarize" }
    check(summarize?.bulletLimit(["length": "short", "style": "bullet points"]) == 5, "short summaries hold 5 bullets")
    check(summarize?.bulletLimit(["length": "detailed", "style": "bullet points"]) == nil, "detailed summaries have no bullet limit")
    check(summarize?.bulletLimit(["length": "short", "style": "a paragraph"]) == nil, "a paragraph has no bullet limit")
    check(summarize?.sentenceLimit(["length": "short", "style": "a paragraph"]) == 3, "short paragraph summaries hold 3 sentences")
    check(summarize?.sentenceLimit(["length": "short", "style": "bullet points"]) == nil, "bullets have no sentence limit")
    check(TextCleanup.droppingUnfinishedLine("- One.\n- Two is cut o") == "- One.", "a line cut off at the token limit is dropped")
    check(TextCleanup.droppingUnfinishedLine("- One.\n- Two.") == "- One.\n- Two.", "finished lines are kept")
    check(TextCleanup.droppingUnfinishedLine("Only a cut-off lin") == "Only a cut-off lin", "a lone line is kept")
    let roadmap = "# Roadmap\n\n### Old bug\n\n**Status.** Fixed in 0.2.3.\n\nDone.\n\n### Help menu\n\n**Status.** Planned.\n\nTo do.\n\n## 1. Updates\n\n**Status.** The first part shipped. Still to do: rollback.\n"
    let open = GitHubWorkflows.openRoadmap(roadmap)
    check(!open.contains("Old bug") && open.contains("Help menu") && open.contains("rollback"), "the roadmap keeps open work and drops finished work")
    let prose = "AFM runs on device, e.g. on a Mac. It is free. It works offline! Does it need a key? No."
    check(TextCleanup.sentenceCount(prose) == 5, "sentences counted past an abbreviation")
    check(TextCleanup.firstSentences(prose, 2) == "AFM runs on device, e.g. on a Mac. It is free.", "first sentences kept whole")
    check(GitHubWorkflows.isProseHighlight("This release adds progress for long messages. It also fixes chat."), "prose highlights kept")
    check(!GitHubWorkflows.isProseHighlight("### Features\n\n- Show progress"), "highlights that copy the notes dropped")
    check(!GitHubWorkflows.isProseHighlight(""), "empty highlights dropped")
}

await suite("Benchmark math") {
    check(GenerationResult(text: "Tokyo", seconds: 0.38, firstTokenSeconds: 0.3799, outputTokens: 2).tokensPerSecond == nil, "two-token reply isn't timed")
    check(GenerationResult(text: "", seconds: 3.0, firstTokenSeconds: 0.5, outputTokens: 101).tokensPerSecond == 40, "speed counts tokens after the first")
    let runs = [BenchRun(round: 1, task: "a", firstToken: 0.4, total: 0.4, outputTokens: 2, tokensPerSecond: 0),
                BenchRun(round: 1, task: "b", firstToken: 0.5, total: 3.0, outputTokens: 101, tokensPerSecond: 40),
                BenchRun(round: 1, task: "c", firstToken: 0.5, total: 1.0, outputTokens: 31, tokensPerSecond: 60)]
    check(Bench.decodeSpeed(runs) == 130.0 / 3.0, "overall speed weights by tokens, skips untimed runs")
}

await suite("CLI link") {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    check(ClaudeHook.isInstalledApp(URL(fileURLWithPath: "/Applications/AFM Studio.app")), "/Applications copy relinks afm")
    check(ClaudeHook.isInstalledApp(URL(fileURLWithPath: home + "/Applications/AFM Studio.app")), "~/Applications copy relinks afm")
    check(!ClaudeHook.isInstalledApp(URL(fileURLWithPath: "/private/tmp/old/AFM Studio.app")), "a copy in a temp folder doesn't")
    check(!ClaudeHook.isInstalledApp(URL(fileURLWithPath: home + "/Projects/afm-studio/build/AFM Studio.app")), "a build folder copy doesn't")
    check(ClaudeHook.isInstalledApp(URL(fileURLWithPath: "/Applications/Tools/AFM Studio.app")), "a subfolder of Applications counts")
    check(!ClaudeHook.isInstalledApp(URL(fileURLWithPath: "/ApplicationsX/AFM Studio.app")), "a look-alike folder doesn't")
}

await suite("GitHub sign-in lookup") {
    let candidates = GitHubAuth.ghCandidates(path: "/usr/bin:/bin:/usr/bin", home: "/Users/x")
    check(candidates.first == "/usr/bin/gh", "the PATH is searched first")
    check(candidates.contains("/Users/x/.local/bin/gh"), "~/.local/bin is searched even when the PATH lacks it")
    check(candidates.contains("/opt/homebrew/bin/gh") && candidates.contains("/usr/local/bin/gh"), "Homebrew folders are searched")
    check(candidates.count == Set(candidates).count, "no folder is searched twice")
    check(GitHubAuth.ghCandidates(path: "bin:.:/usr/bin", home: "/Users/x").allSatisfy { $0.hasPrefix("/") }, "relative PATH entries are skipped")

    let dir = home.appendingPathComponent("fake-gh")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let good = dir.appendingPathComponent("gh").path
    try "#!/bin/sh\n[ \"$1 $2\" = \"auth token\" ] && echo gho_selftest\n".write(toFile: good, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: good)
    check(GitHubAuth.findGH(in: ["/nonexistent/gh", good]) == good, "finds gh outside the PATH")
    check(GitHubAuth.ghToken(at: good) == "gho_selftest", "reads the token from gh")
    let out = dir.appendingPathComponent("gh-out").path
    try "#!/bin/sh\necho 'not logged in' >&2; exit 1\n".write(toFile: out, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out)
    check(GitHubAuth.ghToken(at: out) == nil, "no token when gh isn't signed in")
}

await suite("Long messages") {
    let short = LongMessage.ends("Summarize this, please.")
    check(short.head == "Summarize this, please." && short.tail.isEmpty, "a short message is all head")
    let long = "give me the highlights: " + String(repeating: "word ", count: 400) + "and list the dates."
    let e = LongMessage.ends(long)
    check(e.head.hasPrefix("give me the highlights") && e.head.count == LongMessage.endChars, "head keeps the start, where the request usually is")
    check(e.tail.hasSuffix("and list the dates.") && e.tail.count == LongMessage.endChars, "tail keeps the end")
    let ask = LongMessage.requestPrompt(head: e.head, tail: e.tail)
    check(ask.contains("give me the highlights") && ask.contains("list the dates"), "request prompt sees both ends")
    let notes = LongMessage.notesPrompt(part: "PART", index: 1, count: 3, request: "REQ")
    check(notes.contains("part 2 of 3") && notes.contains("PART") && notes.contains("REQ"), "notes prompt carries the part and the request")
    check(!notes.contains("give me the highlights"), "notes prompt doesn't quote the raw ends")
    check(LongMessage.join(["a", " b\n"]) == "Part 1:\na\n\nPart 2:\nb", "notes are joined in order")
    let final = LongMessage.finalPrompt(request: "REQ", notes: "N")
    check(final.hasPrefix("My request: REQ") && final.contains("N") && final.contains("without calling tools"), "final prompt leads with the request")
    check(!final.contains("It ended"), "final prompt doesn't quote the end of the message")

    let t0 = Date(timeIntervalSince1970: 1000)
    var pr = LongReadProgress(tokens: 20893, parts: 9, done: 0, stage: .request, started: t0, updated: t0, remaining: 100)
    check(pr.fraction == 0 && pr.status == "Working out what you're asking", "request stage")
    pr.stage = .reading; pr.done = 3
    check(pr.fraction == 0.3 && pr.status == "Reading part 4 of 9", "reading counts parts, with the answer as one more step")
    pr.stage = .answering; pr.done = 9
    check(pr.fraction == 0.9 && pr.status == "Writing the answer", "answering")
    check(pr.remaining(at: t0.addingTimeInterval(30)) == 70 && pr.remaining(at: t0.addingTimeInterval(500)) == 0, "remaining counts down and stops at zero")
    check(LongMessage.remaining(parts: 9, done: 0, measuredPerPart: nil, includeRequest: true) == 9 * 13 + 30 + 3, "first estimate uses the default speed")
    check(LongMessage.remaining(parts: 9, done: 4, measuredPerPart: 10) == 5 * 10 + 30, "later estimates use the measured speed")
    check(LongMessage.roughly(30) == "under a minute" && LongMessage.roughly(70) == "about a minute" && LongMessage.roughly(170) == "about 3 minutes", "rough durations")
    check(LongMessage.clock(48) == "48 s" && LongMessage.clock(167) == "2 min 47 s", "exact durations")
    check(LongMessage.summary(tokens: 20893, parts: 9, seconds: 167) == "Read this 20,893-token message in 9 parts in 2 min 47 s.", "summary line")

    check(ChatEngine.answerCap(room: 2200, promptTokens: 2000) == 1040, "the answer gets the room the prompt leaves")
    check(ChatEngine.answerCap(room: 2200, promptTokens: 2900) == nil, "no cap when too little is left to answer")

    let old = #"{"id":"00000000-0000-0000-0000-000000000001","role":"user","text":"hi","date":0,"tools":[]}"#
    let m = try JSONDecoder().decode(ChatMessage.self, from: Data(old.utf8))
    check(m.contextText == nil && m.modelText == "hi", "chats saved before contextText still load")
    var n = m; n.contextText = "notes"
    check(n.modelText == "notes" && n.text == "hi", "the model sees the notes, the person sees what they wrote")
    let round = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(n))
    check(round.contextText == "notes", "contextText is saved")
}

await suite("Tool call limits") {
    let t = ToolCallTracker()
    t.record("github_read(a#1)"); t.record("github_read(a#2)"); t.record("datetime(local)")
    check(t.callsThisTurn("github_read(") == 2, "counts calls by prefix")
    t.beginTurn()
    check(t.callsThisTurn("github_read(") == 0, "a new answer starts the count again")
    t.record("github_read(a#3)")
    check(t.callsThisTurn("github_read(") == 1 && t.calls.count == 4, "keeps the full call list")
}

await suite("GitHub open PRs") {
    check(GitHubOpenPRs.query(login: "me1", orgs: ["a", "b"], scope: .all) == "is:open is:pr archived:false user:me1 org:a org:b", "all: user plus every org")
    check(GitHubOpenPRs.query(login: "me1", orgs: ["a"], scope: .mine) == "is:open is:pr archived:false user:me1", "mine: user only")
    check(GitHubOpenPRs.query(login: "me1", orgs: ["a"], scope: .orgs) == "is:open is:pr archived:false org:a", "orgs: orgs only")
    check(GitHubOpenPRs.query(login: "me1", orgs: [], scope: .orgs) == nil, "orgs with no orgs builds no query")
    check(GitHubOpenPRs.Scope(loose: "my orgs") == .orgs && GitHubOpenPRs.Scope(loose: "") == .all
          && GitHubOpenPRs.Scope(loose: "mine") == .mine && GitHubOpenPRs.Scope(loose: "everything") == .all, "loose scopes")

    check(GitHubClient.normalizeQuery("is:pr  author:me -assignee:ME review-requested:me") == "is:pr author:@me -assignee:@me review-requested:@me", "me becomes @me")
    check(GitHubClient.normalizeQuery("author:meg org:me label:me") == "author:meg org:me label:me", "other tokens are left alone")
    checkThrows("an empty query is refused") { _ = try GitHubClient.checkedQuery("   ") }

    let e422 = #"{"message":"Validation Failed","errors":[{"message":"The listed users and repositories cannot be searched."}]}"#
    check(GitHubClient.errorMessage(Data(e422.utf8), status: 422) == "Validation Failed: The listed users and repositories cannot be searched.", "422 details are kept")
    let eField = #"{"message":"Validation Failed","errors":[{"resource":"Search","field":"q","code":"missing"}]}"#
    check(GitHubClient.errorMessage(Data(eField.utf8), status: 422) == "Validation Failed: q is missing", "field errors are described")
    check(GitHubClient.errorMessage(Data("<html>".utf8), status: 502) == "HTTP 502", "non-JSON bodies fall back to the status")

    func pr(_ n: Int, _ repo: String, _ who: String) -> String {
        #"{"id":\#(n),"number":\#(n),"title":"PR \#(n)","state":"open","user":{"login":"\#(who)"},"labels":[],"comments":0,"html_url":"x","created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-2\#(n % 10)T00:00:00Z","pull_request":{"url":"x"},"repository_url":"https://api.github.com/repos/\#(repo)"}"#
    }
    let json = "[" + [pr(1, "a/x", "dependabot[bot]"), pr(2, "a/x", "me1"), pr(3, "me1/y", "dependabot[bot]"), pr(4, "b/z", "other")].joined(separator: ",") + "]"
    let items = try GitHubClient.decoder.decode([GHIssue].self, from: Data(json.utf8))
    let text = GitHubOpenPRs.summary(total: 9, items: items, login: "me1", orgs: ["a", "b"], scope: .all, listLimit: 2)
    check(text.hasPrefix("9 open pull requests in me1's repos and 2 organizations (a, b)."), "summary leads with the total")
    check(text.contains("cover the 4 most recently updated"), "says when counts are partial")
    check(!text.contains("In organization repos"), "no split when counts are partial")
    let full = GitHubOpenPRs.summary(total: 4, items: items, login: "me1", orgs: ["a", "b"], scope: .all)
    check(full.contains("In me1's own repos: 1. In organization repos: 3."), "splits own and org repos when counts are complete")
    check(text.contains("2 are from bots") && text.contains("1 were opened by me1"), "bots and the user's own PRs are counted")
    check(text.contains("By owner: a 2, b 1, me1 1."), "counts per owner, largest first")
    check(text.contains("- a/x: 2"), "counts per repo")
    check(text.components(separatedBy: "\n- ").count - 1 == 3 + 2, "lists 3 repos and 2 PRs")
    check(GitHubOpenPRs.summary(total: 0, items: [], login: "me1", orgs: [], scope: .mine) == "No open pull requests in me1's repos.", "empty result")
}

await suite("Updates") {
    check(SemVer("v0.2.0")! > SemVer("0.1.0")!, "newer minor wins")
    check(SemVer("0.10.0")! > SemVer("0.9.9")!, "numbers compare as numbers")
    check(SemVer("1.0.0-beta.2")! < SemVer("1.0.0")!, "pre-release sorts before release")
    check(SemVer("1.0.0-beta.10")! > SemVer("1.0.0-beta.2")!, "pre-release numbers compare as numbers")
    check(SemVer("1.0") == SemVer("1.0.0"), "missing parts count as zero")
    check(SemVer("latest") == nil && SemVer("1.x") == nil, "junk tags don't parse")
    let json = """
    {"tag_name":"v0.2.0","name":"AFM Studio 0.2.0","body":"Notes","html_url":"https://github.com/ry-ops/afm-studio/releases/tag/v0.2.0",
     "published_at":"2026-11-01T12:00:00Z","assets":[
       {"name":"AFM-Studio-0.2.0.zip","browser_download_url":"https://github.com/ry-ops/afm-studio/releases/download/v0.2.0/AFM-Studio-0.2.0.zip","size":5},
       {"name":"evil.zip","browser_download_url":"https://evil.example/evil.zip","size":1}]}
    """
    let r = try Updates.parse(Data(json.utf8))
    check(r.version?.description == "0.2.0" && r.publishedAt != nil, "parses the release")
    check(r.assets.map(\.name) == ["AFM-Studio-0.2.0.zip"] && r.appZip != nil, "keeps only downloads from this repo")
    let foreign = try Updates.parse(Data(#"{"tag_name":"v9.0.0","html_url":"https://evil.example/x"}"#.utf8))
    check(foreign.url == "https://github.com/ry-ops/afm-studio/releases/tag/v9.0.0", "replaces a release link that points elsewhere")
    check(Updates.status(for: r, current: SemVer("0.1.0")!) == .available(r), "newer release is offered")
    check(Updates.status(for: r, current: SemVer("0.2.0")!) == .upToDate(latest: "0.2.0"), "same version is up to date")
    check(Updates.status(for: nil) == .noReleases, "no releases yet")
    check(Updates.howToUpdate(r, source: "/tmp/it's here").contains("'/tmp/it'\\''s here'"), "source path is shell-quoted")
    check(AFMSettings().checkForUpdates == false, "update checks start off")
}

await suite("Model config") {
    // Settings written before adapters were removed still carry an adapterPath key.
    let legacy = #"{"guardrails":"permissive","useCase":"tagging","adapterPath":"/old/x.fmadapter"}"#
    let cfg = try? JSONDecoder().decode(ModelConfig.self, from: Data(legacy.utf8))
    check(cfg == ModelConfig(guardrails: .permissive, useCase: .tagging), "legacy settings with an adapter path still decode")
}

await suite("Error mapping") {
    // macOS 27 throws LanguageModelError. These codes drive chat compaction and the fix hints users see.
    let overflow = LanguageModelError.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: "too long"))
    check(AFMError.from(overflow).code == "context_exceeded", "context overflow")
    check(AFMError.from(overflow).message.contains("5000"), "context overflow names the token count")
    check(AFMError.from(LanguageModelError.guardrailViolation(.init(debugDescription: "unsafe"))).code == "guardrail", "guardrail violation")
    check(AFMError.from(LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "slow down"))).code == "rate_limited", "rate limited")
    check(AFMError.from(SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "downloading"))).code == "assets_unavailable", "assets unavailable")
    check(AFMError.from(LanguageModelSession.Error.concurrentRequests).code == "concurrent", "concurrent requests")
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
    check(NetGuard.bytes(ofAddress: "127.0.0.1") == [127, 0, 0, 1], "parses the connected IPv4 address")
    check(NetGuard.bytes(ofAddress: "fe80::1%en0").map(NetGuard.isPrivate) == true, "parses a scoped IPv6 address")
    check(NetGuard.bytes(ofAddress: "93.184.215.14").map(NetGuard.isPrivate) == false, "public connected address passes")
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
    let atStatus = cap.lines.count
    await server.handleLine(#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"afm_status","arguments":{}}}"#)
    check(cap.lines.count == atStatus + 1 && cap.lines[atStatus].contains("server_started"), "afm_status says when the server started")
    check(AFMVersion.commit.isEmpty || cap.lines[atStatus].contains(AFMVersion.commit), "afm_status names the server's build when it has one")
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
    check(ChatSessionRecord.defaultIntegrations == nil, "new chats get no integrations while off")
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
    check(ChatSessionRecord.defaultIntegrations == [gh], "new chats start with GitHub once its chat tools are on")
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
    check(GHRef.parse("../user") == nil && GHRef.parse("a/..") == nil && GHRef.parse("a/b?x=1") == nil, "ref: rejects path tricks")
    checkThrows("git: option-like ref is refused") { try LocalRepo.checkRef("--output=/tmp/x") }
    checkThrows("git: option-like range end is refused") { try LocalRepo.checkRef("v1.0..--output=/tmp/x") }
    checkThrows("git: option-like three-dot range is refused") { try LocalRepo.checkRef("main...-p") }
    check((try? LocalRepo.checkRef("origin/main...HEAD")) != nil && (try? LocalRepo.checkRef("v1.2.0..HEAD")) != nil, "git: normal ranges pass")
    let groups = GitHubWorkflows.group(["feat(ui): add dark mode", "fix: crash on launch", "chore: bump deps", "Update README"])
    check(groups.map(\.0) == ["Features", "Fixes", "Maintenance", "Other"] && groups[0].1 == ["add dark mode"], "conventional commit grouping")
    let patches = GitHubWorkflows.filePatches("diff --git a/x.swift b/x.swift\n+one\ndiff --git a/y.md b/y.md\n+two")
    check(patches.map(\.0) == ["x.swift", "y.md"], "diff split per file")
    check(GitHubWorkflows.similarity("App crashes when opening settings", "Crash when opening the settings screen") > 0.25, "duplicate similarity")
    check(BlogWriter.slugify("Building AFM Studio: Apple's model!") == "building-afm-studio-apple-s-model", "blog slug")
}

await suite("Jev") {
    let jev = JevIntegration.integrationID
    check(IntegrationRegistry.isEnabled(jev) == false, "Jev starts off")
    checkThrows("no Jev client (and no key read) while off") { _ = try JevClient.make() }
    checkThrows("rejects keys that aren't TypeSafe's") { try JevAuth.save("sk-ant-api03-nope") }
    checkThrows("rejects keys with spaces") { try JevAuth.save("apikey_abc def ghi jkl mno pqr") }

    // Request body, in TypeSafe's format.
    let body = try JevClient.body(model: "jev-1.13.0", state: "Checkout is down for everyone.", questions: [
        ("urgent", JevQuestion.noul(instructions: "Is this urgent?").json),
        ("team", JevQuestion.choice(instructions: "Which team?", options: [JevOption.parse("billing=Payments and refunds"), JevOption.parse("technical")]).json),
        ("severity", JevQuestion.score(instructions: "How severe?", levels: ["Cosmetic", "Degraded", "Blocking"]).json),
    ])
    let sent = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    let qs = sent["questions"] as! [String: Any]
    check(sent["model"] as? String == "jev-1.13.0" && sent["state"] as? String == "Checkout is down for everyone.", "model and state")
    check((qs["urgent"] as! [String: Any])["type"] as? String == "noul", "noul question")
    let crit = (qs["team"] as! [String: Any])["criteria"] as! [String: Any]
    check(crit["billing"] as? String == "Payments and refunds" && crit["technical"] is NSNull, "choice criteria: described and bare options")
    check((qs["severity"] as! [String: Any])["criteria"] as? [String] == ["Cosmetic", "Degraded", "Blocking"], "score levels in order")
    checkThrows("empty state is refused before sending") { _ = try JevClient.body(model: "m", state: "  ", questions: [("a", JevQuestion.noul(instructions: "x").json)]) }
    checkThrows("no questions is refused") { _ = try JevClient.body(model: "m", state: "x", questions: []) }
    checkThrows("unknown question type is refused") { _ = try JevClient.body(model: "m", state: "x", questions: [("a", ["type": "essay"])]) }
    checkThrows("oversized state is refused before it is billed") {
        _ = try JevClient.body(model: "m", state: String(repeating: "a", count: JevClient.maxStateCharacters + 1), questions: [("a", JevQuestion.noul(instructions: "x").json)])
    }

    // Response parsing, using the shapes from TypeSafe's docs.
    let reply = #"""
    {"model":"jev-1.13.0","answers":{
      "severity":{"type":"score","score":1.43,"confidence":0.35,"legend":{"0":"Cosmetic","1":"Degraded","2":"Blocking"},"probabilities":{"0":0.0,"1":0.57,"2":0.43}},
      "urgent":{"type":"noul","noul":0.92},
      "team":{"type":"choice","choice":"technical","confidence":0.81,"probabilities":{"billing":0.09,"technical":0.91}}},
     "usage":{"input_tokens":120,"output_tokens":0}}
    """#
    let r = try JevClient.parse(Data(reply.utf8), order: ["urgent", "team", "severity"], seconds: 0.08)
    check(r.answers.map(\.name) == ["urgent", "team", "severity"], "answers keep the question order")
    check(r.answers[0].answer.noul == 0.92 && r.answers[0].answer.summary.hasPrefix("true"), "noul answer")
    check(r.answers[1].answer.choice == "technical" && r.answers[1].answer.probabilities["billing"] == 0.09, "choice answer")
    check(r.answers[2].answer.summary.contains("of 0–2") && r.answers[2].answer.summary.contains("Degraded"), "score answer reads its legend")
    check(r.model == "jev-1.13.0" && r.inputTokens == 120, "model and usage")
    check((r.json["estimated_cost_usd"] as! NSDecimalNumber) == NSDecimalNumber(string: "0.00000504"), "cost estimate")
    check(JSONSchemaConverter.jsonText(r.json).contains("\"noul\" : 0.92"), "JSON shows clean numbers")
    checkThrows("garbage response") { _ = try JevClient.parse(Data("<html>".utf8), order: [], seconds: 0) }

    // Errors.
    check(JevClient.error(status: 401, data: Data()).code == "jev_auth", "401 is a key problem")
    check(JevClient.error(status: 400, data: Data(#"{"detail":"max_tokens_exceeded"}"#.utf8)).code == "jev_too_long", "400 too long")
    check(JevClient.error(status: 422, data: Data(#"{"detail":[{"loc":["body","questions","a","criteria"],"msg":"Field required","type":"missing"}]}"#.utf8)).message
          == "TypeSafe: body.questions.a.criteria: Field required", "422 names the field")

    // MCP and CLI helpers.
    let parsed = try JevIntegration.questions(from: ["b": ["type": "noul"], "a": ["type": "noul"]])
    check(parsed.map(\.0) == ["a", "b"], "MCP questions in a stable order")
    checkThrows("MCP questions must be an object") { _ = try JevIntegration.questions(from: "spam?") }
    check(JevIntegration.simpleQuestion("Spam?", options: nil) == .noul(instructions: "Spam?"), "one question, no options: noul")
    check(JevIntegration.simpleQuestion("Kind?", options: "bug, question=Asks how") == .choice(instructions: "Kind?", options: [JevOption(name: "bug"), JevOption(name: "question", description: "Asks how")]), "options make a choice")

    // Spending tally, kept under AFM_HOME.
    JevUsage.reset()
    JevUsage.record(inputTokens: 1_000_000, model: "jev-1.13.0", source: "cli")
    JevUsage.record(inputTokens: 500_000, model: "jev-1.13.0", source: "mcp")
    let u = JevUsage.load()
    check(u.calls == 2 && u.inputTokens == 1_500_000 && abs(u.estimatedCost - 0.063) < 1e-9 && u.bySource == ["cli": 1, "mcp": 1], "usage tally")

    IntegrationRegistry.setPrefs(jev) { $0.enabled = true }
    check(IntegrationRegistry.mcpTools.map(\.name) == ["afm_jev_decide"], "one Jev tool for Claude once on")
    check(IntegrationRegistry.chatEnabled.map(\.id) == [jev], "Jev chat tool once on")
    IntegrationRegistry.setPrefs(jev) { $0 = IntegrationPrefs() }
}

await suite("Recipe sources") {
    let now = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!
    check(RecipeSource.render("updated:<{{date-{{days}}}}", ["days": "14"], now: now) == "updated:<2026-10-17", "date token after a parameter")
    check(RecipeSource.render("x {{date-0}} {{nope}}", [:], now: now) == "x 2026-10-31 {{nope}}", "today, and unknown tokens are kept")
    check(RecipeSource(kind: "github.search").integrationID == "github", "kind names its integration")

    let fixed: @Sendable () async throws -> (String, [String]) = { ("me1", ["a", "b"]) }
    let q1 = try await GitHubSources.query("is:open {{owners}}", values: ["scope": "all"], login: fixed)
    check(q1 == "is:open user:me1 org:a org:b", "owners for all")
    let q2 = try await GitHubSources.query("is:open {{owners}}", values: ["scope": "orgs"], login: fixed)
    check(q2 == "is:open org:a org:b", "owners for orgs")
    let q3 = try await GitHubSources.query("is:open {{owners}}", values: ["repo": "x/y, https://github.com/p/q"], login: fixed)
    check(q3 == "is:open repo:x/y repo:p/q", "repo param wins, URLs parse")
    let q4 = try await GitHubSources.query("label:{{labels}}  {{owners}}", values: ["labels": "sev1,outage", "scope": "mine"], login: fixed)
    check(q4 == "label:sev1,outage user:me1", "labels and spaces")
    do { _ = try await GitHubSources.query("{{owners}}", values: ["scope": "orgs"], login: { ("me1", []) }); check(false, "orgs with no orgs should throw") } catch { passed += 1 }

    let one = #"[{"id":7,"number":7,"title":"Fix login","state":"open","user":{"login":"sam"},"labels":[{"name":"bug"}],"comments":2,"html_url":"https://github.com/a/x/pull/7","created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-30T00:00:00Z","pull_request":{"url":"x"},"repository_url":"https://api.github.com/repos/a/x","draft":true}]"#
    let issue = try GitHubClient.decoder.decode([GHIssue].self, from: Data(one.utf8))[0]
    let line = GitHubSources.line(issue, now: now)
    check(line == "- a/x#7 [PR, draft] \"Fix login\" by @sam. Opened 2026-10-01 (30 days ago), updated 2026-10-30 (1 day ago). 2 comments. Labels: bug.", "item line: \(line)")

    let log = (1...60).map { "2026-10-30T10:00:\(String(format: "%02d", $0 % 60)).1234567Z line \($0)" }.joined(separator: "\n")
        + "\n2026-10-30T10:01:00.0000000Z ##[error]Process completed with exit code 1.\n2026-10-30T10:01:01.0000000Z Cleaning up"
    let ex = GitHubSources.logExcerpt(log)
    check(ex.hasPrefix("line 41") && ex.contains("##[error]Process completed") && ex.hasSuffix("Cleaning up"), "excerpt starts 20 lines before the error, without timestamps")
    check(GitHubSources.logExcerpt("##[group]Run x\n\u{1B}[36;1mnpm test\u{1B}[0m\n##[endgroup]") == "npm test", "runner markers and color codes removed")
    let h = GitHubSources.headline(total: 9, found: [issue], now: now)
    check(h == "**9 pull requests** in a/x.", "headline: \(h)")
    check(GitHubSources.logExcerpt("| a    |     b |\n+--------------+\nok") == "| a | b |\nok", "padding squeezed, border-only lines dropped")
    check(GitHubSources.logExcerpt((1...100).map { "l\($0)" }.joined(separator: "\n")).hasPrefix("l61"), "no error: the last 40 lines")

    // A user recipe with a source round-trips through JSON and doesn't need text.
    let json = #"{"id":"mine","title":"Mine","summary":"","symbol":"x","category":"GitHub","instructions":"i","template":"{{input}}","params":[],"source":{"kind":"github.search","query":"is:open author:@me","limit":5}}"#
    let r = try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
    check(r.source?.query == "is:open author:@me" && r.source?.limit == 5 && r.hasSource && !r.needsInput, "source decodes")
    check(RecipeBook.shared.find("summarize")?.needsInput == true, "plain recipes still need text")

    // GitHub's recipes appear only while the integration is on, and the source refuses while it's off.
    let gh = GitHubIntegration.integrationID
    check(RecipeBook.shared.find("gh-open-prs") == nil, "hidden while GitHub is off")
    do { _ = try await RecipeSources.fetch(GitHubRecipes.all[0]); check(false, "fetch should refuse while off") }
    catch { check(AFMError.from(error).code == "integration_off", "refuses while off") }
    IntegrationRegistry.setPrefs(gh) { $0.enabled = true }
    let ids = RecipeBook.shared.all().filter(\.hasSource).map(\.id)
    check(ids == ["gh-open-prs", "gh-review-queue", "gh-stale-prs", "gh-incidents", "gh-postmortem", "gh-ci-failures"], "six GitHub recipes once on")
    check(RecipeBook.shared.find("gh-open-prs")?.isBuiltin == true, "marked built-in")
    IntegrationRegistry.setPrefs(gh) { $0 = IntegrationPrefs() }
    for rec in GitHubRecipes.all {
        check(rec.template.contains("{{input}}") && rec.source != nil, "\(rec.id) reads its source")
        if let q = rec.source?.query {
            let filled = RecipeSource.render(q, rec.defaults(), now: now)
            check(!filled.replacingOccurrences(of: "{{owners}}", with: "").contains("{{"), "\(rec.id) query fills: \(filled)")
        }
    }
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

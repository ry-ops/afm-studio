import Foundation
import AFMKit

struct ToolOutput {
    var text: String
    var structured: [String: Any]?
    var meta: [String: Any] = [:]
}

enum MCPTools {
    static let textProps: [String: Any] = [
        "text": ["type": "string", "description": "The text to process. Give this or `path`."],
        "path": ["type": "string", "description": "Path to a text file in the user's home folder (e.g. ~/notes/meeting.txt). It is read locally, so the content never enters your context. Key, credential and .env files are refused."],
    ]

    static func def(_ name: String, _ title: String, _ desc: String, _ props: [String: Any] = [:], required: [String] = [],
                    withText: Bool = false, openWorld: Bool = false, readOnly: Bool = true) -> [String: Any] {
        var p = props
        if withText { for (k, v) in textProps { p[k] = v } }
        return [
            "name": name,
            "title": title,
            "description": desc,
            "inputSchema": ["type": "object", "properties": p, "required": required, "additionalProperties": false],
            "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": false, "idempotentHint": false, "openWorldHint": openWorld],
        ]
    }

    static func definitions(allowFiles: Bool) -> [[String: Any]] {
        let common: [String: Any] = [
            "temperature": ["type": "number", "minimum": 0, "maximum": 2, "description": "Sampling temperature. Lower is more deterministic."],
            "max_tokens": ["type": "integer", "minimum": 1, "maximum": 4000, "description": "Maximum tokens in the response."],
            "permissive": ["type": "boolean", "description": "Use Apple's permissive guardrails, which block fewer harmless requests when transforming supplied text."],
        ]
        func with(_ p: [String: Any]) -> [String: Any] { p.merging(common) { a, _ in a } }
        return [
            def("afm_status", "Model status", "Check whether Apple's on-device model is available, and get its context size and supported languages."),
            def("afm_generate", "Generate text", "Send a prompt to Apple's on-device model and get a text reply. Good for quick drafts, rewording and simple questions. Not reliable for facts or math.",
                with([
                    "prompt": ["type": "string", "description": "The prompt."],
                    "instructions": ["type": "string", "description": "Optional system instructions that set the model's role and rules."],
                    "tools": ["type": "array", "items": ["type": "string", "enum": ["datetime", "calculator", "system_info"]], "description": "Built-in tools the model may call."],
                ]), required: ["prompt"]),
            def("afm_structured", "Structured output", "Generate JSON that is guaranteed to match a JSON Schema (constrained decoding on device). Pass `schema` (JSON Schema object) or `fields` shorthand like \"name:string, age:int, tags:[string], mood:enum(happy|sad), note:string?\".",
                with([
                    "prompt": ["type": "string", "description": "What to generate or extract."],
                    "schema": ["type": "object", "description": "A JSON Schema object (object, array, string enum/pattern, integer/number ranges, boolean, anyOf, $defs/$ref)."],
                    "fields": ["type": "string", "description": "Shorthand field list instead of `schema`."],
                    "instructions": ["type": "string"],
                ]).merging(textProps) { a, _ in a }, required: ["prompt"]),
            def("afm_summarize", "Summarize", "Summarize text or a local file on device. Handles documents far larger than the 4K context by chunking.",
                ["style": ["type": "string", "enum": ["bullet points", "a paragraph", "an executive summary", "a one-line TL;DR"]],
                 "length": ["type": "string", "enum": ["short", "medium", "detailed"]]], withText: true),
            def("afm_extract", "Extract fields", "Extract specific fields from text or a local file into JSON. Give `fields` shorthand (\"vendor:string, total:number, items:[string]\") or a JSON Schema in `schema`.",
                ["fields": ["type": "string"], "schema": ["type": "object"], "guidance": ["type": "string", "description": "Optional extra instructions about what to extract."]], withText: true),
            def("afm_classify", "Classify", "Pick the best label for text from your own list. Returns label, confidence and reason as JSON.",
                ["labels": ["type": "array", "items": ["type": "string"], "minItems": 2]], required: ["labels"], withText: true),
            def("afm_rewrite", "Rewrite", "Rewrite text in another tone while keeping its meaning.",
                ["tone": ["type": "string", "description": "e.g. professional, friendly, concise, formal, casual, persuasive, plain English"]], withText: true),
            def("afm_translate", "Translate", "Translate text into one of the on-device model's supported languages.",
                ["language": ["type": "string", "description": "Target language, e.g. Spanish, Japanese, German"]], required: ["language"], withText: true),
            def("afm_proofread", "Proofread", "Fix spelling, grammar and punctuation. Returns the corrected text.", withText: true),
            def("afm_tag", "Tag", "Tag text with topics using Apple's content-tagging model. Returns JSON.",
                ["max_tags": ["type": "integer", "minimum": 1, "maximum": 20]], withText: true),
            def("afm_ask_document", "Ask a document", "Answer a question using only the given text or local file.",
                ["question": ["type": "string"]], required: ["question"], withText: true),
            def("afm_count_tokens", "Count tokens", "Count tokens with the on-device tokenizer and compare against the 4,096-token context.", withText: true),
            def("afm_chat", "Chat", "Multi-turn chat with the on-device model. Reuse `session_id` to continue a conversation; it's saved and appears in AFM Studio. The context compacts itself when full.",
                with([
                    "message": ["type": "string"],
                    "session_id": ["type": "string", "description": "Conversation id. Omit to start a new one; the id is returned."],
                    "instructions": ["type": "string", "description": "System instructions (applied when the session is created or reset)."],
                    "reset": ["type": "boolean", "description": "Clear the conversation first."],
                ]), required: ["message"]),
            def("afm_recipes", "List recipes", "List every recipe (built-in and user-made) with its parameters. Run one with afm_run_recipe."),
            def("afm_run_recipe", "Run recipe", "Run a named recipe (e.g. action-items, meeting-notes, sentiment, entities, quiz, commit-message, explain-code, explain-error, draft, key-points) on text or a local file. `redact` with `path` returns the file with names, addresses, emails, phone numbers and ID numbers replaced by placeholders, so you can read it without seeing them.",
                ["recipe": ["type": "string"], "params": ["type": "object", "description": "Recipe parameters as string values, e.g. {\"tone\": \"friendly\"}.", "additionalProperties": ["type": "string"]]],
                required: ["recipe"], withText: true),
        ]
    }

    static func preview(_ args: [String: Any]) -> String {
        let s = JSONValue.string(args)
        return s.count > 600 ? String(s.prefix(600)) + "…" : s
    }

    static func input(_ a: [String: Any]) throws -> String {
        if let t = a.str("text"), !t.isEmpty { return t }
        if let p = a.str("path"), !p.isEmpty { return try FileAccess.readText(p, limit: 4_000_000) }
        throw AFMError(code: "missing_input", message: "Give `text` or `path`.")
    }

    static func options(_ a: [String: Any]) -> GenOptions {
        GenOptions(temperature: a.double("temperature"), maxTokens: a.int("max_tokens"))
    }

    static func config(_ a: [String: Any]) -> ModelConfig {
        ModelConfig(guardrails: a.bool("permissive") == true ? .permissive : .standard)
    }

    static func meta(_ r: GenerationResult) -> [String: Any] {
        var m: [String: Any] = ["seconds": (r.seconds * 100).rounded() / 100]
        if let p = r.promptTokens { m["input_tokens"] = p }
        if let o = r.outputTokens { m["output_tokens"] = o }
        if r.chunks > 1 { m["chunks"] = r.chunks }
        if !r.toolCalls.isEmpty { m["tool_calls"] = r.toolCalls }
        return m
    }

    static func output(_ r: GenerationResult) -> ToolOutput {
        var o = ToolOutput(text: r.text, meta: meta(r))
        if r.isJSON, let obj = JSONValue.parse(r.text) as? [String: Any] { o.structured = obj }
        return o
    }

    static func recipe(_ id: String, _ text: String, _ params: [String: String], _ a: [String: Any]) async throws -> ToolOutput {
        guard let r = RecipeBook.shared.find(id) else {
            throw AFMError(code: "unknown_recipe", message: "No recipe named \"\(id)\".", suggestion: "Call afm_recipes to see the list.")
        }
        return output(try await RecipeRunner.run(r, input: text, params: params, options: options(a), config: config(a)))
    }

    static func schemaText(_ a: [String: Any]) throws -> String? {
        if let s = a["schema"] as? [String: Any] { return JSONValue.string(s) }
        if let s = a["schema"] as? String, !s.isEmpty { return s }
        if let f = a.str("fields"), !f.isEmpty { return JSONValue.string(try JSONSchemaConverter.jsonSchema(fromFields: f, title: "Extraction")) }
        return nil
    }

    static func call(_ name: String, _ a: [String: Any], server: MCPServer) async throws -> ToolOutput {
        switch name {
        case "afm_status":
            return ToolOutput(text: statusJSON(), structured: JSONValue.parse(statusJSON()) as? [String: Any])

        case "afm_generate":
            let tools = ((a["tools"] as? [String]) ?? []).compactMap(ToolKind.init(rawValue:)).filter { !$0.isSensitive }
            let r = try await AFM.run(GenerationRequest(prompt: a.str("prompt") ?? "", instructions: a.str("instructions"),
                                                        options: options(a), config: config(a), tools: tools))
            return output(r)

        case "afm_structured":
            guard let st = try schemaText(a) else { throw AFMError(code: "missing_schema", message: "Give `schema` or `fields`.") }
            var prompt = a.str("prompt") ?? ""
            if let t = try? input(a) { prompt += "\n\nText:\n\"\"\"\n\(t)\n\"\"\"" }
            let schema = try JSONSchemaConverter.schema(fromJSON: st)
            let r = try await AFM.run(GenerationRequest(prompt: prompt, instructions: a.str("instructions"), options: options(a), config: config(a), schema: schema))
            return output(r)

        case "afm_summarize":
            var p: [String: String] = [:]
            if let s = a.str("style") { p["style"] = s }
            if let l = a.str("length") { p["length"] = l }
            return try await recipe("summarize", try input(a), p, a)

        case "afm_extract":
            guard let st = try schemaText(a) else { throw AFMError(code: "missing_schema", message: "Give `fields` or `schema`.") }
            let guidance = a.str("guidance").map { " \($0)" } ?? ""
            let r = Recipe(id: "_extract", title: "Extract", summary: "",
                           instructions: "You extract information from text into the requested fields. Use only information in the text. Use an empty string or empty list when something isn't present.",
                           template: "Extract the requested fields from this text.\(guidance)\n\nText:\n\"\"\"\n{{input}}\n\"\"\"",
                           schema: st, temperature: 0.1, permissive: true, long: .merge)
            return output(try await RecipeRunner.run(r, input: try input(a), options: options(a), config: config(a)))

        case "afm_classify":
            let labels = (a["labels"] as? [String]) ?? []
            guard labels.count >= 2 else { throw AFMError(code: "labels", message: "Give at least two labels.") }
            return try await recipe("classify", try input(a), ["labels": labels.map { $0.replacingOccurrences(of: ",", with: " ") }.joined(separator: ", ")], a)

        case "afm_rewrite":
            return try await recipe("rewrite", try input(a), ["tone": a.str("tone") ?? "professional"], a)

        case "afm_translate":
            return try await recipe("translate", try input(a), ["language": a.str("language") ?? "Spanish"], a)

        case "afm_proofread":
            return try await recipe("proofread", try input(a), [:], a)

        case "afm_tag":
            return try await recipe("tags", try input(a), ["max_tags": String(a.int("max_tags") ?? 6)], a)

        case "afm_ask_document":
            return try await recipe("ask", try input(a), ["question": a.str("question") ?? ""], a)

        case "afm_count_tokens":
            let t = try input(a)
            let n = await AFM.tokenCount(t)
            let ctx = AFM.contextSize
            let obj: [String: Any] = ["tokens": n, "context_size": ctx, "fits": n < ctx - 500, "characters": t.count]
            return ToolOutput(text: "\(n) tokens (context window \(ctx)). \(n < ctx - 500 ? "Fits in one pass." : "Will be chunked by long-document tools.")", structured: obj)

        case "afm_chat":
            let sid = a.str("session_id").flatMap { $0.isEmpty ? nil : $0 } ?? "mcp-" + String(UUID().uuidString.prefix(8)).lowercased()
            let engine = try server.chat(sid)
            if a.bool("reset") == true { engine.reset() }
            let instr = a.str("instructions")
            let opts = options(a)
            let cfg = config(a)
            engine.update { r in
                if let instr, r.messages.isEmpty { r.instructions = instr }
                r.options = opts
                r.config.guardrails = cfg.guardrails
                if r.source.isEmpty { r.source = "mcp" }
            }
            let msg = try await engine.send(a.str("message") ?? "")
            return ToolOutput(text: msg.text, structured: ["session_id": sid, "reply": msg.text],
                              meta: ["session_id": sid, "seconds": ((msg.seconds ?? 0) * 100).rounded() / 100, "tool_calls": msg.tools])

        case "afm_recipes":
            return ToolOutput(text: recipesJSON())

        case "afm_run_recipe":
            let params = ((a["params"] as? [String: Any]) ?? [:]).reduce(into: [String: String]()) { $0[$1.key] = "\($1.value)" }
            return try await recipe(a.str("recipe") ?? "", try input(a), params, a)

        default:
            throw AFMError(code: "unknown_tool", message: "Unknown tool \(name).")
        }
    }

    static func statusJSON() -> String {
        let s = ModelStatus.current()
        var obj: [String: Any] = [
            "available": s.available, "context_size": s.contextSize, "languages": s.languages,
            "content_tagging_available": s.taggingAvailable, "macos": s.osVersion, "server_version": AFMVersion.string,
        ]
        if let r = s.reason { obj["reason"] = r }
        if let g = s.guidance { obj["guidance"] = g }
        return JSONRender.pretty(json: JSONValue.string(obj))
    }

    static func recipesJSON() -> String {
        let list: [[String: Any]] = RecipeBook.shared.all().map { r in
            [
                "id": r.id, "title": r.title, "summary": r.summary, "category": r.category,
                "structured": r.isStructured, "builtin": r.isBuiltin,
                "params": r.params.map { p -> [String: Any] in
                    var d: [String: Any] = ["key": p.key, "label": p.label, "default": p.defaultValue]
                    if let c = p.choices { d["choices"] = c }
                    return d
                },
            ]
        }
        return JSONRender.pretty(json: JSONValue.string(["recipes": list]))
    }
}

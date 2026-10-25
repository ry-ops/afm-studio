import Foundation
import AFMKit

/// A Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0).
/// Exposes Apple's on-device model to Claude Code, Claude Desktop and any MCP client.
public final class MCPServer: @unchecked Sendable {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    let gate = ModelGate()
    let writeLock = NSLock()
    let chatLock = NSLock()
    var chats: [String: ChatEngine] = [:]
    let settings = AFMSettings.load()
    let output: (String) -> Void

    public init(output: ((String) -> Void)? = nil) {
        self.output = output ?? { line in
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
    }

    static func log(_ s: String) { FileHandle.standardError.write(Data("[afm-mcp] \(s)\n".utf8)) }

    public func run() async {
        MCPServer.log("ready (afm-studio \(AFMVersion.string))")
        let lines = AsyncStream<String> { cont in
            Thread.detachNewThread {
                while let l = readLine(strippingNewline: true) { cont.yield(l) }
                cont.finish()
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for await line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                group.addTask { await self.handleLine(line) }
            }
        }
    }

    func send(_ obj: [String: Any]) {
        writeLock.lock(); defer { writeLock.unlock() }
        output(JSONValue.string(obj))
    }

    public func handleLine(_ line: String) async {
        guard let msg = JSONValue.parse(line) else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
            return
        }
        if let batch = msg as? [[String: Any]] {
            for m in batch { await handle(m) }
        } else if let m = msg as? [String: Any] {
            await handle(m)
        }
    }

    func handle(_ m: [String: Any]) async {
        let id = m["id"]
        guard let method = m["method"] as? String else { return }
        let params = (m["params"] as? [String: Any]) ?? [:]
        if id == nil { return } // notification (initialized, cancelled, …)
        do {
            let result = try await dispatch(method, params)
            send(["jsonrpc": "2.0", "id": id!, "result": result])
        } catch let e as RPCError {
            send(["jsonrpc": "2.0", "id": id!, "error": ["code": e.code, "message": e.message]])
        } catch {
            send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32603, "message": error.localizedDescription]])
        }
    }

    struct RPCError: Error { let code: Int; let message: String }

    func dispatch(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return [
                "protocolVersion": MCPServer.supportedVersions.contains(asked) ? asked : MCPServer.supportedVersions[0],
                "capabilities": ["tools": ["listChanged": false], "resources": ["listChanged": false]],
                "serverInfo": ["name": AFMVersion.name, "title": "AFM Studio", "version": AFMVersion.string],
                "instructions": MCPServer.instructions,
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": MCPTools.definitions(allowFiles: true) + IntegrationRegistry.mcpTools.map(\.mcpDefinition)]
        case "tools/call":
            guard let name = params["name"] as? String else { throw RPCError(code: -32602, message: "Missing tool name") }
            let args = (params["arguments"] as? [String: Any]) ?? [:]
            return await callTool(name, args)
        case "resources/list":
            return ["resources": [
                ["uri": "afm://status", "name": "status", "title": "Model status", "mimeType": "application/json",
                 "description": "Availability, context size and supported languages of Apple's on-device model."],
                ["uri": "afm://recipes", "name": "recipes", "title": "Recipes", "mimeType": "application/json",
                 "description": "Every built-in and user recipe with its parameters."],
            ]]
        case "resources/read":
            let uri = params["uri"] as? String ?? ""
            let text: String
            switch uri {
            case "afm://status": text = MCPTools.statusJSON()
            case "afm://recipes": text = MCPTools.recipesJSON()
            default: throw RPCError(code: -32002, message: "Resource not found: \(uri)")
            }
            return ["contents": [["uri": uri, "mimeType": "application/json", "text": text]]]
        case "resources/templates/list":
            return ["resourceTemplates": []]
        case "prompts/list":
            return ["prompts": []]
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    func callTool(_ name: String, _ args: [String: Any]) async -> [String: Any] {
        let start = Date()
        do {
            let out: ToolOutput
            if IntegrationRegistry.isIntegrationTool(name) {
                guard let integ = IntegrationRegistry.mcpTool(named: name) else {
                    throw AFMError(code: "integration_off", message: "That integration is turned off in AFM Studio.",
                                   suggestion: "Turn it on (and allow it for Claude) in AFM Studio > Integrations.")
                }
                let o = try await gate.serial { try await integ.run(args) }
                out = ToolOutput(text: o.text, structured: o.json)
            } else {
                out = try await gate.serial { try await MCPTools.call(name, args, server: self) }
            }
            History.append(HistoryEntry(source: "mcp", kind: name, title: name, input: MCPTools.preview(args), output: out.text,
                                        seconds: Date().timeIntervalSince(start), outputTokens: out.meta["output_tokens"] as? Int))
            var r: [String: Any] = ["content": [["type": "text", "text": out.text]], "isError": false]
            if let s = out.structured { r["structuredContent"] = s }
            if !out.meta.isEmpty { r["_meta"] = ["afm": out.meta] }
            return r
        } catch {
            let e = AFMError.from(error)
            History.append(HistoryEntry(source: "mcp", kind: name, title: name, input: MCPTools.preview(args), output: e.fullDescription,
                                        seconds: Date().timeIntervalSince(start), ok: false))
            return ["content": [["type": "text", "text": "Error (\(e.code)): \(e.fullDescription)"]], "isError": true]
        }
    }

    /// Opens an MCP chat. Claude may only continue chats that were started over MCP, so it can't
    /// read or rewrite chats from the app or Terminal, and MCP chats never get file or web tools.
    func chat(_ id: String) throws -> ChatEngine {
        chatLock.lock(); defer { chatLock.unlock() }
        if let c = chats[id] { return c }
        if let existing = SessionStore.shared.load(id), existing.source != "mcp" {
            throw AFMError(code: "chat_not_shared", message: "Chat \(id) was started outside Claude, so it can't be continued here.",
                           suggestion: "Omit session_id to start a new chat.")
        }
        let c = ChatEngine.open(id: id, source: "mcp")
        c.allowSensitiveTools = false
        chats[id] = c
        return c
    }

    static let instructions = """
    AFM Studio gives you Apple's on-device foundation model (about 3B parameters, 4,096-token context) running privately on this Mac. It is free, offline and fast.
    Use it to offload text work: summarizing, extracting fields into JSON, classifying, tagging, rewriting, proofreading and translating.
    Integration tools (for example afm_github_*) appear only when the user has turned that integration on. The afm_github_* tools read GitHub (read-only) and do the reading and drafting on device: summaries, triage, digests, PR descriptions, release notes, repo briefs, next-step issues and blog drafts. They never post, label or commit; drafts come with pre-filled links the user can open.
    Most tools accept `path` instead of `text`. With `path`, a file in the user's home folder is processed locally and never enters your context, which saves your tokens on large files. Long inputs are split into chunks and combined automatically.
    It is weak at world knowledge, math and writing code. Treat its output as a draft and verify facts.
    """
}

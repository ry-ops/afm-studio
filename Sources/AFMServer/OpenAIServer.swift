import Foundation
import Network
import FoundationModels
import AFMKit

public struct HTTPRequest {
    public var method: String
    public var path: String
    var headers: [String: String]
    var body: Data

    public enum Parse {
        case incomplete
        case invalid(status: Int, message: String)
        case complete(HTTPRequest)
    }

    public static let maxBody = 16_000_000

    /// Returns nil until the full request (headers + Content-Length body) has arrived, or when it's malformed.
    public static func parse(_ buf: Data) -> HTTPRequest? {
        if case .complete(let r) = inspect(buf) { return r }
        return nil
    }

    public static func inspect(_ buf: Data) -> Parse {
        guard let range = buf.range(of: Data("\r\n\r\n".utf8)) else {
            return buf.count > 64_000 ? .invalid(status: 431, message: "Request headers too large") : .incomplete
        }
        let head = String(decoding: buf[..<range.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid(status: 400, message: "Empty request") }
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return .invalid(status: 400, message: "Malformed request line") }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased().trimmingCharacters(in: .whitespaces)] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid(status: 400, message: "Chunked request bodies aren't supported; send Content-Length") }
        let rawLen = headers["content-length"] ?? "0"
        guard let len = Int(rawLen), len >= 0 else { return .invalid(status: 400, message: "Invalid Content-Length") }
        guard len <= maxBody else { return .invalid(status: 413, message: "Request too large") }
        let bodyStart = range.upperBound
        guard buf.count - bodyStart >= len else { return .incomplete }
        let path = String(parts[1]).components(separatedBy: "?")[0]
        return .complete(HTTPRequest(method: String(parts[0]).uppercased(), path: path, headers: headers, body: buf.subdata(in: bodyStart..<(bodyStart + len))))
    }

    /// Host values a browser sends only when it really talks to this machine. Anything else is
    /// a DNS-rebinding attempt: a website whose name was pointed at 127.0.0.1.
    public static func isLocalHost(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return true } // HTTP/1.0 clients may omit it; browsers never do
        var h = host.lowercased()
        if h.hasPrefix("[") { h = String(h.prefix { $0 != "]" }.dropFirst()) }
        else if let colon = h.lastIndex(of: ":") { h = String(h[..<colon]) }
        return h == "127.0.0.1" || h == "localhost" || h == "::1"
    }

    /// Requests from web pages carry Origin. Only pages served from this machine may call the server.
    public static func isLocalOrigin(_ origin: String?) -> Bool {
        guard let origin, origin != "null" else { return origin == nil }
        guard let host = URLComponents(string: origin)?.host else { return false }
        return isLocalHost(host)
    }

    /// Constant-time comparison so the token can't be guessed byte by byte from response timing.
    public static func tokenMatches(_ header: String?, _ token: String) -> Bool {
        let a = Array((header ?? "").utf8), b = Array("Bearer \(token)".utf8)
        var diff = UInt8(a.count == b.count ? 0 : 1)
        for i in 0..<b.count { diff |= b[i] ^ (i < a.count ? a[i] : 0) }
        return diff == 0
    }

    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
}

/// An OpenAI-compatible HTTP server bound to 127.0.0.1, so any OpenAI client library,
/// editor plugin or script can use Apple's on-device model.
public final class OpenAIServer: @unchecked Sendable {
    public let port: UInt16
    public let token: String?
    public private(set) var isRunning = false
    public var onLog: (@Sendable (String) -> Void)?
    public var onState: (@Sendable (Bool, String?) -> Void)?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "afm.http")
    private let gate = ModelGate()
    /// Touched only on `queue`.
    private var openConnections = 0
    public static let maxConnections = 32
    public static let models = ["apple-foundation-model", "apple-foundation-model-permissive", "apple-foundation-model-tagging"]

    public init(port: UInt16 = 11535, token: String? = nil) {
        self.port = port
        self.token = token?.isEmpty == true ? nil : token
    }

    public var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    public func start() throws {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw AFMError(code: "port", message: "Invalid port \(port).") }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: p)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isRunning = true
                self.log("Listening on \(self.baseURL)")
                self.onState?(true, nil)
            case .failed(let e):
                self.isRunning = false
                self.log("Server failed: \(e)")
                self.onState?(false, "\(e)")
            case .cancelled:
                self.isRunning = false
                self.onState?(false, nil)
            default: break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    func log(_ s: String) { onLog?(s) }

    private func accept(_ c: NWConnection) {
        guard openConnections < Self.maxConnections else { c.cancel(); return }
        openConnections += 1
        var counted = true
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                if counted { counted = false; self?.openConnections -= 1 }
            default: break
            }
        }
        c.start(queue: queue)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            switch HTTPRequest.inspect(buf) {
            case .complete(let req):
                Task { await self.route(req, c) }
                return
            case .invalid(let status, let message):
                self.error(c, status, message, code: "invalid_request")
                return
            case .incomplete:
                break
            }
            if done || err != nil { c.cancel(); return }
            self.receive(c, buf)
        }
    }

    // MARK: Responses

    private func raw(_ c: NWConnection, _ data: Data, close: Bool) {
        c.send(content: data, completion: .contentProcessed { _ in if close { c.cancel() } })
    }

    private func respond(_ c: NWConnection, _ status: Int, _ obj: Any) {
        let body = JSONValue.encode(obj)
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 413: "Payload Too Large", 415: "Unsupported Media Type", 431: "Request Header Fields Too Large", 500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "OK"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        raw(c, Data(head.utf8) + body, close: true)
    }

    private func error(_ c: NWConnection, _ status: Int, _ message: String, code: String = "error") {
        respond(c, status, ["error": ["message": message, "type": code, "code": code]])
    }

    // MARK: Routing

    private func route(_ r: HTTPRequest, _ c: NWConnection) async {
        log("\(r.method) \(r.path)")
        // Web pages must not be able to drive the model: refuse rebinding hosts and foreign origins,
        // and require a JSON body so a cross-site "simple" POST (text/plain, form data) is rejected.
        guard HTTPRequest.isLocalHost(r.headers["host"]) else { return error(c, 403, "Host \(r.headers["host"] ?? "") isn't allowed; use 127.0.0.1 or localhost", code: "forbidden_host") }
        guard HTTPRequest.isLocalOrigin(r.headers["origin"]) else { return error(c, 403, "Cross-origin requests aren't allowed", code: "forbidden_origin") }
        if r.method == "POST", !(r.headers["content-type"] ?? "").lowercased().hasPrefix("application/json") {
            return error(c, 415, "Send the body as JSON with Content-Type: application/json", code: "unsupported_media_type")
        }
        if let token, r.path != "/health" {
            guard HTTPRequest.tokenMatches(r.headers["authorization"], token) else { return error(c, 401, "Missing or wrong bearer token", code: "unauthorized") }
        }
        switch (r.method, r.path) {
        case ("GET", "/"), ("GET", "/health"):
            let s = ModelStatus.current()
            respond(c, 200, ["status": s.available ? "ok" : "unavailable", "available": s.available, "context_size": s.contextSize, "version": AFMVersion.string])
        case ("GET", "/v1/models"):
            respond(c, 200, ["object": "list", "data": OpenAIServer.models.map { ["id": $0, "object": "model", "created": 1_750_000_000, "owned_by": "apple"] }])
        case ("POST", "/v1/chat/completions"):
            await chatCompletions(r.json, c)
        case ("POST", "/v1/tokens"), ("POST", "/afm/tokens"):
            let text = r.json.str("text") ?? r.json.str("input") ?? ""
            respond(c, 200, ["tokens": await AFM.tokenCount(text), "context_size": AFM.contextSize])
        case ("GET", "/afm/recipes"):
            respond(c, 200, JSONValue.parse(MCPTools.recipesJSON()) ?? [:])
        case ("POST", let p) where p.hasPrefix("/afm/recipes/"):
            let id = String(p.dropFirst("/afm/recipes/".count))
            let b = r.json
            guard let recipe = RecipeBook.shared.find(id) else { return error(c, 404, "No recipe \(id)", code: "not_found") }
            let params = ((b["params"] as? [String: Any]) ?? [:]).reduce(into: [String: String]()) { $0[$1.key] = "\($1.value)" }
            do {
                let res = try await gate.serial { try await RecipeRunner.run(recipe, input: b.str("input") ?? b.str("text") ?? "", params: params) }
                History.append(HistoryEntry(source: "api", kind: "recipe", title: recipe.title, input: b.str("input") ?? "", output: res.text, seconds: res.seconds, outputTokens: res.outputTokens))
                var out: [String: Any] = ["recipe": recipe.id, "output": res.text, "seconds": res.seconds, "chunks": res.chunks]
                if res.isJSON { out["json"] = JSONValue.parse(res.text) ?? NSNull() }
                respond(c, 200, out)
            } catch {
                let e = AFMError.from(error)
                self.error(c, 500, e.fullDescription, code: e.code)
            }
        case ("OPTIONS", _):
            raw(c, Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), close: true)
        default:
            error(c, 404, "Unknown route \(r.method) \(r.path)", code: "not_found")
        }
    }

    static func text(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let parts = content as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        return ""
    }

    private func chatCompletions(_ b: [String: Any], _ c: NWConnection) async {
        let messages = (b["messages"] as? [[String: Any]]) ?? []
        let modelName = b.str("model") ?? OpenAIServer.models[0]
        var config = ModelConfig.default
        if modelName.hasSuffix("permissive") { config.guardrails = .permissive }
        if modelName.hasSuffix("tagging") { config.useCase = .tagging }

        var system = messages.filter { ["system", "developer"].contains($0["role"] as? String ?? "") }.map { Self.text($0["content"]) }.joined(separator: "\n\n")
        let convo = messages.filter { ["user", "assistant"].contains($0["role"] as? String ?? "") }
        guard let lastUser = convo.lastIndex(where: { $0["role"] as? String == "user" }) else {
            return error(c, 400, "messages must include a user message", code: "invalid_request")
        }

        var schema: GenerationSchema?
        var jsonObject = false
        if let rf = b["response_format"] as? [String: Any] {
            switch rf.str("type") {
            case "json_schema":
                if let js = rf["json_schema"] as? [String: Any], let s = js["schema"] as? [String: Any] {
                    do { schema = try JSONSchemaConverter.schema(from: s) } catch { return self.error(c, 400, "Unsupported schema: \(AFMError.from(error).message)", code: "invalid_schema") }
                }
            case "json_object":
                jsonObject = true
                system += (system.isEmpty ? "" : "\n\n") + "Respond with a single valid JSON object and nothing else."
            default: break
            }
        }

        var opts = GenOptions(temperature: b.double("temperature"), maxTokens: b.int("max_completion_tokens") ?? b.int("max_tokens"))
        if let s = b.int("seed") { opts.seed = UInt64(max(0, s)) }
        if let tp = b.double("top_p"), tp < 1 { opts.sampling = .topP; opts.topP = tp }
        if opts.temperature == 0 { opts.sampling = .greedy }

        let stream = b.bool("stream") == true
        let id = "chatcmpl-" + String(UUID().uuidString.prefix(12)).lowercased()
        let created = Int(Date().timeIntervalSince1970)
        let prompt = Self.text(convo[lastUser]["content"])

        do {
            let model = try config.makeModel()
            guard model.isAvailable else { return error(c, 503, ModelStatus.current().guidance ?? "Model unavailable", code: "unavailable") }
            var entries: [Transcript.Entry] = []
            if !system.isEmpty { entries.append(.instructions(Transcript.Instructions(segments: [.text(.init(content: system))], toolDefinitions: []))) }
            for m in convo[..<lastUser] {
                let t = Self.text(m["content"])
                if m["role"] as? String == "user" { entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: t))]))) }
                else { entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: t))]))) }
            }
            let session = LanguageModelSession(model: model, tools: [], transcript: Transcript(entries: entries))
            let start = Date()

            try await gate.serial {
                if stream {
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
                    raw(c, Data(head.utf8), close: false)
                    func chunk(_ delta: [String: Any], finish: String?) {
                        let obj: [String: Any] = ["id": id, "object": "chat.completion.chunk", "created": created, "model": modelName,
                                                  "choices": [["index": 0, "delta": delta, "finish_reason": (finish as Any?) ?? NSNull()]]]
                        raw(c, Data("data: \(JSONValue.string(obj))\n\n".utf8), close: false)
                    }
                    chunk(["role": "assistant", "content": ""], finish: nil)
                    var full = ""
                    if let schema {
                        let r = try await session.respond(to: Prompt(prompt), schema: schema, options: opts.generationOptions)
                        full = JSONRender.pretty(SchemaOrder(schema)?.apply(r.content) ?? r.content)
                        chunk(["content": full], finish: nil)
                    } else if jsonObject {
                        // Buffered, so a Markdown fence around the JSON can be removed before anything is sent.
                        full = JSONRender.unfenced(try await session.respond(to: Prompt(prompt), options: opts.generationOptions).content)
                        chunk(["content": full], finish: nil)
                    } else {
                        var sent = ""
                        for try await snap in session.streamResponse(to: Prompt(prompt), options: opts.generationOptions) {
                            let cur = snap.content
                            if cur.hasPrefix(sent) {
                                let delta = String(cur.dropFirst(sent.count))
                                if !delta.isEmpty { chunk(["content": delta], finish: nil) }
                            }
                            sent = cur
                        }
                        full = sent
                    }
                    chunk([:], finish: "stop")
                    raw(c, Data("data: [DONE]\n\n".utf8), close: true)
                    History.append(HistoryEntry(source: "api", kind: "chat.completions", title: modelName, input: prompt, output: full, seconds: Date().timeIntervalSince(start)))
                } else {
                    let text: String
                    if let schema {
                        let c = try await session.respond(to: Prompt(prompt), schema: schema, options: opts.generationOptions).content
                        text = JSONRender.pretty(SchemaOrder(schema)?.apply(c) ?? c)
                    } else {
                        let raw = try await session.respond(to: Prompt(prompt), options: opts.generationOptions).content
                        text = jsonObject ? JSONRender.unfenced(raw) : raw
                    }
                    let pt = (try? await model.tokenCount(for: session.transcript)) ?? 0
                    let ct = (try? await model.tokenCount(for: Prompt(text))) ?? 0
                    respond(c, 200, [
                        "id": id, "object": "chat.completion", "created": created, "model": modelName,
                        "choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": "stop"]],
                        "usage": ["prompt_tokens": max(0, pt - ct), "completion_tokens": ct, "total_tokens": pt],
                    ])
                    History.append(HistoryEntry(source: "api", kind: "chat.completions", title: modelName, input: prompt, output: text, seconds: Date().timeIntervalSince(start), outputTokens: ct))
                }
            }
        } catch {
            let e = await AFMError.resolve(error)
            if stream {
                let obj: [String: Any] = ["error": ["message": e.fullDescription, "type": e.code, "code": e.code]]
                raw(c, Data("data: \(JSONValue.string(obj))\n\ndata: [DONE]\n\n".utf8), close: true)
            } else {
                self.error(c, e.code == "context_exceeded" ? 400 : 500, e.fullDescription, code: e.code)
            }
        }
    }
}

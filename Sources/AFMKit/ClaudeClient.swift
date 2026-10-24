import Foundation

public struct ClaudeModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let inputPerMTok: Double
    public let outputPerMTok: Double
    /// Server-side refusal fallbacks (`fallbacks: "default"`) are supported on these models.
    public let supportsFallbacks: Bool

    public static let all: [ClaudeModel] = [
        ClaudeModel(id: "claude-opus-5-5", name: "Claude Opus 5.5", inputPerMTok: 4, outputPerMTok: 20, supportsFallbacks: true),
        ClaudeModel(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", inputPerMTok: 2, outputPerMTok: 10, supportsFallbacks: true),
        ClaudeModel(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", inputPerMTok: 0.10, outputPerMTok: 0.50, supportsFallbacks: false),
        ClaudeModel(id: "claude-fable-5-1", name: "Claude Fable 5.1", inputPerMTok: 10, outputPerMTok: 50, supportsFallbacks: true),
    ]
    public static let defaultID = "claude-opus-5-5"
    public static func find(_ id: String) -> ClaudeModel { all.first { $0.id == id } ?? all[0] }
}

public struct ClaudeResult: Sendable, Equatable {
    public var text: String
    public var model: String
    public var stopReason: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var seconds: Double
    public var firstTokenSeconds: Double?

    public func cost(_ m: ClaudeModel) -> Double {
        Double(inputTokens) / 1_000_000 * m.inputPerMTok + Double(outputTokens) / 1_000_000 * m.outputPerMTok
    }
}

/// A minimal streaming client for the Anthropic Messages API (raw HTTP: Swift has no official SDK).
public struct ClaudeClient: Sendable {
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]
    let apiKey: String
    public var model: String
    public var effort: String

    public init(apiKey: String, model: String = ClaudeModel.defaultID, effort: String = "medium") {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
    }

    /// Uses the Keychain key, falling back to ANTHROPIC_API_KEY.
    public static func fromStoredKey(model: String = ClaudeModel.defaultID, effort: String = "medium") throws -> ClaudeClient {
        guard let key = ClaudeKeychain.resolve().key else {
            throw AFMError(code: "no_api_key", message: "No Anthropic API key is set.",
                           suggestion: "Add one in AFM Studio > Claude, or run `afm claude key set`.")
        }
        return ClaudeClient(apiKey: key, model: model, effort: effort)
    }

    func request(path: String, method: String = "POST", body: [String: Any]? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.anthropic.com" + path)!, timeoutInterval: 600)
        r.httpMethod = method
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        if let body { r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return r
    }

    /// Checks the key without spending tokens (Models API).
    public func verify() async throws -> String {
        let (data, resp) = try await URLSession.shared.data(for: request(path: "/v1/models/\(model)", method: "GET"))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.apiError(status, data) }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (obj?["display_name"] as? String) ?? model
    }

    /// Streams a reply. `history` is prior turns as (role, text) pairs.
    public func stream(_ prompt: String, system: String? = nil, history: [(String, String)] = [],
                       maxTokens: Int = 16000, onText: (@Sendable (String) -> Void)? = nil) async throws -> ClaudeResult {
        let m = ClaudeModel.find(model)
        var messages: [[String: Any]] = history.map { ["role": $0.0, "content": $0.1] }
        messages.append(["role": "user", "content": prompt])
        var body: [String: Any] = [
            "model": model, "max_tokens": maxTokens, "stream": true, "messages": messages,
            "output_config": ["effort": effort],
        ]
        if let system, !system.isEmpty { body["system"] = system }
        var req = request(path: "/v1/messages", body: nil)
        if m.supportsFallbacks {
            body["fallbacks"] = "default"
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 100_000 { break } }
            throw Self.apiError(status, data)
        }
        var result = ClaudeResult(text: "", model: model, stopReason: nil, inputTokens: 0, outputTokens: 0, seconds: 0)
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let ev = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { continue }
            switch ev["type"] as? String {
            case "message_start":
                let msg = ev["message"] as? [String: Any]
                if let mdl = msg?["model"] as? String { result.model = mdl }
                if let u = msg?["usage"] as? [String: Any] { result.inputTokens = (u["input_tokens"] as? Int) ?? 0 }
            case "content_block_delta":
                if let d = ev["delta"] as? [String: Any], d["type"] as? String == "text_delta", let t = d["text"] as? String {
                    if result.firstTokenSeconds == nil { result.firstTokenSeconds = Date().timeIntervalSince(start) }
                    result.text += t
                    onText?(result.text)
                }
            case "message_delta":
                if let d = ev["delta"] as? [String: Any], let s = d["stop_reason"] as? String { result.stopReason = s }
                if let u = ev["usage"] as? [String: Any] {
                    if let o = u["output_tokens"] as? Int { result.outputTokens = o }
                    if let i = u["input_tokens"] as? Int, i > 0 { result.inputTokens = i }
                }
            case "error":
                let e = ev["error"] as? [String: Any]
                throw AFMError(code: (e?["type"] as? String) ?? "api_error", message: (e?["message"] as? String) ?? "The API returned an error.")
            default: break
            }
        }
        result.seconds = Date().timeIntervalSince(start)
        if result.stopReason == "refusal" {
            throw AFMError(code: "refusal", message: "Claude declined this request.", suggestion: result.text.isEmpty ? nil : "Partial output: \(result.text.prefix(200))")
        }
        return result
    }

    static func apiError(_ status: Int, _ data: Data) -> AFMError {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let e = obj?["error"] as? [String: Any]
        let msg = (e?["message"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
        switch status {
        case 401: return AFMError(code: "unauthorized", message: "The API key was rejected.", suggestion: "Check or replace the key.")
        case 403: return AFMError(code: "forbidden", message: msg)
        case 404: return AFMError(code: "not_found", message: msg)
        case 429: return AFMError(code: "rate_limited", message: "Rate limited by the Claude API.", suggestion: "Wait a moment and retry.")
        case 529: return AFMError(code: "overloaded", message: "The Claude API is overloaded.", suggestion: "Retry shortly.")
        default: return AFMError(code: "http_\(status)", message: msg)
        }
    }
}

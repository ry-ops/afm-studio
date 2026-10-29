import Foundation
import AFMKit

/// One typed question for Jev. Jev answers with probabilities, never with text.
public enum JevQuestion: Sendable, Equatable {
    /// True or false. The answer is the probability that the statement is true.
    case noul(instructions: String)
    /// Pick one option. Each option has a name and an optional description of when it applies.
    case choice(instructions: String, options: [JevOption])
    /// Place the state on an ordered scale. Level 0 is the first description.
    case score(instructions: String, levels: [String])

    public var json: [String: Any] {
        switch self {
        case .noul(let i): return ["type": "noul", "instructions": i]
        case .choice(let i, let opts):
            var criteria: [String: Any] = [:]
            for o in opts { criteria[o.name] = o.description ?? NSNull() }
            return ["type": "choice", "instructions": i, "criteria": criteria]
        case .score(let i, let levels): return ["type": "score", "instructions": i, "criteria": levels]
        }
    }
}

public struct JevOption: Sendable, Equatable {
    public var name: String
    public var description: String?
    public init(name: String, description: String? = nil) { self.name = name; self.description = description }

    /// Parses `name=description` or a bare `name`.
    public static func parse(_ s: String) -> JevOption {
        guard let i = s.firstIndex(of: "=") else { return JevOption(name: s.trimmingCharacters(in: .whitespaces)) }
        let d = String(s[s.index(after: i)...]).trimmingCharacters(in: .whitespaces)
        return JevOption(name: String(s[..<i]).trimmingCharacters(in: .whitespaces), description: d.isEmpty ? nil : d)
    }
}

/// One answer, keyed in the response by the question's name.
public struct JevAnswer: Sendable, Equatable {
    public var type: String
    /// noul: probability the statement is true.
    public var noul: Double?
    /// choice: the most likely option.
    public var choice: String?
    /// score: the probability-weighted level, from 0 to levels - 1.
    public var score: Double?
    public var confidence: Double?
    public var probabilities: [String: Double]
    /// score: what each level means.
    public var legend: [String: String]

    init(_ d: [String: Any]) {
        type = d["type"] as? String ?? "?"
        noul = (d["noul"] as? NSNumber)?.doubleValue
        choice = d["choice"] as? String
        score = (d["score"] as? NSNumber)?.doubleValue
        confidence = (d["confidence"] as? NSNumber)?.doubleValue
        probabilities = (d["probabilities"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
        legend = (d["legend"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
    }

    /// A one-line reading, e.g. "true 0.92", "billing (confidence 0.81)", "1.43 of 0–2 (confidence 0.35)".
    public var summary: String {
        func f(_ x: Double) -> String { String(format: "%.2f", x) }
        switch type {
        case "noul": return noul.map { "\($0 >= 0.5 ? "true" : "false") · p(true) = \(f($0))" } ?? "no answer"
        case "choice": return (choice ?? "?") + (confidence.map { " · confidence \(f($0))" } ?? "")
        case "score":
            let top = legend.keys.compactMap(Int.init).max().map { " of 0–\($0)" } ?? ""
            let nearest = score.flatMap { legend[String(Int($0.rounded()))] }.map { " (\($0))" } ?? ""
            return (score.map(f) ?? "?") + top + nearest + (confidence.map { " · confidence \(f($0))" } ?? "")
        default: return "\(type) answer"
        }
    }

    /// Rounds to four places as a decimal, so JSON shows 0.96 rather than 0.95999999999999996.
    static func clean(_ x: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.4f", x)) }

    public var json: [String: Any] {
        var d: [String: Any] = ["type": type]
        if let noul { d["noul"] = Self.clean(noul) }
        if let choice { d["choice"] = choice }
        if let score { d["score"] = Self.clean(score) }
        if let confidence { d["confidence"] = Self.clean(confidence) }
        if !probabilities.isEmpty { d["probabilities"] = probabilities.mapValues(Self.clean) }
        if !legend.isEmpty { d["legend"] = legend }
        return d
    }
}

public struct JevResult: @unchecked Sendable {
    public var model: String
    /// In the order the questions were asked.
    public var answers: [(name: String, answer: JevAnswer)]
    public var inputTokens: Int
    public var outputTokens: Int
    public var seconds: Double

    public var json: [String: Any] {
        var a: [String: Any] = [:]
        for (n, ans) in answers { a[n] = ans.json }
        return ["model": model, "answers": a, "usage": ["input_tokens": inputTokens, "output_tokens": outputTokens],
                "seconds": NSDecimalNumber(string: String(format: "%.3f", seconds)),
                "estimated_cost_usd": NSDecimalNumber(string: String(format: "%.8f", JevUsage.cost(inputTokens: inputTokens)))]
    }

    public var text: String {
        let width = answers.map(\.name.count).max() ?? 0
        let lines = answers.map { $0.name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + $0.answer.summary }
        return (lines + [String(format: "%@ · %d input tokens · %.0f ms", model, inputTokens, seconds * 1000)]).joined(separator: "\n")
    }
}

/// TypeSafe's System One API. https://docs.typesafe.ai/api/system-one
public struct JevClient: Sendable {
    public static let base = "https://api.typesafe.ai"
    public static let defaultModel = "jev-latest"
    /// Jev reads up to 32K tokens. This stops a huge file before it is sent and billed.
    public static let maxStateCharacters = 120_000

    let key: String
    public init(key: String) { self.key = key }

    /// A client using the saved key. Throws if the integration is off or no key is set.
    public static func make() throws -> JevClient {
        try IntegrationRegistry.requireEnabled(JevIntegration.integrationID)
        guard let k = JevAuth.resolve().key else {
            throw AFMError(code: "jev_no_key", message: "No TypeSafe API key is set.",
                           suggestion: "Run `afm jev key set`, or add it in AFM Studio > Integrations > Jev.")
        }
        return JevClient(key: k)
    }

    /// Builds the request body. Question names keep their order in `questions`.
    public static func body(model: String, state: Any, questions: [(String, [String: Any])]) throws -> Data {
        guard !questions.isEmpty else { throw AFMError(code: "jev_no_questions", message: "Ask at least one question.") }
        var q: [String: Any] = [:]
        for (name, def) in questions {
            guard !name.isEmpty else { throw AFMError(code: "jev_bad_question", message: "Every question needs a name.") }
            guard let t = def["type"] as? String, ["noul", "choice", "score"].contains(t) else {
                throw AFMError(code: "jev_bad_question", message: "Question \(name) needs a type of noul, choice or score.")
            }
            q[name] = def
        }
        if let s = state as? String {
            guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AFMError(code: "jev_no_state", message: "Give Jev something to decide about.", suggestion: "Pass text, a file or stdin.")
            }
            guard s.count <= maxStateCharacters else {
                throw AFMError(code: "jev_too_long", message: "That's \(s.count) characters, more than Jev's 32K-token window holds.",
                               suggestion: "Send a smaller excerpt.")
            }
        }
        return try JSONSerialization.data(withJSONObject: ["model": model, "state": state, "questions": q], options: [.sortedKeys])
    }

    /// Asks the questions about `state` (text or a JSON object) in one call.
    public func decide(state: Any, questions: [(String, [String: Any])], model: String = JevSettings.load().model,
                       source: String = "cli") async throws -> JevResult {
        let body = try Self.body(model: model, state: state, questions: questions)
        let start = Date()
        let data = try await post("/v1/systemone", body: body)
        let seconds = Date().timeIntervalSince(start)
        let r = try Self.parse(data, order: questions.map(\.0), seconds: seconds)
        JevUsage.record(inputTokens: r.inputTokens, model: r.model, source: source)
        return r
    }

    public static func parse(_ data: Data, order: [String], seconds: Double) throws -> JevResult {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let answers = json["answers"] as? [String: Any] else {
            throw AFMError(code: "jev_decode", message: "Unexpected response from TypeSafe.")
        }
        let usage = json["usage"] as? [String: Any] ?? [:]
        let names = order.filter { answers[$0] != nil } + answers.keys.filter { !order.contains($0) }.sorted()
        return JevResult(model: json["model"] as? String ?? "?",
                         answers: names.map { ($0, JevAnswer(answers[$0] as? [String: Any] ?? [:])) },
                         inputTokens: (usage["input_tokens"] as? NSNumber)?.intValue ?? 0,
                         outputTokens: (usage["output_tokens"] as? NSNumber)?.intValue ?? 0,
                         seconds: seconds)
    }

    public struct Model: Sendable { public var name: String; public var description: String; public var releaseDate: String }

    public func models() async throws -> [Model] {
        let data = try await request("GET", "/v1/models", body: nil)
        let list = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["models"] as? [[String: Any]] ?? []
        return list.map { Model(name: $0["name"] as? String ?? "?", description: $0["description"] as? String ?? "", releaseDate: $0["release_date"] as? String ?? "") }
    }

    func post(_ path: String, body: Data) async throws -> Data { try await request("POST", path, body: body) }

    /// Retries 429 and 529 with backoff, as TypeSafe's docs ask. Other errors fail at once.
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        var delay: UInt64 = 500_000_000
        for attempt in 1...4 {
            var req = URLRequest(url: URL(string: Self.base + path)!, timeoutInterval: 30)
            req.httpMethod = method
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("afm-studio/\(AFMVersion.string)", forHTTPHeaderField: "User-Agent")
            if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (data, resp): (Data, URLResponse)
            do { (data, resp) = try await URLSession.shared.data(for: req) }
            catch { throw AFMError(code: "jev_network", message: "Couldn't reach TypeSafe: \(error.localizedDescription)") }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return data }
            if (status == 429 || status == 529), attempt < 4 {
                try await Task.sleep(nanoseconds: delay); delay *= 2; continue
            }
            throw Self.error(status: status, data: data)
        }
        throw AFMError(code: "jev_busy", message: "TypeSafe stayed busy.")
    }

    public static func error(status: Int, data: Data) -> AFMError {
        let detail = detailText(data)
        switch status {
        case 401: return AFMError(code: "jev_auth", message: "TypeSafe rejected the API key.", suggestion: "Check it with `afm jev key show`, or set a new one with `afm jev key set`.")
        case 402, 403: return AFMError(code: "jev_denied", message: "TypeSafe refused the request\(detail.map { ": \($0)" } ?? ".")",
                                       suggestion: "Your spending limit may be used up. Check console.typesafe.ai.")
        case 429: return AFMError(code: "jev_rate_limit", message: "TypeSafe's rate limit was hit.", suggestion: "Wait a moment and try again.")
        case 529: return AFMError(code: "jev_overloaded", message: "TypeSafe is overloaded.", suggestion: "Try again shortly.")
        case 400 where detail?.contains("max_tokens_exceeded") == true:
            return AFMError(code: "jev_too_long", message: "The input is longer than Jev's context window.", suggestion: "Send a smaller excerpt.")
        default: return AFMError(code: "jev_\(status)", message: "TypeSafe: \(detail ?? "HTTP \(status)")")
        }
    }

    /// The `detail` field TypeSafe puts in error bodies, flattened to one line.
    static func detailText(_ data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let d = json["detail"] else {
            let s = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        if let s = d as? String { return s }
        if let list = d as? [[String: Any]] {
            return list.map { e in
                let loc = (e["loc"] as? [Any] ?? []).map { "\($0)" }.joined(separator: ".")
                return (loc.isEmpty ? "" : loc + ": ") + (e["msg"] as? String ?? "invalid")
            }.joined(separator: "; ")
        }
        if let obj = d as? [String: Any], let m = obj["message"] as? String ?? obj["code"] as? String { return m }
        return "\(d)"
    }
}

import Foundation
import AFMKit
import FoundationModels

/// Jev, TypeSafe AI's decision model. It answers typed questions (noul, choice, score) with
/// probabilities instead of text. Pairs with the on-device model: AFM writes, Jev decides.
public struct JevIntegration: AFMIntegration {
    public static let integrationID = "jev"
    public init() {}
    public let id = JevIntegration.integrationID
    public let name = "Jev"
    public let symbol = "arrow.triangle.branch"
    public let summary = "TypeSafe's decision model. Ask yes/no, multiple-choice or scale questions about text and get probabilities back in milliseconds."

    public let manifest = IntegrationManifest(
        credentials: ["A TypeSafe API key from your Keychain, or TYPESAFE_API_KEY"],
        hosts: ["api.typesafe.ai"],
        writes: .none,
        dataNote: "The text you ask about is sent to TypeSafe's cloud. TypeSafe says it doesn't train on customer data. Each call is billed to your TypeSafe account; AFM Studio keeps a running tally on this Mac.")

    public func status() async -> IntegrationStatus {
        guard IntegrationRegistry.isEnabled(id) else { return IntegrationStatus(connected: false, detail: "Turned off.") }
        guard JevAuth.resolve().key != nil else { return IntegrationStatus(connected: false, detail: "No API key. Run `afm jev key set`.") }
        do {
            let models = try await JevClient.make().models()
            return IntegrationStatus(connected: true, detail: "Connected with \(JevAuth.sourceDescription). Models: \(models.map(\.name).joined(separator: ", ")).")
        } catch {
            return IntegrationStatus(connected: false, detail: AFMError.from(error).fullDescription)
        }
    }

    /// Turns TypeSafe-format questions ({"name": {"type": …, "instructions": …, "criteria": …}}) into ordered pairs.
    public static func questions(from any: Any?) throws -> [(String, [String: Any])] {
        guard let dict = any as? [String: Any], !dict.isEmpty else {
            throw AFMError(code: "jev_no_questions", message: "Give `questions` as an object of named questions.",
                           suggestion: #"Example: {"spam": {"type": "noul", "instructions": "Is this comment spam?"}}"#)
        }
        return try dict.keys.sorted().map { name in
            guard let q = dict[name] as? [String: Any] else {
                throw AFMError(code: "jev_bad_question", message: "Question \(name) must be an object with a type.")
            }
            return (name, q)
        }
    }

    /// A one-question shortcut: options make it a choice, otherwise a yes/no.
    public static func simpleQuestion(_ question: String, options: String?) -> JevQuestion {
        let opts = (options ?? "").split(separator: ",").map { JevOption.parse(String($0)) }.filter { !$0.name.isEmpty }
        return opts.count >= 2 ? .choice(instructions: question, options: opts) : .noul(instructions: question)
    }

    // MARK: Tool for the on-device model (chat). One small definition to save the 4K context.

    public func modelTools(tracker: ToolCallTracker?) -> [any Tool] {
        let schema = try! GenerationSchema(root: DynamicGenerationSchema(name: "JevDecideArgs", properties: [
            .init(name: "text", description: "The text to judge", schema: .init(type: String.self)),
            .init(name: "question", description: "A yes/no question or statement about the text", schema: .init(type: String.self)),
            .init(name: "options", description: "Optional comma-separated options to choose from instead of yes/no", schema: .init(type: String.self)),
        ]), dependencies: [])
        @Sendable func str(_ c: GeneratedContent, _ k: String) -> String { ((try? c.value(String?.self, forProperty: k)) ?? nil) ?? "" }
        return [
            DynamicTool(name: "jev_decide", description: "Get a calibrated probability from Jev, a fast decision model in the cloud: is a statement about the text true, or which option fits best.",
                        parameters: schema) { a in
                let question = str(a, "question")
                tracker?.record("jev_decide(\(question.prefix(40)))")
                let q = JevIntegration.simpleQuestion(question, options: str(a, "options"))
                let r = try await JevClient.make().decide(state: str(a, "text"), questions: [("answer", q.json)], source: "chat")
                return r.answers.first.map { "Jev: \($0.answer.summary)" } ?? "Jev gave no answer."
            },
        ]
    }

    // MARK: Tool for Claude (MCP)

    public var mcpTools: [IntegrationTool] {
        [
            IntegrationTool(
                name: "afm_jev_decide", title: "Decide with Jev",
                description: """
                Ask Jev, TypeSafe's decision model, typed questions about text or a local file and get probabilities back, usually in well under a second. \
                With `path` the file is read on this Mac and sent to TypeSafe, so it never enters your context. \
                `questions` maps your names to questions: {"type": "noul", "instructions": "..."} for true/false (returns p(true)); \
                {"type": "choice", "instructions": "...", "criteria": {"option": "when it applies", ...}} to pick one; \
                {"type": "score", "instructions": "...", "criteria": ["level 0", "level 1", ...]} for an ordered scale. \
                Or give `question` (and optional comma-separated `options`) for a single quick decision. \
                Good for classification, routing and gating; weak at counting, arithmetic and dates, so do those in code. Each call is billed to the user's TypeSafe account.
                """,
                properties: [
                    "text": ["type": "string", "description": "The text to decide about. Give this or `path`."],
                    "path": ["type": "string", "description": "A text file in the user's home folder. Key, credential and .env files are refused."],
                    "questions": ["type": "object", "description": "Named questions in TypeSafe's format.", "additionalProperties": ["type": "object"]],
                    "question": ["type": "string", "description": "A single yes/no question, used when `questions` is absent."],
                    "options": ["type": "string", "description": "With `question`: comma-separated options, each `name` or `name=when it applies`. Makes it a choice."],
                    "model": ["type": "string", "description": "Model name (default from settings, usually jev-latest)."],
                ]) { a in
                    let state: String
                    if let t = a.s("text") { state = t }
                    else if let p = a.s("path") { state = try FileAccess.readText(p, limit: JevClient.maxStateCharacters * 4) }
                    else { throw AFMError(code: "missing_input", message: "Give `text` or `path`.") }
                    let qs: [(String, [String: Any])]
                    if a["questions"] != nil { qs = try Self.questions(from: a["questions"]) }
                    else if let q = a.s("question") { qs = [("answer", Self.simpleQuestion(q, options: a.s("options")).json)] }
                    else { throw AFMError(code: "jev_no_questions", message: "Give `questions` or `question`.") }
                    let client = try JevClient.make()
                    let r = try await client.decide(state: state, questions: qs, model: a.s("model") ?? JevSettings.load().model, source: "mcp")
                    return IntegrationOutput(text: r.text, json: r.json)
                },
        ]
    }
}

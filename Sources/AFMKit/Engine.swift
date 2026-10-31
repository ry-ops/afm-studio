import Foundation
import FoundationModels

public struct GenerationRequest: Sendable {
    public var prompt: String
    public var instructions: String?
    public var options: GenOptions
    public var config: ModelConfig
    public var tools: [ToolKind]
    public var schema: GenerationSchema?
    public var includeSchemaInPrompt: Bool
    public var measureTokens: Bool

    public init(prompt: String, instructions: String? = nil, options: GenOptions = .default, config: ModelConfig = .default,
                tools: [ToolKind] = [], schema: GenerationSchema? = nil, includeSchemaInPrompt: Bool = true, measureTokens: Bool = true) {
        self.prompt = prompt
        self.instructions = instructions
        self.options = options
        self.config = config
        self.tools = tools
        self.schema = schema
        self.includeSchemaInPrompt = includeSchemaInPrompt
        self.measureTokens = measureTokens
    }
}

public struct GenerationResult: Codable, Sendable, Equatable, Hashable {
    public var text: String
    public var isJSON: Bool
    public var seconds: Double
    public var firstTokenSeconds: Double?
    public var promptTokens: Int?
    public var outputTokens: Int?
    public var toolCalls: [String]
    public var chunks: Int
    /// For a recipe that fetched its own input: what it found, with links.
    public var sources: [SourceItem]?
    /// For a recipe that fetched its own input: the text the model read.
    public var sourceText: String?

    public init(text: String, isJSON: Bool = false, seconds: Double = 0, firstTokenSeconds: Double? = nil,
                promptTokens: Int? = nil, outputTokens: Int? = nil, toolCalls: [String] = [], chunks: Int = 1,
                sources: [SourceItem]? = nil, sourceText: String? = nil) {
        self.sources = sources
        self.sourceText = sourceText
        self.text = text
        self.isJSON = isJSON
        self.seconds = seconds
        self.firstTokenSeconds = firstTokenSeconds
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.toolCalls = toolCalls
        self.chunks = chunks
    }

    /// Decode speed: the tokens after the first, over the time after the first token. Nil when the
    /// reply is too short to time, because a two-token answer ends a millisecond after it starts.
    public var tokensPerSecond: Double? {
        guard let o = outputTokens, o >= Self.minTimedTokens, seconds > 0 else { return nil }
        guard let first = firstTokenSeconds else { return Double(o) / seconds }
        let gen = seconds - first
        guard gen >= 0.05 else { return nil }
        return Double(o - 1) / gen
    }

    public static let minTimedTokens = 8

    public var statsLine: String {
        var parts = [String(format: "%.2fs", seconds)]
        if let f = firstTokenSeconds { parts.append(String(format: "first token %.2fs", f)) }
        if let p = promptTokens { parts.append("\(p) in") }
        if let o = outputTokens { parts.append("\(o) out") }
        if chunks == 1, let t = tokensPerSecond { parts.append(String(format: "%.1f tok/s", t)) }
        if chunks > 1 { parts.append("\(chunks) chunks") }
        if !toolCalls.isEmpty { parts.append("tools: " + toolCalls.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// The main entry point: one call for plain, streamed, tool-using or structured generation.
public enum AFM {
    public static var status: ModelStatus { .current() }

    /// `AFM_TRACE=1` logs each model call's time and sizes to stderr, to see where a slow run spends it.
    static let isTracing = ProcessInfo.processInfo.environment["AFM_TRACE"] == "1"

    public static func run(_ req: GenerationRequest,
                           onPartial: (@Sendable (String) -> Void)? = nil,
                           onTool: (@Sendable (String) -> Void)? = nil) async throws -> GenerationResult {
        do {
            let model = req.config.makeModel()
            guard model.isAvailable else { throw AFMError.unavailable(.current()) }
            let tracker = ToolCallTracker(onCall: onTool)
            let tools = ToolRegistry.make(req.tools, tracker: tracker)
            let instructions = req.instructions.flatMap { $0.isEmpty ? nil : Instructions($0) }
            let session = LanguageModelSession(model: model, tools: tools, instructions: instructions)
            var genOptions = req.options
            if genOptions.maxTokens == nil {
                // Cap the reply at the room left in the context, so a runaway reply ends early instead of failing.
                var used = (try? await model.tokenCount(for: Prompt(req.prompt))) ?? Chunker.estimate(req.prompt)
                if let i = req.instructions, !i.isEmpty { used += (try? await model.tokenCount(for: Instructions(i))) ?? Chunker.estimate(i) }
                if let schema = req.schema { used += (try? await model.tokenCount(for: schema)) ?? 300 }
                if !tools.isEmpty { used += (try? await model.tokenCount(for: tools)) ?? 150 * tools.count }
                let room = model.contextSize - used - 120
                if room >= 64 { genOptions.maxTokens = room }
            }
            let opts = genOptions.generationOptions
            let prompt = Prompt(req.prompt)
            let start = Date()
            var first: Double?
            var text = ""
            var isJSON = false

            if let schema = req.schema {
                isJSON = true
                let order = SchemaOrder(schema)
                func fmt(_ c: GeneratedContent) -> String { JSONRender.pretty(order?.apply(c) ?? c) }
                if let onPartial {
                    let stream = session.streamResponse(to: prompt, schema: schema, includeSchemaInPrompt: req.includeSchemaInPrompt, options: opts)
                    var last: GeneratedContent?
                    for try await snap in stream {
                        if first == nil { first = Date().timeIntervalSince(start) }
                        last = snap.rawContent
                        onPartial(fmt(snap.rawContent))
                    }
                    text = last.map(fmt) ?? "{}"
                } else {
                    let r = try await session.respond(to: prompt, schema: schema, includeSchemaInPrompt: req.includeSchemaInPrompt, options: opts)
                    text = fmt(r.content)
                }
            } else if let onPartial {
                let stream = session.streamResponse(to: prompt, options: opts)
                for try await snap in stream {
                    if first == nil { first = Date().timeIntervalSince(start) }
                    text = snap.content
                    onPartial(text)
                }
            } else {
                let r = try await session.respond(to: prompt, options: opts)
                text = r.content
            }

            let seconds = Date().timeIntervalSince(start)
            if AFM.isTracing {
                let head = req.prompt.prefix(60).replacingOccurrences(of: "\n", with: " ")
                FileHandle.standardError.write(Data(String(format: "[afm-trace] %.1fs  in %d chars  out %d chars  %@\n", seconds, req.prompt.count, text.count, head).utf8))
            }
            var pt: Int?
            var ot: Int?
            if req.measureTokens {
                pt = try? await model.tokenCount(for: prompt)
                ot = try? await model.tokenCount(for: Prompt(text))
            }
            return GenerationResult(text: text, isJSON: isJSON, seconds: seconds, firstTokenSeconds: first,
                                    promptTokens: pt, outputTokens: ot, toolCalls: tracker.calls)
        } catch {
            throw await AFMError.resolve(error)
        }
    }

    /// Convenience one-liner.
    public static func generate(_ prompt: String, instructions: String? = nil, options: GenOptions = .default,
                                config: ModelConfig = .default) async throws -> String {
        try await run(GenerationRequest(prompt: prompt, instructions: instructions, options: options, config: config, measureTokens: false)).text
    }

    /// Exact token count from the on-device tokenizer (falls back to an estimate).
    public static func tokenCount(_ text: String, config: ModelConfig = .default) async -> Int {
        await Chunker.countTokens(text, model: config.makeModel())
    }

    public static func tokenCount(instructions: String, config: ModelConfig = .default) async -> Int {
        (try? await config.makeModel().tokenCount(for: Instructions(instructions))) ?? Chunker.estimate(instructions)
    }

    public static var contextSize: Int { SystemLanguageModel.default.contextSize }
}

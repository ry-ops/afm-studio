import Foundation
import FoundationModels

public struct RecipeParam: Codable, Sendable, Hashable, Identifiable {
    public var key: String
    public var label: String
    public var defaultValue: String
    public var choices: [String]?
    public var help: String?
    public var id: String { key }

    public init(key: String, label: String, defaultValue: String, choices: [String]? = nil, help: String? = nil) {
        self.key = key; self.label = label; self.defaultValue = defaultValue; self.choices = choices; self.help = help
    }
}

/// How a recipe copes with input that is larger than the context window.
public enum LongStrategy: String, Codable, Sendable, Hashable, CaseIterable {
    /// Run on each chunk, then run again on the joined results (summaries, answers).
    case reduce
    /// Run on each chunk and join the outputs in order (rewrites, translation).
    case concatenate
    /// Structured output: merge JSON from every chunk.
    case merge
    /// Refuse input that doesn't fit.
    case reject
    /// Keep the end that fits and drop the beginning (logs, where the error is near the end).
    case tail
}

/// Work done on a recipe's result before it is returned.
public enum RecipeTransform: String, Codable, Sendable, Hashable {
    /// The schema lists people and addresses; the answer is the input with them, and emails,
    /// phone numbers, SSNs and card numbers, replaced by placeholders (`Redactor`).
    case redact
}

/// A reusable task: instructions, a prompt template and optionally a JSON Schema.
/// Built-ins ship with the app; user recipes are JSON files in the recipes folder.
public struct Recipe: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String
    public var symbol: String
    public var category: String
    public var instructions: String
    public var template: String
    public var params: [RecipeParam]
    public var schema: String?
    public var temperature: Double?
    public var useCase: UseCaseMode?
    public var permissive: Bool?
    public var long: LongStrategy?
    public var builtin: Bool?
    public var transform: RecipeTransform?
    /// The most top-level bullets a prose answer may have, keyed by a parameter value: summarize
    /// uses `["short": 5, "medium": 10]` for its length. The model ignores such limits when it
    /// combines the results of a long input, so the runner enforces them.
    public var maxBullets: [String: Int]?
    /// The most sentences a prose answer without bullets may have, keyed the same way.
    public var maxSentences: [String: Int]?

    public init(id: String, title: String, summary: String, symbol: String = "wand.and.stars", category: String = "Custom",
                instructions: String, template: String = "{{input}}", params: [RecipeParam] = [], schema: String? = nil,
                temperature: Double? = nil, useCase: UseCaseMode? = nil, permissive: Bool? = nil, long: LongStrategy? = nil, builtin: Bool? = nil,
                transform: RecipeTransform? = nil, maxBullets: [String: Int]? = nil, maxSentences: [String: Int]? = nil) {
        self.id = id; self.title = title; self.summary = summary; self.symbol = symbol; self.category = category
        self.instructions = instructions; self.template = template; self.params = params; self.schema = schema
        self.temperature = temperature; self.useCase = useCase; self.permissive = permissive; self.long = long; self.builtin = builtin
        self.transform = transform; self.maxBullets = maxBullets; self.maxSentences = maxSentences
    }

    /// Whether these parameter values ask for bullets (summarize's "bullet points" style) rather than prose.
    static func asksForBullets(_ values: [String: String]) -> Bool {
        values.values.contains { $0.lowercased().contains("bullet") }
    }

    /// The bullet limit that applies with these parameter values, or nil. Only a bulleted answer has one.
    public func bulletLimit(_ values: [String: String]) -> Int? {
        guard let maxBullets, Recipe.asksForBullets(values) else { return nil }
        return values.values.compactMap { maxBullets[$0] }.min()
    }

    /// The sentence limit that applies with these parameter values, or nil. Only a prose answer has one.
    public func sentenceLimit(_ values: [String: String]) -> Int? {
        guard let maxSentences, !Recipe.asksForBullets(values) else { return nil }
        return values.values.compactMap { maxSentences[$0] }.min()
    }

    /// The answer is JSON. A recipe with a transform uses its schema internally and answers in text.
    public var isStructured: Bool { schema != nil && transform == nil }
    public var isBuiltin: Bool { builtin == true }
    public var strategy: LongStrategy { long ?? (isStructured ? .merge : .reduce) }

    public func defaults() -> [String: String] {
        Dictionary(uniqueKeysWithValues: params.map { ($0.key, $0.defaultValue) })
    }

    /// Replaces `{{key}}` with the value and `{{key_json}}` with a JSON array of comma-separated values.
    public static func render(_ template: String, _ values: [String: String]) -> String {
        var out = template
        for (k, v) in values {
            let items = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let json = "[" + items.map { JSONRender.quote($0) }.joined(separator: ",") + "]"
            out = out.replacingOccurrences(of: "{{\(k)_json}}", with: json)
            out = out.replacingOccurrences(of: "{{\(k)}}", with: v)
        }
        return out
    }
}

public final class RecipeBook: @unchecked Sendable {
    public static let shared = RecipeBook()
    public init() {}

    public var userDirectory: URL { AFMPaths.recipes }

    public func all() -> [Recipe] {
        var byID: [String: Recipe] = [:]
        var order: [String] = []
        for r in Recipe.builtins { byID[r.id] = r; order.append(r.id) }
        for r in userRecipes() {
            if byID[r.id] == nil { order.append(r.id) }
            byID[r.id] = r
        }
        return order.compactMap { byID[$0] }
    }

    public func find(_ id: String) -> Recipe? {
        let key = id.lowercased()
        return all().first { $0.id.lowercased() == key }
    }

    public func userRecipes() -> [Recipe] {
        let files = (try? FileManager.default.contentsOfDirectory(at: userDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let d = try? Data(contentsOf: url), var r = try? JSONDecoder().decode(Recipe.self, from: d) else { return nil }
            r.builtin = false
            return r
        }
    }

    public func save(_ recipe: Recipe) throws {
        var r = recipe
        r.builtin = nil
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(r).write(to: userDirectory.appendingPathComponent(Self.fileName(r.id)), options: .atomic)
    }

    public func delete(_ id: String) throws {
        let url = userDirectory.appendingPathComponent(Self.fileName(id))
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    static func fileName(_ id: String) -> String {
        id.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "-" }.joined() + ".json"
    }
}

/// Runs recipes, including automatic map-reduce for documents larger than the context window.
public enum RecipeRunner {
    public struct Progress: Sendable { public let done: Int; public let total: Int; public let stage: String }

    /// The last whole lines of `text` that fit in `budget` tokens.
    static func tail(_ text: String, budget: Int, model: SystemLanguageModel) async throws -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while lines.count > 1, Chunker.estimate(lines.joined(separator: "\n")) > budget { lines.removeFirst(max(1, lines.count / 20)) }
        while lines.count > 1, await Chunker.countTokens(lines.joined(separator: "\n"), model: model) > budget { lines.removeFirst(max(1, lines.count / 10)) }
        var kept = lines.joined(separator: "\n")
        // One line longer than the budget (minified output): keep its end.
        while kept.count > 200, await Chunker.countTokens(kept, model: model) > budget { kept = String(kept.suffix(kept.count * 4 / 5)) }
        return kept
    }

    public static func run(_ recipe: Recipe, input: String, params: [String: String] = [:],
                           options: GenOptions = .default, config: ModelConfig = .default,
                           onPartial: (@Sendable (String) -> Void)? = nil,
                           onProgress: (@Sendable (Progress) -> Void)? = nil) async throws -> GenerationResult {
        guard let transform = recipe.transform else {
            return try await generate(recipe, input: input, params: params, options: options, config: config, onPartial: onPartial, onProgress: onProgress)
        }
        // The model's JSON is an intermediate step: don't stream it as if it were the answer.
        var r = try await generate(recipe, input: input, params: params, options: options, config: config, onPartial: nil, onProgress: onProgress)
        switch transform {
        case .redact:
            r.text = Redactor.redact(input, found: r.text).text
        }
        r.isJSON = false
        onPartial?(r.text)
        return r
    }

    static func generate(_ recipe: Recipe, input: String, params: [String: String],
                         options: GenOptions, config: ModelConfig,
                         onPartial: (@Sendable (String) -> Void)?,
                         onProgress: (@Sendable (Progress) -> Void)?) async throws -> GenerationResult {
        var values = recipe.defaults()
        for (k, v) in params where !v.isEmpty { values[k] = v }

        var cfg = config
        if let u = recipe.useCase { cfg.useCase = u }
        if recipe.permissive == true { cfg.guardrails = .permissive }
        var opts = options
        if opts.temperature == nil { opts.temperature = recipe.temperature }

        let schemaText = recipe.schema.map { Recipe.render($0, values) }
        let schema: GenerationSchema? = try schemaText.map { try JSONSchemaConverter.schema(fromJSON: $0) }
        let instructions = Recipe.render(recipe.instructions, values)
        let model = cfg.makeModel()
        guard model.isAvailable else { throw AFMError.unavailable(.current()) }

        let overhead = await Chunker.countTokens(instructions + Recipe.render(recipe.template, values.merging(["input": ""]) { a, _ in a }), model: model)
        var schemaTokens = 0
        if let schema { schemaTokens = (try? await model.tokenCount(for: schema)) ?? 0 }
        let reserve = opts.maxTokens ?? (schema == nil ? 900 : 700)
        let budget = max(500, model.contextSize - overhead - schemaTokens - reserve - 160)

        let limit = schema == nil ? recipe.bulletLimit(values) : nil
        let sentenceLimit = schema == nil ? recipe.sentenceLimit(values) : nil

        /// Tidies a prose answer and holds it to the recipe's bullet limit: first by asking the model
        /// to pick the most important bullets, then, if it still runs over, by keeping the first ones.
        func finish(_ r: inout GenerationResult, input: String, partial: (@Sendable (String) -> Void)?) async throws {
            guard schema == nil else { return }
            r.text = TextCleanup.tidy(r.text, input: input)
            if TextCleanup.bulletCount(r.text) == 0, let sentenceLimit, TextCleanup.sentenceCount(r.text) > sentenceLimit {
                let shorten = GenerationRequest(
                    prompt: "Shorten this to at most \(sentenceLimit) sentences. Keep the most important facts, add nothing, and output only the shortened text.\n\n\(r.text)",
                    instructions: "You shorten text without changing its facts.", options: opts, config: cfg)
                if let short = try? await AFM.run(shorten, onPartial: nil), !short.text.isEmpty {
                    r.text = TextCleanup.tidy(short.text, input: input)
                }
                r.text = TextCleanup.firstSentences(r.text, sentenceLimit)
                partial?(r.text)
                return
            }
            guard let limit, TextCleanup.bulletCount(r.text) > limit else { return }
            let pick = GenerationRequest(
                prompt: "Keep only the \(limit) most important of these bullet points, covering the whole list rather than its start, and skipping any that repeat another. Copy each kept bullet unchanged. Output only those \(limit) bullets.\n\n\(r.text)",
                instructions: "You choose the most important points from a list. Never add or reword a point.", options: opts, config: cfg)
            if let picked = try? await AFM.run(pick, onPartial: nil), TextCleanup.bulletCount(picked.text) > 0 {
                r.text = TextCleanup.tidy(picked.text, input: input)
            }
            r.text = TextCleanup.firstBullets(r.text, limit)
            partial?(r.text)
        }

        func once(_ text: String, partial: (@Sendable (String) -> Void)?, options: GenOptions? = nil, extra: String = "") async throws -> GenerationResult {
            var v = values
            v["input"] = text
            let prompt = Recipe.render(recipe.template, v)
            let request = GenerationRequest(prompt: prompt, instructions: instructions + extra, options: options ?? opts, config: cfg, schema: schema)
            do {
                return try await AFM.run(request, onPartial: partial)
            } catch where AFMError.isTransientModelError(error) {
                return try await AFM.run(request, onPartial: partial)  // once; it clears up on retry
            }
        }

        let inputTokens = await Chunker.countTokens(input, model: model)
        if inputTokens <= budget {
            var single = try await once(input, partial: onPartial)
            try await finish(&single, input: input, partial: onPartial)
            return single
        }
        guard recipe.strategy != .reject else {
            throw AFMError(code: "context_exceeded", message: "Input is about \(inputTokens) tokens; this recipe handles at most \(budget).")
        }
        if recipe.strategy == .tail {
            var kept = try await tail(input, budget: budget - 40, model: model)
            kept = "(Only the last \(kept.split(separator: "\n").count) lines fit; earlier lines were left out.)\n" + kept
            var r = try await once(kept, partial: onPartial)
            try await finish(&r, input: kept, partial: onPartial)
            r.promptTokens = inputTokens
            return r
        }

        let start = Date()
        let chunks = await Chunker.split(input, maxTokens: budget, model: model)
        var outputs: [String] = []
        // Writing is what costs time (reading 2,000 tokens takes about 3 seconds, writing 300 takes 10).
        // With a length limit the per-section notes only feed a short answer, so cap them.
        let isNotes = (limit != nil || sentenceLimit != nil) && recipe.strategy == .reduce
        let noteOpts: GenOptions? = isNotes ? { var o = opts; o.maxTokens = min(o.maxTokens ?? 300, 300); return o }() : nil
        // Told only "short", a section wrote five long bullets with sub-bullets: say what the notes are for.
        let noteRule = !isNotes ? "" : limit.map { " This is one section of a longer document: write at most \($0) bullets of one short sentence each, with no sub-bullets." }
            ?? sentenceLimit.map { " This is one section of a longer document: write at most \($0) short sentences." } ?? ""
        for (i, c) in chunks.enumerated() {
            onProgress?(Progress(done: i, total: chunks.count, stage: "Chunk \(i + 1) of \(chunks.count)"))
            var text = try await once(c, partial: nil, options: noteOpts, extra: noteRule).text
            if isNotes { text = TextCleanup.droppingUnfinishedLine(text) }
            outputs.append(schema == nil ? TextCleanup.tidy(text, input: c) : text)
        }
        onProgress?(Progress(done: chunks.count, total: chunks.count, stage: "Combining"))

        var final: GenerationResult
        switch recipe.strategy {
        case .merge:
            final = GenerationResult(text: JSONMerge.merge(outputs, schema: schemaText), isJSON: true)
        case .concatenate:
            final = GenerationResult(text: outputs.joined(separator: "\n\n"))
            onPartial?(final.text)
        case .reduce, .reject, .tail:  // reject and tail returned earlier
            var joined = outputs.joined(separator: "\n\n")
            var depth = 0
            while await Chunker.countTokens(joined, model: model) > budget && depth < 3 {
                let parts = await Chunker.split(joined, maxTokens: budget, model: model)
                var next: [String] = []
                for p in parts { next.append(try await once(p, partial: nil).text) }
                joined = next.joined(separator: "\n\n")
                depth += 1
            }
            // The parts are answers about different sections. Asked to "treat it as one document", the
            // model kept one part and dropped the rest (a two-part question lost its second answer).
            if let limit, TextCleanup.bulletCount(joined) > limit {
                // The section notes are already bullets. Combining them first wrote a long answer
                // (19 seconds for the README) that then had to be cut: pick from the notes directly.
                final = GenerationResult(text: joined)
            } else {
                let length = sentenceLimit.map { " Use at most \($0) sentences." } ?? limit.map { " Use at most \($0) bullets." } ?? ""
                let note = "The text below is one result per section of a single long document, in order. Combine them into one answer: keep every detail that answers the request, from every section, skip sections that found nothing, and follow the requested length.\(length)\n\n"
                final = try await once(note + joined, partial: onPartial)
            }
        }
        if recipe.strategy == .concatenate {
            if schema == nil { final.text = TextCleanup.tidy(final.text, input: input) }
        } else {
            try await finish(&final, input: input, partial: onPartial)
        }
        final.seconds = Date().timeIntervalSince(start)
        final.chunks = chunks.count
        final.promptTokens = inputTokens
        final.outputTokens = await Chunker.countTokens(final.text, model: model)
        return final
    }
}

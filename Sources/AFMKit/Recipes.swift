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

    public init(id: String, title: String, summary: String, symbol: String = "wand.and.stars", category: String = "Custom",
                instructions: String, template: String = "{{input}}", params: [RecipeParam] = [], schema: String? = nil,
                temperature: Double? = nil, useCase: UseCaseMode? = nil, permissive: Bool? = nil, long: LongStrategy? = nil, builtin: Bool? = nil,
                transform: RecipeTransform? = nil) {
        self.id = id; self.title = title; self.summary = summary; self.symbol = symbol; self.category = category
        self.instructions = instructions; self.template = template; self.params = params; self.schema = schema
        self.temperature = temperature; self.useCase = useCase; self.permissive = permissive; self.long = long; self.builtin = builtin
        self.transform = transform
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

        func once(_ text: String, partial: (@Sendable (String) -> Void)?) async throws -> GenerationResult {
            var v = values
            v["input"] = text
            let prompt = Recipe.render(recipe.template, v)
            let request = GenerationRequest(prompt: prompt, instructions: instructions, options: opts, config: cfg, schema: schema)
            do {
                return try await AFM.run(request, onPartial: partial)
            } catch where AFMError.isTransientModelError(error) {
                return try await AFM.run(request, onPartial: partial)  // once; it clears up on retry
            }
        }

        let inputTokens = await Chunker.countTokens(input, model: model)
        if inputTokens <= budget {
            var single = try await once(input, partial: onPartial)
            if schema == nil { single.text = TextCleanup.tidy(single.text, input: input) }
            return single
        }
        guard recipe.strategy != .reject else {
            throw AFMError(code: "context_exceeded", message: "Input is about \(inputTokens) tokens; this recipe handles at most \(budget).")
        }
        if recipe.strategy == .tail {
            var kept = try await tail(input, budget: budget - 40, model: model)
            kept = "(Only the last \(kept.split(separator: "\n").count) lines fit; earlier lines were left out.)\n" + kept
            var r = try await once(kept, partial: onPartial)
            if schema == nil { r.text = TextCleanup.tidy(r.text, input: kept) }
            r.promptTokens = inputTokens
            return r
        }

        let start = Date()
        let chunks = await Chunker.split(input, maxTokens: budget, model: model)
        var outputs: [String] = []
        for (i, c) in chunks.enumerated() {
            onProgress?(Progress(done: i, total: chunks.count, stage: "Chunk \(i + 1) of \(chunks.count)"))
            let text = try await once(c, partial: nil).text
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
            let note = "The text below is one result per section of a single long document, in order. Combine them into one answer: keep every detail that answers the request, from every section, skip sections that found nothing, and follow the requested length.\n\n"
            final = try await once(note + joined, partial: onPartial)
        }
        if schema == nil { final.text = TextCleanup.tidy(final.text, input: input) }
        final.seconds = Date().timeIntervalSince(start)
        final.chunks = chunks.count
        final.promptTokens = inputTokens
        final.outputTokens = await Chunker.countTokens(final.text, model: model)
        return final
    }
}

import Foundation

/// Where a recipe's input comes from when you don't give it any. The fetch is plain code that runs the
/// same way every time: the model never writes the query, it only reads what the fetch returns.
///
/// `kind` is `<integration>.<what>`, e.g. `github.search`. Text fields may use `{{param}}`, and
/// `{{date-N}}` for the date N days ago (`{{date-{{days}}}}` works, since parameters are filled first).
public struct RecipeSource: Codable, Sendable, Hashable {
    public var kind: String
    /// A search query (`github.search`, `github.each`).
    public var query: String?
    /// One item to read, such as `{{ref}}` (`github.thread`).
    public var ref: String?
    /// A repository, such as `{{repo}}` (`github.runs`).
    public var repo: String?
    /// A branch filter (`github.runs`).
    public var branch: String?
    /// The most items to list.
    public var limit: Int?
    /// The most items written out for the model (default 15). The rest are counted, not listed,
    /// so the answer fits in one pass: merging chunked lists made the 3B model repeat and invent items.
    public var list: Int?
    /// `oldest` lists the least recently updated first (stale work). Default: newest first.
    public var order: String?
    /// The most items to read in full (`github.each`, `github.runs`).
    public var each: Int?
    /// Include a pull request's diff when reading it (default true for `github.thread`, false for `github.each`).
    public var diff: Bool?

    public init(kind: String, query: String? = nil, ref: String? = nil, repo: String? = nil, branch: String? = nil,
                limit: Int? = nil, list: Int? = nil, order: String? = nil, each: Int? = nil, diff: Bool? = nil) {
        self.kind = kind; self.query = query; self.ref = ref; self.repo = repo; self.branch = branch
        self.limit = limit; self.list = list; self.order = order; self.each = each; self.diff = diff
    }

    /// The integration that resolves this source: the part of `kind` before the first dot.
    public var integrationID: String { String(kind.split(separator: ".", maxSplits: 1).first ?? "") }

    /// Fills `{{param}}`, then `{{date-N}}`, in a source field.
    public static func render(_ s: String, _ values: [String: String], now: Date = Date()) -> String {
        let filled = Recipe.render(s, values)
        guard let re = try? NSRegularExpression(pattern: #"\{\{date-(\d{1,4})\}\}"#) else { return filled }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        var out = filled
        for m in re.matches(in: filled, range: NSRange(filled.startIndex..., in: filled)).reversed() {
            guard let whole = Range(m.range, in: filled), let n = Range(m.range(at: 1), in: filled), let days = Int(filled[n]) else { continue }
            let d = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: now) ?? now
            out.replaceSubrange(whole, with: f.string(from: d))
        }
        return out
    }
}

/// One thing a source found, with a link, so an agent can act on it without asking the model.
public struct SourceItem: Codable, Sendable, Hashable {
    public var ref: String
    public var title: String
    public var url: String
    public var kind: String
    public var updated: String?
    public init(ref: String, title: String, url: String, kind: String, updated: String? = nil) {
        self.ref = ref; self.title = title; self.url = url; self.kind = kind; self.updated = updated
    }
}

/// What a source fetched: the text the model reads and the items behind it.
public struct SourceMaterial: Sendable, Hashable {
    /// Plain text for the model, in the recipe's `{{input}}`.
    public var text: String
    public var items: [SourceItem]
    /// The query or item that was read, for logs and agents.
    public var description: String
    /// Shown instead of a model answer when nothing was found.
    public var emptyMessage: String?
    /// Exact facts, such as counts, put above a prose answer by code so the model never restates them.
    public var headline: String?
    public init(text: String, items: [SourceItem], description: String, emptyMessage: String? = nil, headline: String? = nil) {
        self.text = text; self.items = items; self.description = description; self.emptyMessage = emptyMessage; self.headline = headline
    }
    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public enum RecipeSources {
    /// Runs a recipe's source with these parameter values (defaults filled in for missing ones).
    public static func fetch(_ recipe: Recipe, params: [String: String] = [:], onProgress: (@Sendable (String) -> Void)? = nil) async throws -> SourceMaterial {
        guard let source = recipe.source else {
            throw AFMError(code: "no_source", message: "The recipe \(recipe.id) has no source; give it text instead.")
        }
        var values = recipe.defaults()
        for (k, v) in params where !v.isEmpty { values[k] = v }
        let id = source.integrationID
        guard let integration = IntegrationRegistry.find(id) else {
            throw AFMError(code: "unknown_source", message: "No integration handles the source kind \"\(source.kind)\".",
                           suggestion: "Kinds start with an integration id, such as github.search.")
        }
        try IntegrationRegistry.requireEnabled(id)
        guard let material = try await integration.fetch(source, values: values, onProgress: onProgress) else {
            throw AFMError(code: "unknown_source", message: "\(integration.name) doesn't have a source kind \"\(source.kind)\".")
        }
        return material
    }
}

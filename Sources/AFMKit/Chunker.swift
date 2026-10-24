import Foundation
import FoundationModels

/// Splits long text into pieces that fit the 4K context, on paragraph and sentence boundaries.
public enum Chunker {
    public static func estimate(_ s: String) -> Int { max(1, Int((Double(s.utf8.count) / 3.6).rounded(.up))) }

    public static func countTokens(_ text: String, model: SystemLanguageModel) async -> Int {
        if text.isEmpty { return 0 }
        return (try? await model.tokenCount(for: Prompt(text))) ?? estimate(text)
    }

    public static func split(_ text: String, maxTokens: Int, model: SystemLanguageModel) async -> [String] {
        let total = await countTokens(text, model: model)
        if total <= maxTokens { return [text] }
        let charsPerToken = Double(text.count) / Double(max(total, 1))
        let maxChars = max(400, Int(Double(maxTokens) * charsPerToken * 0.92))
        return split(text, maxChars: maxChars)
    }

    public static func split(_ text: String, maxChars: Int) -> [String] {
        var pieces: [String] = []
        for para in text.components(separatedBy: "\n\n") {
            let p = para.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty { continue }
            if p.count <= maxChars { pieces.append(p); continue }
            var cur = ""
            p.enumerateSubstrings(in: p.startIndex..., options: .bySentences) { sub, _, _, _ in
                guard let s = sub else { return }
                if cur.count + s.count > maxChars, !cur.isEmpty { pieces.append(cur); cur = "" }
                if s.count > maxChars {
                    var rest = Substring(s)
                    while rest.count > maxChars { pieces.append(String(rest.prefix(maxChars))); rest = rest.dropFirst(maxChars) }
                    cur = String(rest)
                } else { cur += s }
            }
            if !cur.isEmpty { pieces.append(cur) }
        }
        var chunks: [String] = []
        var cur = ""
        for p in pieces {
            if cur.isEmpty { cur = p }
            else if cur.count + p.count + 2 <= maxChars { cur += "\n\n" + p }
            else { chunks.append(cur); cur = p }
        }
        if !cur.isEmpty { chunks.append(cur) }
        return chunks.isEmpty ? [String(text.prefix(maxChars))] : chunks
    }
}

/// Merges structured outputs from several chunks: arrays are concatenated (deduplicated),
/// nested objects merged, and scalars keep the first non-empty value.
public enum JSONMerge {
    public static func merge(_ jsons: [String]) -> String {
        let contents = jsons.compactMap { try? GeneratedContent(json: $0) }
        guard var acc = contents.first else { return jsons.first ?? "{}" }
        for c in contents.dropFirst() { acc = merge(acc, c) }
        return JSONRender.pretty(acc)
    }

    static func merge(_ a: GeneratedContent, _ b: GeneratedContent) -> GeneratedContent {
        switch (a.kind, b.kind) {
        case (.structure(let pa, let ka), .structure(let pb, let kb)):
            var props = pa
            var keys = ka
            for k in kb {
                guard let vb = pb[k] else { continue }
                if let va = pa[k] { props[k] = merge(va, vb) } else { props[k] = vb; keys.append(k) }
            }
            return GeneratedContent(kind: .structure(properties: props, orderedKeys: keys))
        case (.array(let xa), .array(let xb)):
            var seen = Set(xa.map { $0.jsonString })
            var out = xa
            for x in xb where !seen.contains(x.jsonString) { out.append(x); seen.insert(x.jsonString) }
            return GeneratedContent(kind: .array(out))
        case (.string(let s), _) where s.trimmingCharacters(in: .whitespaces).isEmpty:
            return b
        case (.null, _):
            return b
        default:
            return a
        }
    }
}

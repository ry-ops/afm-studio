import Foundation
import NaturalLanguage

/// Removes wrapping the on-device model copies from a prompt into a prose answer.
public enum TextCleanup {
    /// The answer without the `"""` delimiters recipes put around their input, and without a
    /// Markdown code fence (```` ```markdown ```` or ```` ```md ````) around the whole answer.
    /// A fence for code, or one inside a longer answer, is kept. Given the `input`, a leading
    /// "Subject:" line the input doesn't have is dropped: rewrites and email replies invent one.
    public static func tidy(_ text: String, input: String? = nil) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("\"\"\"") || t.hasSuffix("\"\"\"") {
            if t.hasPrefix("\"\"\"") { t.removeFirst(3) }
            if t.hasSuffix("\"\"\"") { t.removeLast(3) }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let inner = markdownFenced(t) { t = inner }
        if let input, !input.lowercased().contains("subject:") {
            var lines = t.components(separatedBy: "\n")
            if let first = lines.first, first.lowercased().hasPrefix("subject:") {
                lines.removeFirst()
                t = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return t
    }

    /// The inside of a Markdown fence that wraps all of `text`, or nil.
    static func markdownFenced(_ text: String) -> String? {
        guard text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6 else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 3, let first = lines.first, lines.last == "```" else { return nil }
        let lang = first.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
        guard lang == "markdown" || lang == "md" else { return nil }
        let body = lines.dropFirst().dropLast()
        // Another fence opening inside means the outer one isn't a lone wrapper.
        guard !body.contains(where: { $0.hasPrefix("```") && $0.count > 3 }) else { return nil }
        return body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a line starts a top-level bullet or numbered item.
    static func isBullet(_ line: Substring) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") { return true }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return false }
        let rest = line.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }

    /// How many top-level bullets or numbered items `text` has. Indented sub-bullets don't count.
    public static func bulletCount(_ text: String) -> Int {
        text.split(separator: "\n").filter(isBullet).count
    }

    /// `text` cut after its first `limit` top-level bullets. Lines before the first bullet, and each
    /// kept bullet's indented sub-lines, stay; everything after the last kept bullet goes.
    public static func firstBullets(_ text: String, _ limit: Int) -> String {
        var seen = 0
        var out: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if isBullet(line) {
                seen += 1
                if seen > limit { break }
            } else if seen >= limit, !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The sentences of `text`, as NaturalLanguage finds them.
    static func sentences(_ text: String) -> [String] {
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        return tok.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// How many sentences `text` has.
    public static func sentenceCount(_ text: String) -> Int { sentences(text).count }

    /// The first `limit` sentences of `text`.
    public static func firstSentences(_ text: String, _ limit: Int) -> String {
        sentences(text).prefix(limit).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

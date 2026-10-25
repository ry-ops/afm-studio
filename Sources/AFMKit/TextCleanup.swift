import Foundation

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
}

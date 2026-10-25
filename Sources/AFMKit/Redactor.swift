import Foundation

/// Replaces personal details in text with numbered placeholders such as `[Person 1]`.
///
/// The on-device model only *finds* names and addresses (it returns them as JSON); it never
/// rewrites the text, so nothing else can change. Emails, phone numbers, US Social Security
/// numbers and card numbers are found here with patterns. A name or address the model lists that
/// doesn't appear in the text is ignored.
public enum Redactor {
    public struct Result: Sendable, Equatable {
        public let text: String
        /// How many distinct values were hidden, by kind ("Person", "Email", ...).
        public let counts: [String: Int]
    }

    /// `found` is the model's JSON (`{"people": [...], "addresses": [...]}`); invalid JSON counts as nothing found.
    public static func redact(_ text: String, found: String) -> Result {
        var people: [String] = [], addresses: [String] = []
        if let d = found.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            people = (obj["people"] as? [String]) ?? []
            addresses = (obj["addresses"] as? [String]) ?? []
        }
        return redact(text, people: people, addresses: addresses)
    }

    public static func redact(_ text: String, people: [String], addresses: [String]) -> Result {
        let ns = text as NSString
        var hits: [(range: NSRange, kind: String, key: String)] = []

        func add(_ pattern: String, _ kind: String, options: NSRegularExpression.Options = [], key: (String) -> String = { $0 },
                 accept: (String) -> Bool = { _ in true }) {
            guard let rx = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let s = ns.substring(with: m.range)
                if accept(s) { hits.append((m.range, kind, key(s))) }
            }
        }
        let digits: (String) -> String = { $0.filter(\.isNumber) }

        add(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "Email", key: { $0.lowercased() })
        add(#"(?<![\w-])\d{3}-\d{2}-\d{4}(?![\w-])"#, "ID")
        add(#"(?<![\w-])(?:\d[ -]?){12,18}\d(?![\w-])"#, "Card", key: digits, accept: { luhn(digits($0)) })
        add(#"(?<![\w+])(?:\+\d{1,3}[\s.-]?)?(?:\(\d{3}\)\s?|\d{3}[\s.-])\d{3}[\s.-]\d{4}(?!\w)"#, "Phone", key: digits)
        add(#"(?<![\w])\+\d{1,3}(?:[\s.-]?\d){7,12}(?!\w)"#, "Phone", key: digits)

        for a in Set(addresses.map(clean)) where a.count >= 5 {
            add(NSRegularExpression.escapedPattern(for: a), "Address", options: .caseInsensitive, key: { $0.lowercased() })
        }
        // Full names first; each part of a full name then gets the same placeholder ("Ortiz" alone).
        var partOf: [String: String] = [:]
        let names = Set(people.map(clean)).filter { $0.count >= 2 }
        for name in names {
            add(#"(?<!\w)"# + NSRegularExpression.escapedPattern(for: name) + #"(?!\w)"#, "Person", key: { _ in name })
            let parts = name.split(separator: " ").map(String.init)
            if parts.count > 1 {
                for p in parts where p.count >= 3 && p.first?.isUppercase == true { partOf[p] = partOf[p] ?? name }
            }
        }
        for (part, name) in partOf where !names.contains(part) {
            add(#"(?<!\w)"# + NSRegularExpression.escapedPattern(for: part) + #"(?!\w)"#, "Person", key: { _ in name })
        }

        // Earliest first; at one spot the longest wins; overlapping later hits are dropped.
        hits.sort { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length }
        var numbers: [String: [String: Int]] = [:]
        var out = ""
        var at = 0
        for h in hits where h.range.location >= at {
            out += ns.substring(with: NSRange(location: at, length: h.range.location - at))
            var byKey = numbers[h.kind] ?? [:]
            let n = byKey[h.key] ?? (byKey.count + 1)
            byKey[h.key] = n
            numbers[h.kind] = byKey
            out += "[\(h.kind) \(n)]"
            at = h.range.location + h.range.length
        }
        out += ns.substring(from: at)
        return Result(text: out, counts: numbers.mapValues(\.count))
    }

    static func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }

    static func luhn(_ digits: String) -> Bool {
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, c) in digits.reversed().enumerated() {
            guard var d = c.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }
}

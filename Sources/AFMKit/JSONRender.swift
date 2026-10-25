import Foundation
import FoundationModels

/// Pretty-prints GeneratedContent while keeping the model's key order.
public enum JSONRender {
    public static func pretty(_ c: GeneratedContent, indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch c.kind {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            if n.rounded() == n && abs(n) < 1e15 { return String(Int64(n)) }
            return String(n)
        case .string(let s): return quote(s)
        case .array(let items):
            if items.isEmpty { return "[]" }
            return "[\n" + items.map { inner + pretty($0, indent: indent + 1) }.joined(separator: ",\n") + "\n\(pad)]"
        case .structure(let props, let keys):
            if keys.isEmpty { return "{}" }
            return "{\n" + keys.compactMap { k in props[k].map { "\(inner)\(quote(k)): \(pretty($0, indent: indent + 1))" } }
                .joined(separator: ",\n") + "\n\(pad)}"
        @unknown default:
            return c.jsonString
        }
    }

    public static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    /// Re-indents any JSON text; returns the input unchanged if it isn't valid JSON.
    public static func pretty(json: String) -> String {
        guard let c = try? GeneratedContent(json: json) else { return json }
        return pretty(c)
    }
}

/// Restores schema property order (FoundationModels returns keys in arbitrary order).
extension JSONRender {
    /// Asked for JSON without a schema, the model often wraps it in a Markdown code fence
    /// (three backticks and a `json` tag). This returns the text inside the first fence, or the
    /// text unchanged when there is no fence.
    public static func unfenced(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = t.range(of: "```") else { return t }
        var body = t[open.upperBound...]
        if let nl = body.firstIndex(of: "\n") { body = body[body.index(after: nl)...] } else { return t }
        guard let close = body.range(of: "```") else { return String(body).trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(body[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct SchemaOrder: @unchecked Sendable {
    let root: [String: Any]
    let defs: [String: Any]

    public init?(_ schema: GenerationSchema) {
        guard let d = try? JSONEncoder().encode(schema), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        root = obj
        defs = (obj["$defs"] as? [String: Any]) ?? [:]
    }

    func resolve(_ node: [String: Any]) -> [String: Any] {
        if let ref = node["$ref"] as? String, let name = ref.split(separator: "/").last, let d = defs[String(name)] as? [String: Any] { return resolve(d) }
        return node
    }

    public func apply(_ c: GeneratedContent) -> GeneratedContent { apply(c, node: root) }

    func apply(_ c: GeneratedContent, node raw: [String: Any]) -> GeneratedContent {
        let node = resolve(raw)
        switch c.kind {
        case .structure(let props, let keys):
            var schemaProps = (node["properties"] as? [String: Any]) ?? [:]
            if schemaProps.isEmpty, let any = node["anyOf"] as? [[String: Any]] {
                let ks = Set(keys)
                if let match = any.map(resolve).first(where: { Set((($0["properties"] as? [String: Any]) ?? [:]).keys).isSuperset(of: ks) }) {
                    return apply(c, node: match)
                }
            }
            if schemaProps.isEmpty { schemaProps = [:] }
            let order = (node["x-order"] as? [String]) ?? []
            var ordered = order.filter { props[$0] != nil }
            for k in keys where !ordered.contains(k) { ordered.append(k) }
            var newProps: [String: GeneratedContent] = [:]
            for (k, v) in props { newProps[k] = apply(v, node: (schemaProps[k] as? [String: Any]) ?? [:]) }
            return GeneratedContent(kind: .structure(properties: newProps, orderedKeys: ordered))
        case .array(let items):
            let itemNode = (node["items"] as? [String: Any]) ?? [:]
            return GeneratedContent(kind: .array(items.map { apply($0, node: itemNode) }))
        default:
            return c
        }
    }
}

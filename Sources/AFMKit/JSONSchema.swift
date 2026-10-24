import Foundation
import FoundationModels

/// Converts standard JSON Schema (the subset that maps onto Apple's guided generation)
/// into a `GenerationSchema`. Supports objects, nested objects, arrays, string enums,
/// string patterns, integer/number ranges, booleans, `anyOf`, and local `$ref`/`$defs`.
public enum JSONSchemaConverter {
    public static func schema(fromJSON text: String) throws -> GenerationSchema {
        guard let data = text.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AFMError(code: "schema", message: "The schema must be a JSON object.")
        }
        return try schema(from: obj)
    }

    public static func schema(from obj: [String: Any]) throws -> GenerationSchema {
        var ctx = Context()
        var deps: [DynamicGenerationSchema] = []
        let defs = (obj["$defs"] as? [String: Any]) ?? (obj["definitions"] as? [String: Any]) ?? [:]
        for (name, def) in defs.sorted(by: { $0.key < $1.key }) {
            guard let d = def as? [String: Any] else { continue }
            ctx.reserved.insert(name)
            deps.append(try convert(d, name: name, ctx: &ctx, forceName: true))
        }
        let rootName = (obj["title"] as? String).map(sanitize) ?? "Output"
        let root = try convert(obj, name: rootName, ctx: &ctx, forceName: true)
        return try GenerationSchema(root: root, dependencies: deps + ctx.extra)
    }

    struct Context {
        var used: Set<String> = []
        var reserved: Set<String> = []
        var extra: [DynamicGenerationSchema] = []
        mutating func unique(_ base: String) -> String {
            var n = sanitize(base)
            var i = 2
            while used.contains(n) { n = sanitize(base) + "\(i)"; i += 1 }
            used.insert(n)
            return n
        }
    }

    static func sanitize(_ s: String) -> String {
        let parts = s.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let joined = parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return joined.isEmpty ? "Value" : joined
    }

    static func typeOf(_ obj: [String: Any]) -> String? {
        if let t = obj["type"] as? String { return t }
        if let ts = obj["type"] as? [String] { return ts.first(where: { $0 != "null" }) }
        if obj["properties"] != nil { return "object" }
        if obj["enum"] != nil { return "string" }
        if obj["items"] != nil { return "array" }
        return nil
    }

    static func convert(_ obj: [String: Any], name: String, ctx: inout Context, forceName: Bool = false) throws -> DynamicGenerationSchema {
        if let ref = obj["$ref"] as? String {
            let target = ref.components(separatedBy: "/").last ?? ref
            return DynamicGenerationSchema(referenceTo: target)
        }
        let desc = obj["description"] as? String
        if let any = (obj["anyOf"] ?? obj["oneOf"]) as? [[String: Any]] {
            let n = forceName ? name : ctx.unique(name)
            if forceName { ctx.used.insert(n) }
            let choices = try any.enumerated().map { i, c in
                try convert(c, name: (c["title"] as? String) ?? "\(n)Option\(i + 1)", ctx: &ctx)
            }
            return DynamicGenerationSchema(name: n, description: desc, anyOf: choices)
        }
        switch typeOf(obj) {
        case "object":
            let n = forceName ? name : ctx.unique((obj["title"] as? String) ?? name)
            if forceName { ctx.used.insert(n) }
            let props = (obj["properties"] as? [String: Any]) ?? [:]
            let required = Set((obj["required"] as? [String]) ?? Array(props.keys))
            let order = (obj["x-order"] as? [String]) ?? orderedKeys(obj, props: props)
            var out: [DynamicGenerationSchema.Property] = []
            for key in order {
                guard let p = props[key] as? [String: Any] else { continue }
                let child = try convert(p, name: n + sanitize(key), ctx: &ctx)
                out.append(.init(name: key, description: p["description"] as? String, schema: child, isOptional: !required.contains(key)))
            }
            return DynamicGenerationSchema(name: n, description: desc, properties: out)
        case "array":
            let items = (obj["items"] as? [String: Any]) ?? ["type": "string"]
            let child = try convert(items, name: name + "Item", ctx: &ctx)
            return DynamicGenerationSchema(arrayOf: child,
                                           minimumElements: obj["minItems"] as? Int,
                                           maximumElements: obj["maxItems"] as? Int)
        case "integer":
            var g: [GenerationGuide<Int>] = []
            let lo = (obj["minimum"] as? NSNumber)?.intValue
            let hi = (obj["maximum"] as? NSNumber)?.intValue
            if let lo, let hi { g.append(.range(lo...max(lo, hi))) } else if let lo { g.append(.minimum(lo)) } else if let hi { g.append(.maximum(hi)) }
            return DynamicGenerationSchema(type: Int.self, guides: g)
        case "number":
            var g: [GenerationGuide<Double>] = []
            let lo = (obj["minimum"] as? NSNumber)?.doubleValue
            let hi = (obj["maximum"] as? NSNumber)?.doubleValue
            if let lo, let hi { g.append(.range(lo...max(lo, hi))) } else if let lo { g.append(.minimum(lo)) } else if let hi { g.append(.maximum(hi)) }
            return DynamicGenerationSchema(type: Double.self, guides: g)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        default:
            if let values = obj["enum"] as? [Any] {
                let strings = values.map { "\($0)" }
                let n = ctx.unique(name)
                return DynamicGenerationSchema(name: n, description: desc, anyOf: strings)
            }
            if let c = obj["const"] {
                return DynamicGenerationSchema(type: String.self, guides: [.constant("\(c)")])
            }
            if let pattern = obj["pattern"] as? String, let rx = try? Regex(pattern) {
                return DynamicGenerationSchema(type: String.self, guides: [.pattern(rx)])
            }
            return DynamicGenerationSchema(type: String.self)
        }
    }

    /// JSONSerialization loses key order, so recover it from `required` then the rest alphabetically.
    static func orderedKeys(_ obj: [String: Any], props: [String: Any]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for k in (obj["required"] as? [String]) ?? [] where props[k] != nil && !seen.contains(k) { out.append(k); seen.insert(k) }
        for k in props.keys.sorted() where !seen.contains(k) { out.append(k) }
        return out
    }

    /// Shorthand field specs: `name:string, age:int, tags:[string], mood:enum(happy|sad), score:number?`
    /// A trailing `?` makes a field optional. Types: string, int, number, bool, enum(a|b), [type].
    public static func jsonSchema(fromFields spec: String, title: String = "Fields") throws -> [String: Any] {
        var props: [String: Any] = [:]
        var required: [String] = []
        var order: [String] = []
        for raw in splitTopLevel(spec) {
            let part = raw.trimmingCharacters(in: .whitespaces)
            if part.isEmpty { continue }
            let pieces = part.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            var name = pieces[0]
            var type = pieces.count > 1 ? pieces[1] : "string"
            var optional = false
            if type.hasSuffix("?") { optional = true; type.removeLast() }
            if name.hasSuffix("?") { optional = true; name.removeLast() }
            guard !name.isEmpty else { throw AFMError(code: "schema", message: "Empty field name in \"\(part)\".") }
            props[name] = try fieldType(type)
            order.append(name)
            if !optional { required.append(name) }
        }
        if props.isEmpty { throw AFMError(code: "schema", message: "No fields given.") }
        return ["type": "object", "title": title, "properties": props, "required": required, "x-order": order]
    }

    static func fieldType(_ t: String) throws -> [String: Any] {
        let s = t.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("[") && s.hasSuffix("]") { return ["type": "array", "items": try fieldType(String(s.dropFirst().dropLast()))] }
        if s.hasPrefix("enum(") && s.hasSuffix(")") {
            let vals = t.trimmingCharacters(in: .whitespaces).dropFirst(5).dropLast().split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            return ["type": "string", "enum": vals]
        }
        switch s {
        case "string", "str", "text", "": return ["type": "string"]
        case "int", "integer": return ["type": "integer"]
        case "number", "float", "double": return ["type": "number"]
        case "bool", "boolean": return ["type": "boolean"]
        default: throw AFMError(code: "schema", message: "Unknown field type \"\(t)\".", suggestion: "Use string, int, number, bool, enum(a|b) or [type].")
        }
    }

    static func splitTopLevel(_ s: String) -> [String] {
        var out: [String] = []; var cur = ""; var depth = 0
        for ch in s {
            if ch == "(" || ch == "[" { depth += 1 }
            if ch == ")" || ch == "]" { depth -= 1 }
            if (ch == "," || ch == "\n") && depth == 0 { out.append(cur); cur = "" } else { cur.append(ch) }
        }
        out.append(cur)
        return out
    }

    public static func jsonText(_ obj: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
}

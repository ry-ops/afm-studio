import Foundation

/// A small, safe expression evaluator (no NSExpression, so bad input can't crash the process).
public enum Calculator {
    public struct CalcError: LocalizedError { public let errorDescription: String? }

    public static func evaluate(_ text: String) throws -> Double {
        var t = text.lowercased().replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
        t = t.replacingOccurrences(of: "\\b(times|multiplied by)\\b", with: "*", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\b(divided by|over)\\b", with: "/", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\bplus\\b", with: "+", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\bminus\\b", with: "-", options: .regularExpression)
        // "17.5% of 2340" and "15%" mean percentages; "a % b" stays modulo.
        t = t.replacingOccurrences(of: "([0-9.]+)\\s*%\\s*of\\b", with: "($1/100)*", options: .regularExpression)
        t = t.replacingOccurrences(of: "([0-9.]+)\\s*%(?!\\s*[0-9(.])", with: "($1/100)", options: .regularExpression)
        t = t.replacingOccurrences(of: "[$€£]", with: "", options: .regularExpression)
        var p = Parser(chars: Array(t))
        let v = try p.expression()
        p.skip()
        if p.i < p.chars.count { throw CalcError(errorDescription: "Unexpected \"\(p.chars[p.i])\"") }
        if !v.isFinite { throw CalcError(errorDescription: "Result is not a finite number") }
        return v
    }

    public static func format(_ v: Double) -> String {
        if v.rounded() == v && abs(v) < 1e15 { return String(Int64(v)) }
        let s = String(format: "%.10g", v)
        return s
    }

    struct Parser {
        let chars: [Character]
        var i = 0
        init(chars: [Character]) { self.chars = chars }

        mutating func skip() { while i < chars.count && chars[i].isWhitespace { i += 1 } }
        mutating func eat(_ c: Character) -> Bool { skip(); if i < chars.count && chars[i] == c { i += 1; return true }; return false }

        mutating func expression() throws -> Double {
            var v = try term()
            while true {
                if eat("+") { v += try term() } else if eat("-") { v -= try term() } else { return v }
            }
        }
        mutating func term() throws -> Double {
            var v = try power()
            while true {
                if eat("*") { v *= try power() }
                else if eat("/") { let d = try power(); if d == 0 { throw CalcError(errorDescription: "Division by zero") }; v /= d }
                else if eat("%") { let d = try power(); if d == 0 { throw CalcError(errorDescription: "Modulo by zero") }; v = v.truncatingRemainder(dividingBy: d) }
                else { return v }
            }
        }
        mutating func power() throws -> Double {
            let b = try unary()
            if eat("^") { return pow(b, try power()) }
            return b
        }
        mutating func unary() throws -> Double {
            if eat("-") { return -(try unary()) }
            if eat("+") { return try unary() }
            return try primary()
        }
        mutating func primary() throws -> Double {
            skip()
            if eat("(") { let v = try expression(); guard eat(")") else { throw CalcError(errorDescription: "Missing )") }; return v }
            guard i < chars.count else { throw CalcError(errorDescription: "Unexpected end of expression") }
            if chars[i].isNumber || chars[i] == "." {
                var s = ""
                while i < chars.count && (chars[i].isNumber || chars[i] == "." || chars[i] == "_" || chars[i] == ",") { if chars[i] != "_" && chars[i] != "," { s.append(chars[i]) }; i += 1 }
                if i < chars.count && chars[i] == "e" && i + 1 < chars.count && (chars[i + 1].isNumber || chars[i + 1] == "-" || chars[i + 1] == "+") {
                    s.append("e"); i += 1
                    if chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
                    while i < chars.count && chars[i].isNumber { s.append(chars[i]); i += 1 }
                }
                guard let v = Double(s) else { throw CalcError(errorDescription: "Bad number \(s)") }
                return v
            }
            if chars[i].isLetter {
                var name = ""
                while i < chars.count && chars[i].isLetter { name.append(chars[i]); i += 1 }
                switch name {
                case "pi": return .pi
                case "e": return M_E
                default: break
                }
                guard eat("(") else { throw CalcError(errorDescription: "Unknown name \(name)") }
                let a = try expression()
                guard eat(")") else { throw CalcError(errorDescription: "Missing )") }
                switch name {
                case "sqrt": return sqrt(a)
                case "sin": return sin(a)
                case "cos": return cos(a)
                case "tan": return tan(a)
                case "log": return log10(a)
                case "ln": return log(a)
                case "abs": return abs(a)
                case "round": return a.rounded()
                case "floor": return floor(a)
                case "ceil": return ceil(a)
                case "exp": return exp(a)
                default: throw CalcError(errorDescription: "Unknown function \(name)")
                }
            }
            throw CalcError(errorDescription: "Unexpected \"\(chars[i])\"")
        }
    }
}

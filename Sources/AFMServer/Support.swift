import Foundation
import AFMKit

/// Serialises model work. The on-device model handles one request at a time per process best.
public actor ModelGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init() {}

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    public func serial<T>(_ op: () async throws -> T) async throws -> T {
        await acquire()
        do { let r = try await op(); release(); return r } catch { release(); throw error }
    }
}

enum JSONValue {
    static func encode(_ obj: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
    }
    static func string(_ obj: Any) -> String { String(decoding: encode(obj), as: UTF8.self) }
    static func parse(_ text: String) -> Any? {
        guard let d = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }
}

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? {
        if let s = self[k] as? String { return s }
        if let n = self[k] as? NSNumber { return n.stringValue }
        return nil
    }
    func double(_ k: String) -> Double? { (self[k] as? NSNumber)?.doubleValue ?? (self[k] as? String).flatMap(Double.init) }
    func int(_ k: String) -> Int? { (self[k] as? NSNumber)?.intValue ?? (self[k] as? String).flatMap(Int.init) }
    func bool(_ k: String) -> Bool? {
        if let b = self[k] as? Bool { return b }
        if let s = self[k] as? String { return ["true", "1", "yes"].contains(s.lowercased()) }
        return nil
    }
}

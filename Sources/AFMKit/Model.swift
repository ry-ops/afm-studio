import Foundation
import FoundationModels

public enum GuardrailMode: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    case standard, permissive
    public var id: String { rawValue }
    public var title: String { self == .standard ? "Standard" : "Permissive" }
    public var detail: String {
        self == .standard
            ? "Apple's default safety guardrails."
            : "Looser guardrails for transforming text you supply (summaries, rewrites, tagging). Fewer false positives."
    }
}

public enum UseCaseMode: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    case general, tagging
    public var id: String { rawValue }
    public var title: String { self == .general ? "General" : "Content tagging" }
}

/// Which on-device model to talk to and how.
public struct ModelConfig: Codable, Sendable, Equatable, Hashable {
    public var guardrails: GuardrailMode
    public var useCase: UseCaseMode
    /// Optional path to a custom `.fmadapter` trained with Apple's adapter toolkit.
    public var adapterPath: String?

    public init(guardrails: GuardrailMode = .standard, useCase: UseCaseMode = .general, adapterPath: String? = nil) {
        self.guardrails = guardrails
        self.useCase = useCase
        self.adapterPath = adapterPath
    }

    public static let `default` = ModelConfig()

    public func makeModel() throws -> SystemLanguageModel {
        let g: SystemLanguageModel.Guardrails = guardrails == .permissive ? .permissiveContentTransformations : .default
        if let p = adapterPath, !p.isEmpty {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            let adapter = try SystemLanguageModel.Adapter(fileURL: url)
            return SystemLanguageModel(adapter: adapter, guardrails: g)
        }
        if useCase == .general && guardrails == .standard { return .default }
        return SystemLanguageModel(useCase: useCase == .tagging ? .contentTagging : .general, guardrails: g)
    }
}

/// What a `.fmadapter` says about itself. Adapters are tied to one exact system model version,
/// so an adapter that loads on one macOS release may fail on the next.
public struct AdapterInfo: Sendable, Equatable {
    public var path: String
    /// Metadata the adapter's author wrote at export time, flattened to strings and sorted by key.
    public var metadata: [(key: String, value: String)]

    public static func == (a: AdapterInfo, b: AdapterInfo) -> Bool {
        a.path == b.path && a.metadata.map(\.key) == b.metadata.map(\.key) && a.metadata.map(\.value) == b.metadata.map(\.value)
    }

    public static func load(path: String) throws -> AdapterInfo {
        let expanded = (path as NSString).expandingTildeInPath
        do {
            let adapter = try SystemLanguageModel.Adapter(fileURL: URL(fileURLWithPath: expanded))
            let pairs = adapter.creatorDefinedMetadata.map { (key: $0.key, value: Self.flatten($0.value)) }.sorted { $0.key < $1.key }
            return AdapterInfo(path: expanded, metadata: pairs)
        } catch {
            throw AFMError.from(error)
        }
    }

    static func flatten(_ v: Any) -> String {
        if let s = v as? String { return s }
        if JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) {
            return String(decoding: d, as: UTF8.self)
        }
        return "\(v)"
    }

    /// One line per metadata entry, ready to print.
    public var summary: String {
        metadata.isEmpty ? "No metadata." : metadata.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }
}

public struct ModelStatus: Codable, Sendable, Equatable {
    public var available: Bool
    public var reason: String?
    public var guidance: String?
    public var contextSize: Int
    public var languages: [String]
    public var taggingAvailable: Bool
    public var osVersion: String

    public static func current() -> ModelStatus {
        let m = SystemLanguageModel.default
        var reason: String? = nil
        var guidance: String? = nil
        var ok = false
        switch m.availability {
        case .available:
            ok = true
        case .unavailable(let r):
            switch r {
            case .deviceNotEligible:
                reason = "deviceNotEligible"
                guidance = "This Mac can't run Apple Intelligence. It needs Apple silicon."
            case .appleIntelligenceNotEnabled:
                reason = "appleIntelligenceNotEnabled"
                guidance = "Turn on Apple Intelligence in System Settings > Apple Intelligence & Siri."
            case .modelNotReady:
                reason = "modelNotReady"
                guidance = "The model is still downloading or preparing. Try again in a few minutes."
            @unknown default:
                reason = "unknown"
                guidance = "The model is unavailable for an unknown reason."
            }
        }
        let langs = Set(m.supportedLanguages.map { $0.minimalIdentifier }).sorted()
        return ModelStatus(
            available: ok,
            reason: reason,
            guidance: guidance,
            contextSize: m.contextSize,
            languages: langs,
            taggingAvailable: SystemLanguageModel(useCase: .contentTagging).isAvailable,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    public static func languageName(_ id: String) -> String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }
}

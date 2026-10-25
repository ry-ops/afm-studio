import Foundation
import FoundationModels

/// One error type with a stable code, a readable message and a fix hint.
public struct AFMError: LocalizedError, Sendable, Equatable {
    public let code: String
    public let message: String
    public let suggestion: String?

    public init(code: String, message: String, suggestion: String? = nil) {
        self.code = code
        self.message = message
        self.suggestion = suggestion
    }

    public var errorDescription: String? { message }
    public var recoverySuggestion: String? { suggestion }
    public var fullDescription: String {
        guard let suggestion else { return message }
        let m = message.trimmingCharacters(in: .whitespaces)
        let end = m.last.map { ".!?:".contains($0) } ?? true
        return (end ? m : m + ".") + " " + suggestion
    }

    public static func unavailable(_ status: ModelStatus) -> AFMError {
        AFMError(code: status.reason ?? "unavailable", message: "The on-device model is unavailable.", suggestion: status.guidance)
    }

    public static func from(_ error: Error) -> AFMError {
        if let e = error as? AFMError { return e }
        if ProcessInfo.processInfo.environment["AFM_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("[afm debug] \(String(reflecting: error))\n".utf8))
        }
        if let g = error as? LanguageModelSession.GenerationError {
            let desc = g.errorDescription ?? "\(g)"
            switch g {
            case .exceededContextWindowSize:
                return AFMError(code: "context_exceeded", message: "The input is larger than the model's context window.",
                                suggestion: "Shorten the input, or use a recipe in long mode so it is split into chunks.")
            case .assetsUnavailable:
                return AFMError(code: "assets_unavailable", message: "Model assets are unavailable right now.", suggestion: g.recoverySuggestion)
            case .guardrailViolation:
                return AFMError(code: "guardrail", message: "Apple's safety guardrails blocked this request.",
                                suggestion: "If you are transforming your own text, retry with permissive guardrails.")
            case .unsupportedGuide:
                return AFMError(code: "unsupported_guide", message: "The schema uses a constraint the model can't follow.", suggestion: desc)
            case .unsupportedLanguageOrLocale:
                return AFMError(code: "unsupported_language", message: "That language or locale isn't supported.", suggestion: "Run `afm status` to see supported languages.")
            case .decodingFailure:
                return AFMError(code: "decoding_failure", message: "The model's output didn't match the schema.", suggestion: "Simplify the schema or retry.")
            case .rateLimited:
                return AFMError(code: "rate_limited", message: "The system rate-limited the request.", suggestion: "Wait a moment and retry. Background processes are limited more strictly.")
            case .concurrentRequests:
                return AFMError(code: "concurrent", message: "This session is already answering a request.", suggestion: nil)
            case .refusal:
                return AFMError(code: "refusal", message: "The model declined to answer.", suggestion: nil)
            @unknown default:
                return AFMError(code: "generation", message: desc, suggestion: g.recoverySuggestion)
            }
        }
        if let t = error as? LanguageModelSession.ToolCallError {
            return AFMError(code: "tool_error", message: "Tool \(t.tool.name) failed: \(t.underlyingError.localizedDescription)")
        }
        if let a = error as? SystemLanguageModel.Adapter.AssetError {
            let versionHint = "Each adapter works with one exact version of the system model. Retrain it with the adapter toolkit that matches this macOS release."
            switch a {
            case .compatibleAdapterNotFound:
                return AFMError(code: "adapter_incompatible", message: a.errorDescription ?? "No compatible adapter was found.", suggestion: versionHint)
            case .invalidAsset:
                return AFMError(code: "adapter", message: a.errorDescription ?? "\(a)",
                                suggestion: (a.recoverySuggestion.map { $0 + " " } ?? "") + versionHint)
            default:
                return AFMError(code: "adapter", message: a.errorDescription ?? "\(a)", suggestion: a.recoverySuggestion)
            }
        }
        if let s = error as? GenerationSchema.SchemaError {
            return AFMError(code: "schema", message: s.errorDescription ?? "\(s)", suggestion: s.recoverySuggestion)
        }
        return AFMError(code: "error", message: (error as NSError).localizedDescription)
    }

    /// Like `from(_:)`, but for a refusal it also asks the model why it declined.
    /// The framework generates that explanation on demand, so this costs one more short model call.
    /// It gives up after `timeout` seconds and falls back to the plain message.
    public static func resolve(_ error: Error, timeout: Double = 10) async -> AFMError {
        guard case LanguageModelSession.GenerationError.refusal(let refusal, _) = error else { return from(error) }
        let explanation: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await refusal.explanation.content }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let text = explanation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return AFMError(code: "refusal", message: "The model declined to answer.", suggestion: text.isEmpty ? nil : "Its explanation: \(text)")
    }
}

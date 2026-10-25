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
            FileHandle.standardError.write(Data("[afm debug] \(type(of: error)): \(String(reflecting: error))\n".utf8))
        }
        if let g = error as? LanguageModelError {
            let desc = g.errorDescription ?? "\(g)"
            switch g {
            case .contextSizeExceeded(let c):
                return AFMError(code: "context_exceeded", message: "The input is \(c.tokenCount) tokens, larger than the model's \(c.contextSize)-token context window.",
                                suggestion: "Shorten the input, or use a recipe in long mode so it is split into chunks.")
            case .guardrailViolation:
                return AFMError(code: "guardrail", message: "Apple's safety guardrails blocked this request.",
                                suggestion: "If you are transforming your own text, retry with permissive guardrails.")
            case .unsupportedGenerationGuide:
                return AFMError(code: "unsupported_guide", message: "The schema uses a constraint the model can't follow.", suggestion: desc)
            case .unsupportedLanguageOrLocale:
                return AFMError(code: "unsupported_language", message: "That language or locale isn't supported.", suggestion: "Run `afm status` to see supported languages.")
            case .rateLimited(let r):
                let wait = r.resetDate.map { d in "Retry after \(d.formatted(date: .omitted, time: .standard))." } ?? "Wait a moment and retry."
                return AFMError(code: "rate_limited", message: "The system rate-limited the request.", suggestion: wait + " Background processes are limited more strictly.")
            case .refusal:
                return AFMError(code: "refusal", message: "The model declined to answer.", suggestion: nil)
            case .timeout:
                return AFMError(code: "timeout", message: "The model took too long to answer.", suggestion: "Retry, or ask for a shorter response.")
            case .unsupportedCapability, .unsupportedTranscriptContent:
                return AFMError(code: "unsupported", message: desc, suggestion: nil)
            @unknown default:
                return AFMError(code: "generation", message: desc, suggestion: nil)
            }
        }
        if let m = error as? SystemLanguageModel.Error {
            switch m {
            case .assetsUnavailable:
                return AFMError(code: "assets_unavailable", message: "Model assets are unavailable right now.",
                                suggestion: "Check that Apple Intelligence is on and finished downloading, then retry.")
            @unknown default:
                return AFMError(code: "model", message: m.errorDescription ?? "\(m)", suggestion: nil)
            }
        }
        if let e = error as? LanguageModelSession.Error {
            switch e {
            case .concurrentRequests:
                return AFMError(code: "concurrent", message: "This session is already answering a request.", suggestion: nil)
            default:
                return AFMError(code: "session", message: e.errorDescription ?? "\(e)", suggestion: nil)
            }
        }
        if error is GeneratedContent.ParsingError {
            return AFMError(code: "decoding_failure", message: "The model's output didn't match the schema.", suggestion: "Simplify the schema or retry.")
        }
        if let t = error as? LanguageModelSession.ToolCallError {
            return AFMError(code: "tool_error", message: "Tool \(t.tool.name) failed: \(t.underlyingError.localizedDescription)")
        }
        if let s = error as? GenerationSchema.SchemaError {
            return AFMError(code: "schema", message: s.errorDescription ?? "\(s)", suggestion: s.recoverySuggestion)
        }
        if isTransientModelError(error) {
            return AFMError(code: "model_internal", message: "The on-device model hit an internal error.",
                            suggestion: "Retry. It tends to happen under sustained load and clears up on its own.")
        }
        return AFMError(code: "error", message: (error as NSError).localizedDescription)
    }

    /// The framework's unnamed internal failure (`LanguageModelError error -1`), which arrives as a
    /// plain NSError rather than a `LanguageModelError` case. Seen now and then during long runs of
    /// back-to-back requests; the same request then succeeds.
    public static func isTransientModelError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain.hasSuffix("LanguageModelError") && ns.code == -1
    }

    /// Like `from(_:)`, but for a refusal it also asks the model why it declined.
    /// The framework generates that explanation on demand, so this costs one more short model call.
    /// It gives up after `timeout` seconds and falls back to the plain message.
    public static func resolve(_ error: Error, timeout: Double = 10) async -> AFMError {
        guard case LanguageModelError.refusal(let refusal) = error else { return from(error) }
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

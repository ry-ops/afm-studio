import Foundation
import FoundationModels

public enum SamplingKind: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    case automatic, greedy, topK, topP
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .greedy: "Greedy (deterministic)"
        case .topK: "Top-K"
        case .topP: "Top-P (nucleus)"
        }
    }
}

/// Generation knobs, serialisable so the GUI, CLI, MCP and HTTP layers share them.
public struct GenOptions: Codable, Sendable, Equatable, Hashable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var sampling: SamplingKind
    public var topK: Int
    public var topP: Double
    public var seed: UInt64?

    public init(temperature: Double? = nil, maxTokens: Int? = nil, sampling: SamplingKind = .automatic,
                topK: Int = 40, topP: Double = 0.9, seed: UInt64? = nil) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.sampling = sampling
        self.topK = topK
        self.topP = topP
        self.seed = seed
    }

    public static let `default` = GenOptions()

    public var generationOptions: GenerationOptions {
        let mode: GenerationOptions.SamplingMode?
        switch sampling {
        case .automatic: mode = nil
        case .greedy: mode = .greedy
        case .topK: mode = .random(top: max(1, topK), seed: seed)
        case .topP: mode = .random(probabilityThreshold: min(max(topP, 0.01), 1.0), seed: seed)
        }
        return GenerationOptions(samplingMode: mode, temperature: temperature, maximumResponseTokens: maxTokens)
    }
}

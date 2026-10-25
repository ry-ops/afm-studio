import Foundation
import FoundationModels

public struct BenchRun: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID = UUID()
    public var round: Int
    public var task: String
    public var firstToken: Double
    public var total: Double
    public var outputTokens: Int
    /// 0 when the reply was too short to time.
    public var tokensPerSecond: Double

    public init(round: Int, task: String, firstToken: Double, total: Double, outputTokens: Int, tokensPerSecond: Double) {
        self.round = round; self.task = task; self.firstToken = firstToken; self.total = total
        self.outputTokens = outputTokens; self.tokensPerSecond = tokensPerSecond
    }
}

/// Measures time-to-first-token and decode speed on a fixed set of tasks with greedy sampling.
public enum Bench {
    public static let tasks: [(name: String, prompt: String)] = [
        ("Short answer", "What is the capital of Japan? Answer in one word."),
        ("Paragraph", "Explain how a heat pump works in one paragraph."),
        ("List", "List eight practical ideas for a weekend home-lab project, one per line."),
        ("Rewrite", "Rewrite this in a formal tone: hey can u send me the report by tmrw, thx"),
        ("Reasoning", "A train leaves at 3:40 PM and the trip takes 2 hours 35 minutes. When does it arrive? Explain briefly."),
    ]

    public static func run(rounds: Int = 1, config: ModelConfig = .default, onRun: (@Sendable (BenchRun) -> Void)? = nil) async throws -> [BenchRun] {
        var out: [BenchRun] = []
        for r in 1...max(1, rounds) {
            for t in tasks {
                let res = try await AFM.run(GenerationRequest(prompt: t.prompt, options: GenOptions(maxTokens: 300, sampling: .greedy), config: config), onPartial: { _ in })
                let run = BenchRun(round: r, task: t.name, firstToken: res.firstTokenSeconds ?? res.seconds, total: res.seconds,
                                   outputTokens: res.outputTokens ?? 0, tokensPerSecond: res.tokensPerSecond ?? 0)
                out.append(run)
                onRun?(run)
            }
        }
        return out
    }

    /// Overall decode speed: every timed token over all the time spent generating them. Averaging
    /// per-run rates instead would let one short, fast reply dominate.
    public static func decodeSpeed(_ runs: [BenchRun]) -> Double? {
        let timed = runs.filter { $0.tokensPerSecond > 0 }
        let tokens = timed.map { Double($0.outputTokens - 1) }.reduce(0, +)
        let time = timed.map { $0.total - $0.firstToken }.reduce(0, +)
        return time > 0 ? tokens / time : nil
    }

    public static func format(_ tokensPerSecond: Double) -> String {
        tokensPerSecond > 0 ? String(format: "%.1f", tokensPerSecond) : "–"
    }
}

import Foundation

/// Prompts for reading a chat message that's longer than the model's context. The message is split into
/// parts, the model takes notes on each part with the person's request in mind, and the answer comes from
/// the notes. The request is usually at the start or the end, so both ends travel with every part.
public enum LongMessage {
    /// Tokens per part: room for the instructions, both ends of the message and the notes.
    public static let chunkTokens = 2600
    /// Characters kept from each end of the message.
    public static let endChars = 300
    /// The most notes the model writes per part. Short notes let every part reach the answer without a lossy combining pass.
    public static let notesTokens = 260

    public static let notesInstructions = "You take faithful, compact notes on part of a longer text. Never invent anything that isn't in the text."

    /// The start and the end of the message. The end is empty when the message is short enough for the start to cover it.
    public static func ends(_ text: String) -> (head: String, tail: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > endChars * 2 else { return (t, "") }
        return (String(t.prefix(endChars)), String(t.suffix(endChars)))
    }

    /// Asks what the person wants, from both ends of the message. The answer replaces the raw ends in later
    /// prompts: quoting the end made the model summarize only the end.
    public static func requestPrompt(head: String, tail: String) -> String {
        var s = "Someone sent a long message. It begins:\n«\(head)»"
        if !tail.isEmpty { s += "\nIt ends:\n«\(tail)»" }
        return s + "\n\nIn one sentence, what are they asking for? If they only pasted text with no request, say they want its main points. Reply with the sentence only."
    }

    public static func notesPrompt(part: String, index: Int, count: Int, request: String) -> String {
        "Someone sent a message too long to read at once. Their request: \(request)\n\nThis is part \(index + 1) of \(count):\n\n\(part)\n\n"
            + "In at most 120 words, write notes on this part that will help answer their request. Keep names, numbers, dates, decisions and anything they asked about. Leave out filler."
    }

    public static func combinePrompt(_ notes: String, request: String) -> String {
        "Someone sent a message too long to read at once. Their request: \(request)\n\nThese are notes on consecutive parts of it:\n\n\(notes)\n\n"
            + "Combine them into shorter notes, in order. Keep at least one point from every part, and what matters most for their request."
    }

    public static func join(_ notes: [String]) -> String {
        notes.enumerated().map { "Part \($0.offset + 1):\n\($0.element.trimmingCharacters(in: .whitespacesAndNewlines))" }.joined(separator: "\n\n")
    }

    public static func finalPrompt(request: String, notes: String) -> String {
        "My request: \(request)\n\nMy message was too long for you to read at once, so it was read in parts and turned into notes. Notes on each part, in order:\n\n\(notes)\n\n"
            + "Answer my request from these notes alone, without calling tools: the notes are the text I sent. Cover the whole message, not just the start or the end."
    }
}

/// Where reading a long message has got to, for a progress display.
public struct LongReadProgress: Sendable, Equatable {
    public enum Stage: String, Sendable { case request, reading, combining, answering }
    public var tokens: Int
    public var parts: Int
    /// Parts read so far.
    public var done: Int
    public var stage: Stage
    public var started: Date
    /// When this report was made. `remaining` counts down from here.
    public var updated: Date
    /// Estimated seconds left, including the answer.
    public var remaining: TimeInterval

    public init(tokens: Int, parts: Int, done: Int, stage: Stage, started: Date, updated: Date = Date(), remaining: TimeInterval) {
        self.tokens = tokens; self.parts = parts; self.done = done; self.stage = stage
        self.started = started; self.updated = updated; self.remaining = remaining
    }

    /// 0 to 1. Each part counts as one step, and writing the answer as one more.
    public var fraction: Double {
        switch stage {
        case .request: 0
        case .reading: Double(done) / Double(parts + 1)
        case .combining, .answering: Double(parts) / Double(parts + 1)
        }
    }

    /// Seconds left at `now`, counting down from the last report but never below zero.
    public func remaining(at now: Date) -> TimeInterval { max(0, remaining - now.timeIntervalSince(updated)) }

    /// One line for the current step, e.g. "Reading part 4 of 9".
    public var status: String {
        switch stage {
        case .request: "Working out what you're asking"
        case .reading: "Reading part \(min(done + 1, parts)) of \(parts)"
        case .combining: "Combining notes"
        case .answering: "Writing the answer"
        }
    }
}

extension LongMessage {
    /// Seconds per part before any part is measured. Measured on this project's Mac mini: 11 to 15 seconds.
    public static let defaultPartSeconds: TimeInterval = 13
    /// Seconds to work out the request, and to write the final answer (measured: about 3 and 35).
    public static let requestSeconds: TimeInterval = 3
    public static let answerSeconds: TimeInterval = 30

    /// Estimated seconds left with `done` of `parts` read, using the measured average when there is one.
    public static func remaining(parts: Int, done: Int, measuredPerPart: TimeInterval?, includeRequest: Bool = false) -> TimeInterval {
        Double(max(0, parts - done)) * (measuredPerPart ?? defaultPartSeconds) + answerSeconds + (includeRequest ? requestSeconds : 0)
    }

    /// A rough duration for a person: "under a minute", "about a minute", "about 3 minutes".
    public static func roughly(_ seconds: TimeInterval) -> String {
        if seconds < 45 { return "under a minute" }
        if seconds < 90 { return "about a minute" }
        return "about \(Int((seconds / 60).rounded())) minutes"
    }

    /// An exact duration: "48 s", "2 min 47 s".
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s) s" : "\(s / 60) min \(s % 60) s"
    }

    /// The line saved after the answer, so the person knows the whole message was read.
    public static func summary(tokens: Int, parts: Int, seconds: TimeInterval) -> String {
        "Read this \(tokens.formatted())-token message in \(parts) parts in \(clock(seconds))."
    }
}

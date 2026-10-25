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

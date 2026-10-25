import Foundation
import FoundationModels

public struct ChatMessage: Codable, Identifiable, Sendable, Equatable, Hashable {
    public enum Role: String, Codable, Sendable { case user, assistant, notice }
    public var id: UUID
    public var role: Role
    public var text: String
    public var date: Date
    public var seconds: Double?
    public var tokens: Int?
    public var tools: [String]
    /// What the model sees for this message when it differs from `text`: notes standing in for a message
    /// too long for the context. `text` keeps what the person wrote.
    public var contextText: String?

    public init(id: UUID = UUID(), role: Role, text: String, date: Date = Date(), seconds: Double? = nil, tokens: Int? = nil, tools: [String] = []) {
        self.id = id; self.role = role; self.text = text; self.date = date; self.seconds = seconds; self.tokens = tokens; self.tools = tools
    }

    /// The text the model sees.
    public var modelText: String { contextText ?? text }
}

/// A saved conversation. Shared by the app, the CLI (`afm chat`) and the MCP server (`afm_chat`).
public struct ChatSessionRecord: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id: String
    public var title: String
    public var created: Date
    public var updated: Date
    public var instructions: String
    public var config: ModelConfig
    public var options: GenOptions
    public var tools: [ToolKind]
    public var messages: [ChatMessage]
    /// Summary of messages before `contextStart`, carried into the model's instructions.
    public var summary: String?
    public var contextStart: Int
    public var source: String
    /// Integration ids (e.g. "github") whose tools the model may call in this chat.
    public var integrations: [String]?

    public init(id: String = UUID().uuidString, title: String = "New chat", instructions: String = ChatSessionRecord.defaultInstructions,
                config: ModelConfig = .default, options: GenOptions = .default, tools: [ToolKind] = ToolKind.safeDefaults, source: String = "studio",
                integrations: [String]? = nil) {
        self.id = id; self.title = title; self.created = Date(); self.updated = Date(); self.instructions = instructions
        self.config = config; self.options = options; self.tools = tools; self.messages = []; self.summary = nil; self.contextStart = 0; self.source = source
        self.integrations = integrations
    }

    /// Integrations a new chat starts with: every one whose "Tools in chat" switch is on. Without this, a new
    /// chat had none, and the model answered that it couldn't see GitHub.
    public static var defaultIntegrations: [String]? {
        let ids = IntegrationRegistry.chatEnabled.map(\.id)
        return ids.isEmpty ? nil : ids
    }

    public static let defaultInstructions = "You are a helpful, accurate assistant running privately on this Mac. Be concise. Use the calculator for any arithmetic and the date tool for the current date or time. Only call a tool when the question needs it. If you don't know something, say so."
}

public final class SessionStore: @unchecked Sendable {
    public static let shared = SessionStore()
    private let lock = NSLock()
    public init() {}

    func url(_ id: String) -> URL { AFMPaths.sessions.appendingPathComponent(Self.safe(id) + ".json") }

    public static func safe(_ id: String) -> String {
        id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "-" }.joined()
    }

    public func list() -> [ChatSessionRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: AFMPaths.sessions, includingPropertiesForKeys: nil)) ?? []
        let dec = Self.decoder
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(ChatSessionRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }

    public func load(_ id: String) -> ChatSessionRecord? {
        guard let d = try? Data(contentsOf: url(id)) else { return nil }
        return try? Self.decoder.decode(ChatSessionRecord.self, from: d)
    }

    public func save(_ r: ChatSessionRecord) {
        lock.lock(); defer { lock.unlock() }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(r).write(to: url(r.id), options: .atomic)
    }

    public func delete(_ id: String) { try? FileManager.default.removeItem(at: url(id)) }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// A live conversation with the on-device model. Survives restarts (it rebuilds the model's
/// transcript from saved messages) and compacts itself when the 4K context fills up.
public final class ChatEngine: @unchecked Sendable {
    public private(set) var record: ChatSessionRecord
    private var session: LanguageModelSession?
    private var model: SystemLanguageModel?
    private let store: SessionStore
    public var persist: Bool
    /// When false, file and network tools are left out of the session even if the saved chat has them on.
    /// The MCP server sets this, so a chat reached from Claude never reads files or fetches pages.
    public var allowSensitiveTools = true {
        didSet { if oldValue != allowSensitiveTools { session = nil } }
    }

    public init(record: ChatSessionRecord, store: SessionStore = .shared, persist: Bool = true) {
        self.record = record
        self.store = store
        self.persist = persist
    }

    public static func open(id: String, source: String = "cli", store: SessionStore = .shared) -> ChatEngine {
        ChatEngine(record: store.load(id) ?? ChatSessionRecord(id: id, title: id, source: source), store: store)
    }

    public func update(_ change: (inout ChatSessionRecord) -> Void) {
        let before = record
        change(&record)
        if before.instructions != record.instructions || before.config != record.config || before.tools != record.tools
            || before.summary != record.summary || before.integrations != record.integrations {
            session = nil
        }
        save()
    }

    public func reset() {
        record.messages.removeAll()
        record.summary = nil
        record.contextStart = 0
        session = nil
        save()
    }

    func save() {
        record.updated = Date()
        if persist { store.save(record) }
    }

    var effectiveInstructions: String {
        guard let s = record.summary, !s.isEmpty else { return record.instructions }
        return record.instructions + "\n\nSummary of the conversation so far:\n" + s
    }

    /// Builds the session from the saved chat. With `pending`, the last message is a user message about to be
    /// sent as the prompt, so it's left out of the history. Including it sent it twice.
    private func makeSession(tracker: ToolCallTracker, pending: Bool = false) throws -> LanguageModelSession {
        let m = record.config.makeModel()
        guard m.isAvailable else { throw AFMError.unavailable(.current()) }
        model = m
        var tools = ToolRegistry.make(allowSensitiveTools ? record.tools : record.tools.filter { !$0.isSensitive }, tracker: tracker)
        let allowed = IntegrationRegistry.chatEnabled
        for id in record.integrations ?? [] {
            if let integ = allowed.first(where: { $0.id == id }) { tools += integ.modelTools(tracker: tracker) }
        }
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(segments: [.text(.init(content: effectiveInstructions))],
                                                  toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) }))
        ]
        var history = Array(record.messages.dropFirst(record.contextStart))
        if pending, history.last?.role == .user { history.removeLast() }
        for m in history {
            switch m.role {
            case .user: entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: m.modelText))])))
            case .assistant: entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: m.text))])))
            case .notice: continue
            }
        }
        return LanguageModelSession(model: m, tools: tools, transcript: Transcript(entries: entries))
    }

    /// Loads the model and caches the instructions and history ahead of the next message, which
    /// shortens the wait for the first token. Call it when the person starts typing. It does nothing
    /// if the session is already built or the model is unavailable.
    public func prewarm() {
        guard session == nil, let s = try? makeSession(tracker: tracker) else { return }
        session = s
        s.prewarm()
    }

    /// Tokens currently used by the conversation, out of the context size.
    public func contextUsage() async -> (used: Int, total: Int) {
        let total = SystemLanguageModel.default.contextSize
        guard let s = session, let m = model else {
            let text = effectiveInstructions + record.messages.dropFirst(record.contextStart).map(\.modelText).joined(separator: "\n")
            return (await AFM.tokenCount(text, config: record.config), total)
        }
        let used = (try? await m.tokenCount(for: s.transcript)) ?? 0
        return (used, total)
    }

    private var tracker = ToolCallTracker()

    @discardableResult
    public func send(_ text: String,
                     onPartial: (@Sendable (String) -> Void)? = nil,
                     onTool: (@Sendable (String) -> Void)? = nil,
                     onNotice: (@Sendable (String) -> Void)? = nil,
                     onProgress: (@Sendable (LongReadProgress) -> Void)? = nil) async throws -> ChatMessage {
        if record.messages.filter({ $0.role == .user }).isEmpty && (record.title == "New chat" || record.title == record.id) {
            record.title = String(text.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        record.messages.append(ChatMessage(role: .user, text: text))
        save()

        // Proactive compaction when the conversation is close to the limit.
        let usage = await contextUsage()
        let promptTokens = await AFM.tokenCount(text, config: record.config)
        if usage.used + promptTokens > Int(Double(usage.total) * 0.72), record.messages.count - record.contextStart > 2 {
            try await compact(onNotice: onNotice)
        }

        // A message too long for the context is read in parts first, and the model answers from notes.
        var prompt = text
        var longRead: (parts: Int, started: Date)?
        let room = await promptRoom()
        if promptTokens > room {
            do {
                let r = try await condense(text, tokens: promptTokens, room: room, onNotice: onNotice, onProgress: onProgress)
                prompt = r.prompt
                longRead = (r.parts, r.started)
            } catch {
                if let last = record.messages.last, last.role == .user, last.text == text { record.messages.removeLast(); save() }
                throw error is CancellationError ? error : await AFMError.resolve(error)
            }
            record.messages[record.messages.count - 1].contextText = prompt
            save()
        }

        // Cap the answer at the room left, so a long answer stops cleanly instead of overflowing the context
        // partway through. With little room left, compaction on overflow still handles it.
        var turnOptions = record.options
        let promptNow = prompt == text ? promptTokens : await AFM.tokenCount(prompt, config: record.config)
        if let cap = ChatEngine.answerCap(room: room, promptTokens: promptNow) {
            turnOptions.maxTokens = min(turnOptions.maxTokens ?? cap, cap)
        }

        var attempt = 0
        while true {
            let callTracker = ToolCallTracker(onCall: onTool)
            var out = ""
            let start = Date()
            do {
                if session == nil { tracker = callTracker; session = try makeSession(tracker: callTracker, pending: true) }
                else { tracker.onCall = onTool }
                let active = tracker
                let s = session!
                let callsBefore = active.calls.count
                active.beginTurn()
                for try await snap in s.streamResponse(to: Prompt(prompt), options: turnOptions.generationOptions) {
                    out = snap.content
                    onPartial?(out)
                }
                let secs = Date().timeIntervalSince(start)
                let toks = await AFM.tokenCount(out, config: record.config)
                let msg = ChatMessage(role: .assistant, text: out, seconds: secs, tokens: toks, tools: Array(active.calls.dropFirst(callsBefore)))
                record.messages.append(msg)
                if let longRead {
                    let line = LongMessage.summary(tokens: promptTokens, parts: longRead.parts, seconds: Date().timeIntervalSince(longRead.started))
                    record.messages.append(ChatMessage(role: .notice, text: line))
                    onNotice?(line)
                }
                save()
                History.append(HistoryEntry(source: record.source, kind: "chat", title: record.title, input: text, output: out, seconds: secs, outputTokens: toks))
                return msg
            } catch {
                session = nil
                if error is CancellationError || Task.isCancelled {
                    if !out.isEmpty {
                        record.messages.append(ChatMessage(role: .assistant, text: out + " …", seconds: Date().timeIntervalSince(start)))
                    }
                    record.messages.append(ChatMessage(role: .notice, text: "Stopped."))
                    save()
                    throw CancellationError()
                }
                if case LanguageModelError.contextSizeExceeded = error, attempt == 0 {
                    attempt += 1
                    try await compact(onNotice: onNotice)
                    continue
                }
                if let last = record.messages.last, last.role == .user, last.text == text {
                    record.messages.removeLast()
                    save()
                }
                throw await AFMError.resolve(error)
            }
        }
    }

    /// Tokens left for the next prompt after the instructions, tool definitions and history, keeping room for the answer.
    func promptRoom() async -> Int {
        let total = SystemLanguageModel.default.contextSize
        let overhead: Int
        if let s = try? makeSession(tracker: ToolCallTracker(), pending: true), let m = model {
            overhead = (try? await m.tokenCount(for: s.transcript)) ?? Chunker.estimate(effectiveInstructions)
        } else {
            overhead = await AFM.tokenCount(effectiveInstructions, config: record.config)
        }
        return total - overhead - ChatEngine.answerReserve
    }

    /// Tokens kept free for the answer when deciding whether a message fits.
    static let answerReserve = 900

    /// The most tokens the answer may use, given the room `promptRoom` reported and the prompt's size.
    /// nil when under 300 tokens are left, where a capped answer would be too short to be useful.
    public static func answerCap(room: Int, promptTokens: Int) -> Int? {
        let left = room + answerReserve - promptTokens - 60
        return left >= 300 ? left : nil
    }

    /// Reads a message that's too long for the context in parts, takes notes on each with the person's request
    /// in mind, and returns a prompt built from those notes. This is what Recipes do for long documents.
    func condense(_ text: String, tokens: Int, room: Int, onNotice: (@Sendable (String) -> Void)?,
                  onProgress: (@Sendable (LongReadProgress) -> Void)? = nil) async throws -> (prompt: String, parts: Int, started: Date) {
        let started = Date()
        var cfg = record.config
        cfg.guardrails = .permissive
        let model = cfg.makeModel()
        let (head, tail) = LongMessage.ends(text)
        let chunks = await Chunker.split(text, maxTokens: LongMessage.chunkTokens, model: model)
        let n = chunks.count
        // Text notices are for the CLI. A caller with a progress display gets structured reports instead.
        let say: (String) -> Void = { m in if onProgress == nil { onNotice?(m) } }
        func report(_ stage: LongReadProgress.Stage, done: Int, remaining: TimeInterval) {
            onProgress?(LongReadProgress(tokens: tokens, parts: n, done: done, stage: stage, started: started, remaining: remaining))
        }

        let first = LongMessage.remaining(parts: n, done: 0, measuredPerPart: nil, includeRequest: true)
        say("This message is about \(tokens.formatted()) tokens, more than the model can read at once. Reading it in \(n) parts, \(LongMessage.roughly(first)).")
        report(.request, done: 0, remaining: first)
        let request = try await AFM.generate(LongMessage.requestPrompt(head: head, tail: tail), instructions: LongMessage.notesInstructions,
                                             options: GenOptions(temperature: 0.1, maxTokens: 80), config: cfg)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var notes: [String] = []
        let readingStarted = Date()
        for (i, c) in chunks.enumerated() {
            try Task.checkCancellation()
            let perPart = i == 0 ? nil : Date().timeIntervalSince(readingStarted) / Double(i)
            say("Reading part \(i + 1) of \(n)…")
            report(.reading, done: i, remaining: LongMessage.remaining(parts: n, done: i, measuredPerPart: perPart))
            notes.append(try await AFM.generate(LongMessage.notesPrompt(part: c, index: i, count: n, request: request),
                                                instructions: LongMessage.notesInstructions,
                                                options: GenOptions(temperature: 0.2, maxTokens: LongMessage.notesTokens), config: cfg))
        }
        let perPart = Date().timeIntervalSince(readingStarted) / Double(max(n, 1))

        var joined = LongMessage.join(notes)
        let limit = room - Chunker.estimate(request) - 150
        var depth = 0
        while await Chunker.countTokens(joined, model: model) > limit, depth < 3 {
            try Task.checkCancellation()
            let pieces = await Chunker.split(joined, maxTokens: LongMessage.chunkTokens, model: model)
            say("Combining notes…")
            report(.combining, done: n, remaining: Double(pieces.count) * perPart + LongMessage.answerSeconds)
            var next: [String] = []
            for p in pieces {
                next.append(try await AFM.generate(LongMessage.combinePrompt(p, request: request),
                                                   instructions: LongMessage.notesInstructions,
                                                   options: GenOptions(temperature: 0.2, maxTokens: LongMessage.notesTokens), config: cfg))
            }
            joined = LongMessage.join(next)
            depth += 1
        }
        say("Read all \(n) parts. Answering from the notes.")
        report(.answering, done: n, remaining: LongMessage.answerSeconds)
        return (LongMessage.finalPrompt(request: request, notes: joined), n, started)
    }

    /// Summarises older turns into the instructions and keeps only the newest user message live.
    public func compact(onNotice: (@Sendable (String) -> Void)? = nil) async throws {
        let live = Array(record.messages.dropFirst(record.contextStart))
        guard live.count > 1 else { return }
        let older = live.dropLast()
        var convo = older.filter { $0.role != .notice }.map { ($0.role == .user ? "User: " : "Assistant: ") + $0.modelText }.joined(separator: "\n")
        if let s = record.summary { convo = "Earlier summary: \(s)\n" + convo }
        if convo.count > 9000 { convo = String(convo.suffix(9000)) }
        var cfg = record.config
        cfg.guardrails = .permissive
        let summary = try await AFM.generate(
            "Summarize this conversation in under 120 words. Keep names, facts, numbers, decisions and open questions.\n\n" + convo,
            instructions: "You write compact, faithful conversation summaries.", options: GenOptions(temperature: 0.2), config: cfg)
        record.summary = summary
        let insertAt = max(record.messages.count - 1, 0)
        record.messages.insert(ChatMessage(role: .notice, text: "Earlier messages were summarized to fit the 4,096-token context."), at: insertAt)
        record.contextStart = insertAt
        session = nil
        save()
        onNotice?("Conversation compacted to fit the context window.")
    }

    /// Writes an Apple feedback attachment for the last response (for Feedback Assistant).
    public func feedbackAttachment(positive: Bool, issue: LanguageModelFeedback.Issue.Category? = nil, note: String? = nil) -> URL? {
        guard let s = session else { return nil }
        let issues = issue.map { [LanguageModelFeedback.Issue(category: $0, explanation: note)] } ?? []
        let data = s.logFeedbackAttachment(sentiment: positive ? .positive : .negative, issues: issues, desiredResponseText: nil)
        let url = AFMPaths.feedback.appendingPathComponent("feedback-\(Int(Date().timeIntervalSince1970)).json")
        try? data.write(to: url)
        return url
    }

    public func markdownExport() -> String {
        var out = "# \(record.title)\n\n"
        for m in record.messages {
            switch m.role {
            case .user: out += "**You:** \(m.text)\n\n"
            case .assistant: out += "**AFM:** \(m.text)\n\n"
            case .notice: out += "_\(m.text)_\n\n"
            }
        }
        return out
    }
}

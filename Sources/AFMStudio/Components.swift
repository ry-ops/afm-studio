import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AFMKit

enum Pasteboard {
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
    static var string: String { NSPasteboard.general.string(forType: .string) ?? "" }
}

/// Renders Markdown with fenced code blocks shown as monospaced cards.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.code {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(block.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .padding(10)
                    }
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topTrailing) { CopyButton(text: block.text, compact: true).padding(4) }
                } else {
                    Text(attributed(block.text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    struct Block { let text: String; let code: Bool }

    var blocks: [Block] {
        let parts = text.components(separatedBy: "```")
        return parts.enumerated().compactMap { i, p in
            if i % 2 == 1 {
                var lines = p.components(separatedBy: "\n")
                if let first = lines.first, !first.contains(" "), first.count < 20 { lines.removeFirst() }
                let code = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                return Block(text: code, code: true)
            }
            let t = p.trimmingCharacters(in: .newlines)
            return t.isEmpty ? nil : Block(text: t, code: false)
        }
    }

    func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct CopyButton: View {
    let text: String
    var compact = false
    @State private var copied = false

    var body: some View {
        Button {
            Pasteboard.copy(text)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
        } label: {
            if compact { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
            else { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
        }
        .buttonStyle(.borderless)
        .help("Copy")
        .disabled(text.isEmpty)
    }
}

struct StatChip: View {
    let symbol: String
    let text: String
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.quaternary.opacity(0.7), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

struct ResultStats: View {
    let result: GenerationResult
    var body: some View {
        HStack(spacing: 6) {
            StatChip(symbol: "timer", text: String(format: "%.1fs", result.seconds))
            if let f = result.firstTokenSeconds { StatChip(symbol: "bolt", text: String(format: "first %.2fs", f)) }
            if let o = result.outputTokens { StatChip(symbol: "text.word.spacing", text: "\(o) tokens") }
            if result.chunks == 1, let t = result.tokensPerSecond { StatChip(symbol: "speedometer", text: String(format: "%.1f tok/s", t)) }
            if result.chunks > 1 { StatChip(symbol: "square.split.2x2", text: "\(result.chunks) chunks") }
            ForEach(result.toolCalls, id: \.self) { StatChip(symbol: "wrench.and.screwdriver", text: $0) }
        }
    }
}

struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label(title, systemImage: symbol ?? "circle").font(.headline)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
    }
}

struct TokenGauge: View {
    let used: Int
    let total: Int
    var body: some View {
        let frac = min(1, Double(used) / Double(max(total, 1)))
        Gauge(value: frac) {
            EmptyView()
        } currentValueLabel: {
            Text("\(used)")
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(frac > 0.85 ? .orange : .accentColor)
        .scaleEffect(0.6)
        .frame(width: 34, height: 34)
        .help("\(used) of \(total) context tokens")
    }
}

/// Generation and model options, shared by several panes.
struct OptionsEditor: View {
    @Binding var options: GenOptions
    @Binding var config: ModelConfig
    var showUseCase = true

    var body: some View {
        Picker("Guardrails", selection: $config.guardrails) {
            ForEach(GuardrailMode.allCases) { Text($0.title).tag($0) }
        }
        .help(config.guardrails.detail)
        if showUseCase {
            Picker("Model", selection: $config.useCase) {
                ForEach(UseCaseMode.allCases) { Text($0.title).tag($0) }
            }
        }
        Picker("Sampling", selection: $options.sampling) {
            ForEach(SamplingKind.allCases) { Text($0.title).tag($0) }
        }
        if options.sampling == .topK {
            Stepper("Top-K: \(options.topK)", value: $options.topK, in: 1...200)
        }
        if options.sampling == .topP {
            LabeledContent("Top-P") {
                Slider(value: $options.topP, in: 0.05...1) { Text(String(format: "%.2f", options.topP)) }
            }
        }
        Toggle("Custom temperature", isOn: Binding(
            get: { options.temperature != nil },
            set: { options.temperature = $0 ? (options.temperature ?? 0.7) : nil }))
        if let t = options.temperature {
            LabeledContent(String(format: "Temperature %.2f", t)) {
                Slider(value: Binding(get: { options.temperature ?? 0.7 }, set: { options.temperature = $0 }), in: 0...2)
            }
        }
        Toggle("Limit response length", isOn: Binding(
            get: { options.maxTokens != nil },
            set: { options.maxTokens = $0 ? (options.maxTokens ?? 500) : nil }))
        if let m = options.maxTokens {
            Stepper("Max tokens: \(m)", value: Binding(get: { options.maxTokens ?? 500 }, set: { options.maxTokens = $0 }), in: 16...4000, step: 16)
        }
    }
}

/// A text editor that accepts dropped text files and has open/paste buttons.
struct InputEditor: View {
    @Binding var text: String
    var placeholder = "Paste or type text, or drop a file here"
    var minHeight: CGFloat = 160
    @State private var dropping = false
    @State private var tokens: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                }
            }
            .frame(minHeight: minHeight)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(dropping ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: dropping ? 2 : 1))
            .dropDestination(for: URL.self) { urls, _ in
                let loaded = urls.compactMap { FileLoader.text(at: $0) }
                guard !loaded.isEmpty else { return false }
                text = loaded.joined(separator: "\n\n")
                return true
            } isTargeted: { dropping = $0 }
            HStack(spacing: 12) {
                Button("Open File…", systemImage: "folder") {
                    if let s = FileLoader.pick() { text = s }
                }
                Button("Paste", systemImage: "doc.on.clipboard") { text = Pasteboard.string }
                if !text.isEmpty { Button("Clear", systemImage: "xmark.circle") { text = "" } }
                Spacer()
                if let tokens {
                    Text("\(tokens) tokens · \(text.count) characters")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(tokens > 3000 ? .orange : .secondary)
                        .help(tokens > 3000 ? "Long input: recipes will split it into chunks." : "")
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
            tokens = text.isEmpty ? nil : await AFM.tokenCount(text)
        }
    }
}

enum FileLoader {
    static func text(at url: URL) -> String? {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let d = try? Data(contentsOf: url) else { return nil }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
    }

    @MainActor static func pick() -> String? {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.text, .plainText, .sourceCode, .json, .xml, .html, .commaSeparatedText, .log]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let u = p.url else { return nil }
        return text(at: u)
    }

    @MainActor static func pickMany() -> [URL] {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.text, .plainText, .sourceCode, .json, .xml, .html, .commaSeparatedText, .log, .folder]
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        guard p.runModal() == .OK else { return [] }
        return p.urls
    }

    @MainActor static func save(_ text: String, name: String, type: UTType = .plainText) {
        let p = NSSavePanel()
        p.nameFieldStringValue = name
        p.allowedContentTypes = [type]
        if p.runModal() == .OK, let u = p.url { try? text.write(to: u, atomically: true, encoding: .utf8) }
    }
}

struct PaneHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(LinearGradient(colors: [.indigo, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

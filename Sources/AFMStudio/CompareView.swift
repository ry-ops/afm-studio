import SwiftUI
import AFMKit

struct Variant: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var options: GenOptions
    var config: ModelConfig
    var output = ""
    var result: GenerationResult?
    var error: String?
    var running = false
}

struct CompareView: View {
    @ViewState private var prompt = "Write a two-sentence product description for a solar-powered camping lantern."
    @ViewState private var instructions = ""
    @ViewState private var variants: [Variant] = [
        Variant(name: "Precise", options: GenOptions(sampling: .greedy), config: ModelConfig()),
        Variant(name: "Balanced", options: GenOptions(temperature: 0.7), config: ModelConfig()),
        Variant(name: "Creative", options: GenOptions(temperature: 1.3, sampling: .topP, topP: 0.95), config: ModelConfig()),
    ]
    @ViewState private var running = false
    @ViewState private var task: Task<Void, Never>?
    @ViewState private var editing: Variant.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: "Compare", subtitle: "Run one prompt with different settings side by side.", symbol: "rectangle.split.3x1")
            TextField("Prompt", text: $prompt, axis: .vertical).lineLimit(2...6).textFieldStyle(.roundedBorder)
            TextField("Instructions (optional)", text: $instructions, axis: .vertical).lineLimit(1...3).textFieldStyle(.roundedBorder)
            HStack {
                Button("Add Variant", systemImage: "plus") {
                    variants.append(Variant(name: "Variant \(variants.count + 1)", options: GenOptions(temperature: 1.0), config: ModelConfig()))
                }
                .disabled(variants.count >= 5)
                Spacer()
                if running {
                    ProgressView().controlSize(.small)
                    Button("Stop", systemImage: "stop.fill") { task?.cancel() }
                } else {
                    Button("Run All", systemImage: "play.fill") { run() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(prompt.isEmpty)
                }
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach($variants) { $v in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                TextField("Name", text: $v.name).font(.headline).textFieldStyle(.plain)
                                Spacer()
                                Button { editing = editing == v.id ? nil : v.id } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.borderless)
                                if variants.count > 1 {
                                    Button { variants.removeAll { $0.id == v.id } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                                }
                            }
                            Text(summary(v)).font(.caption).foregroundStyle(.secondary)
                            if editing == v.id {
                                Form { OptionsEditor(options: $v.options, config: $v.config) }.formStyle(.columns)
                            }
                            Divider()
                            ScrollView {
                                Group {
                                    if v.running && v.output.isEmpty { ProgressView().controlSize(.small) }
                                    else if let e = v.error { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                                    else { MarkdownText(text: v.output) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 120)
                            if let r = v.result {
                                HStack { StatChip(symbol: "timer", text: String(format: "%.1fs", r.seconds)); if let o = r.outputTokens { StatChip(symbol: "text.word.spacing", text: "\(o) tok") }; Spacer(); CopyButton(text: v.output, compact: true) }
                            }
                        }
                        .padding(14)
                        .frame(width: 320)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(22)
    }

    func summary(_ v: Variant) -> String {
        var parts = [v.options.sampling.title]
        if let t = v.options.temperature { parts.append(String(format: "temp %.2f", t)) }
        if v.config.guardrails == .permissive { parts.append("permissive") }
        if let m = v.options.maxTokens { parts.append("max \(m)") }
        return parts.joined(separator: " · ")
    }

    func run() {
        running = true
        for i in variants.indices { variants[i].output = ""; variants[i].result = nil; variants[i].error = nil }
        let p = prompt, ins = instructions
        task = Task {
            for i in variants.indices {
                if Task.isCancelled { break }
                variants[i].running = true
                let v = variants[i]
                do {
                    let r = try await AFM.run(GenerationRequest(prompt: p, instructions: ins.isEmpty ? nil : ins, options: v.options, config: v.config),
                                              onPartial: { s in Task { @MainActor in if i < variants.count { variants[i].output = s } } })
                    variants[i].output = r.text
                    variants[i].result = r
                } catch {
                    if !Task.isCancelled { variants[i].error = AFMError.from(error).fullDescription }
                }
                variants[i].running = false
            }
            running = false
        }
    }
}

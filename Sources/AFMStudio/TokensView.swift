import SwiftUI
import AFMKit

struct TokensView: View {
    @ViewState private var text = ""
    @ViewState private var instructions = ""
    @ViewState private var tokens = 0
    @ViewState private var instructionTokens = 0
    @ViewState private var chunks = 1
    @ViewState private var counting = false
    let context = AFM.contextSize

    var total: Int { tokens + instructionTokens }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PaneHeader(title: "Tokens", subtitle: "Exact counts from the on-device tokenizer, against the \(context)-token context.", symbol: "number.square")
                HStack(alignment: .top, spacing: 16) {
                    Card(title: "Usage", symbol: "gauge.with.dots.needle.33percent") {
                        Gauge(value: Double(min(total, context)), in: 0...Double(context)) {
                            Text("Context")
                        } currentValueLabel: {
                            Text("\(total)")
                        } minimumValueLabel: { Text("0") } maximumValueLabel: { Text("\(context)") }
                        .tint(Gradient(colors: [.green, .yellow, .orange, .red]))
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                            GridRow { Text("Text"); Text("\(tokens)").monospacedDigit().bold() }
                            GridRow { Text("Instructions"); Text("\(instructionTokens)").monospacedDigit().bold() }
                            GridRow { Text("Characters per token"); Text(tokens > 0 ? String(format: "%.2f", Double(text.count) / Double(tokens)) : "–").monospacedDigit() }
                            GridRow { Text("Room left for a reply"); Text("\(max(0, context - total))").monospacedDigit().foregroundStyle(context - total < 500 ? .orange : .primary) }
                            GridRow { Text("Chunks for long-mode recipes"); Text("\(chunks)").monospacedDigit() }
                        }
                        .font(.callout)
                    }
                    .frame(maxWidth: 360)
                    Card(title: "Why this matters", symbol: "info.circle") {
                        Text("The context window holds the instructions, the prompt, any tool definitions and the reply. When text doesn't fit, AFM Studio splits it on paragraph and sentence boundaries, runs each piece, and combines the results.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Text("Instructions").font(.headline)
                TextField("Optional system instructions", text: $instructions, axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder)
                Text("Text").font(.headline)
                InputEditor(text: $text, minHeight: 300)
            }
            .padding(22)
        }
        .task(id: text + "\u{0}" + instructions) {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            tokens = await AFM.tokenCount(text)
            instructionTokens = instructions.isEmpty ? 0 : await AFM.tokenCount(instructions: instructions)
            if tokens > 3000 {
                chunks = await Chunker.split(text, maxTokens: 2600, model: ModelConfig().makeModel()).count
            } else { chunks = 1 }
        }
    }
}

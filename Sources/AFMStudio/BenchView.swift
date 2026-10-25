import SwiftUI
import Charts
import AFMKit

struct BenchView: View {
    @ViewState private var runs: [BenchRun] = []
    @ViewState private var rounds = 1
    @ViewState private var running = false
    @ViewState private var error: String?
    @ViewState private var task: Task<Void, Never>?

    var meanTPS: Double { runs.isEmpty ? 0 : runs.map(\.tokensPerSecond).reduce(0, +) / Double(runs.count) }
    var medianTTFT: Double { runs.isEmpty ? 0 : runs.map(\.firstToken).sorted()[runs.count / 2] }
    var totalTokens: Int { runs.map(\.outputTokens).reduce(0, +) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader(title: "Benchmark", subtitle: "Time to first token and decode speed on this Mac, with greedy sampling.", symbol: "speedometer")
                HStack {
                    Stepper("Rounds: \(rounds)", value: $rounds, in: 1...5).fixedSize()
                    Text("\(Bench.tasks.count * rounds) generations").foregroundStyle(.secondary)
                    Spacer()
                    if running {
                        ProgressView(value: Double(runs.count), total: Double(Bench.tasks.count * rounds)).frame(width: 160)
                        Button("Stop", systemImage: "stop.fill") { task?.cancel() }
                    } else {
                        Button("Run Benchmark", systemImage: "play.fill") { run() }.buttonStyle(.borderedProminent)
                    }
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                HStack(spacing: 14) {
                    tile("Mean speed", runs.isEmpty ? "–" : String(format: "%.1f tok/s", meanTPS), "speedometer")
                    tile("Median first token", runs.isEmpty ? "–" : String(format: "%.2f s", medianTTFT), "bolt")
                    tile("Tokens generated", runs.isEmpty ? "–" : "\(totalTokens)", "text.word.spacing")
                    tile("Context window", "\(AFM.contextSize)", "rectangle.compress.vertical")
                }
                if !runs.isEmpty {
                    Card(title: "Decode speed by task", symbol: "chart.bar") {
                        Chart(runs) { r in
                            BarMark(x: .value("Task", r.task), y: .value("Tokens/sec", r.tokensPerSecond))
                                .foregroundStyle(by: .value("Round", "Round \(r.round)"))
                                .position(by: .value("Round", "Round \(r.round)"))
                        }
                        .chartYAxisLabel("tokens / second")
                        .frame(height: 220)
                    }
                    Card(title: "Latency", symbol: "timer") {
                        Chart(runs) { r in
                            BarMark(x: .value("Task", r.task), yStart: .value("Start", 0), yEnd: .value("First token", r.firstToken))
                                .foregroundStyle(.orange.opacity(0.8))
                                .position(by: .value("Round", "Round \(r.round)"))
                            BarMark(x: .value("Task", r.task), yStart: .value("First token", r.firstToken), yEnd: .value("Total", r.total))
                                .foregroundStyle(.blue.opacity(0.6))
                                .position(by: .value("Round", "Round \(r.round)"))
                        }
                        .chartYAxisLabel("seconds (orange: waiting for first token, blue: generating)")
                        .frame(height: 220)
                    }
                    Table(runs) {
                        TableColumn("Round") { Text("\($0.round)") }.width(50)
                        TableColumn("Task", value: \.task)
                        TableColumn("First token") { Text(String(format: "%.2fs", $0.firstToken)).monospacedDigit() }
                        TableColumn("Total") { Text(String(format: "%.2fs", $0.total)).monospacedDigit() }
                        TableColumn("Tokens") { Text("\($0.outputTokens)").monospacedDigit() }
                        TableColumn("Tok/s") { Text(String(format: "%.1f", $0.tokensPerSecond)).monospacedDigit() }
                    }
                    .frame(minHeight: 200)
                } else if !running {
                    ContentUnavailableView("No results yet", systemImage: "speedometer", description: Text("Runs \(Bench.tasks.count) short tasks: \(Bench.tasks.map(\.name).joined(separator: ", ")).")).padding(.top, 30)
                }
            }
            .padding(22)
        }
    }

    func tile(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit())
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    func run() {
        running = true; error = nil; runs = []
        let n = rounds
        task = Task {
            do {
                _ = try await Bench.run(rounds: n) { r in Task { @MainActor in runs.append(r) } }
            } catch { if !Task.isCancelled { self.error = AFMError.from(error).fullDescription } }
            running = false
        }
    }
}

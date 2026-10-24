import SwiftUI
import AFMKit

struct HistoryView: View {
    @State private var items: [HistoryEntry] = []
    @State private var search = ""
    @State private var source = "all"
    @State private var selection: HistoryEntry.ID?
    @State private var confirmClear = false

    var filtered: [HistoryEntry] {
        items.filter { (source == "all" || $0.source == source) && (search.isEmpty || ($0.title + $0.input + $0.output).localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 12) {
                PaneHeader(title: "History", subtitle: "Every run from the app, Terminal, Claude (MCP) and the local API. Stored only on this Mac.", symbol: "clock.arrow.circlepath")
                HStack {
                    Picker("Source", selection: $source) {
                        Text("All").tag("all"); Text("Studio").tag("studio"); Text("Terminal").tag("cli"); Text("Claude (MCP)").tag("mcp"); Text("API").tag("api")
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 460)
                    Spacer()
                    Text("\(filtered.count) runs").foregroundStyle(.secondary)
                    Button("Refresh", systemImage: "arrow.clockwise") { load() }
                    Button("Clear…", systemImage: "trash") { confirmClear = true }.disabled(items.isEmpty)
                }
                Table(filtered, selection: $selection) {
                    TableColumn("When") { Text($0.date.formatted(date: .abbreviated, time: .shortened)) }.width(140)
                    TableColumn("Source") { Text(label($0.source)) }.width(90)
                    TableColumn("Kind", value: \.kind).width(120)
                    TableColumn("Title") { e in HStack { if !e.ok { Image(systemName: "xmark.octagon.fill").foregroundStyle(.red) }; Text(e.title).lineLimit(1) } }
                    TableColumn("Time") { Text(String(format: "%.1fs", $0.seconds)).monospacedDigit() }.width(60)
                }
                .overlay { if filtered.isEmpty { ContentUnavailableView("No history", systemImage: "clock", description: Text("Runs appear here as you use AFM anywhere.")) } }
            }
            .padding([.horizontal, .top], 22)
            .frame(minHeight: 280)

            Group {
                if let e = items.first(where: { $0.id == selection }) {
                    HSplitView {
                        detail("Input", e.input)
                        detail("Output", e.output)
                    }
                } else {
                    Text("Select a run to see its input and output.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 180)
        }
        .searchable(text: $search, placement: .toolbar)
        .onAppear(perform: load)
        .confirmationDialog("Delete all history?", isPresented: $confirmClear) {
            Button("Delete History", role: .destructive) { History.clear(); load() }
        }
    }

    func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title).font(.headline); Spacer(); CopyButton(text: text, compact: true) }
            ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .padding(14)
    }

    func label(_ s: String) -> String { ["studio": "Studio", "cli": "Terminal", "mcp": "Claude", "api": "API"][s] ?? s }
    func load() { items = History.load(limit: 2000) }
}

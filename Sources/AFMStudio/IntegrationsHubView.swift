import SwiftUI
import AFMKit

/// Every integration AFM Studio ships, with what it touches and the switches that control it. All start off.
struct IntegrationsHubView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader(title: "Integrations", subtitle: "Connect outside services. Each one starts off, and you choose where its tools show up.", symbol: "puzzlepiece.extension")
                ForEach(IntegrationRegistry.all, id: \.id) { IntegrationCard(integration: $0) }
                Text("Each tool you turn on uses part of the on-device model's 4K context, and adds to the tool list Claude sees. Keep on only what you use.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(22)
        }
    }
}

struct IntegrationCard: View {
    @Environment(AppState.self) private var app
    let integration: any AFMIntegration
    @State private var changedForClaude = false

    var prefs: IntegrationPrefs { app.settings.integrationPrefs[integration.id] ?? IntegrationPrefs() }

    func set(_ change: (inout IntegrationPrefs) -> Void) {
        var p = prefs
        change(&p)
        app.settings.integrationPrefs[integration.id] = p
        app.saveSettings()
        changedForClaude = true
        Task { await app.github.refreshStatus() }
    }

    var body: some View {
        let m = integration.manifest
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: integration.symbol).font(.title2).frame(width: 40, height: 40)
                    .foregroundStyle(.white)
                    .background(prefs.enabled ? Color.accentColor : Color.secondary, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(integration.name).font(.title3.bold())
                    Text(integration.summary).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("On", isOn: Binding(get: { prefs.enabled }, set: { v in set { $0.enabled = v } }))
                    .toggleStyle(.switch).labelsHidden()
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { Text("Signs in with").foregroundStyle(.secondary); Text(m.credentials.joined(separator: "; ")) }
                GridRow { Text("Talks to").foregroundStyle(.secondary); Text(m.hosts.joined(separator: ", ")) }
                GridRow { Text("Writes").foregroundStyle(.secondary); Text(m.writes == .draftsOnly ? "Drafts only. You review and submit everything." : m.writes.rawValue.capitalized) }
                GridRow { Text("Your data").foregroundStyle(.secondary); Text(m.dataNote) }
            }
            .font(.callout)
            if prefs.enabled {
                Divider()
                Toggle(isOn: Binding(get: { prefs.chat }, set: { v in set { $0.chat = v } })) {
                    VStack(alignment: .leading) {
                        Text("Tools in chat")
                        Text("The on-device model can call its read-only tools when you switch them on for a chat.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(get: { prefs.claude }, set: { v in set { $0.claude = v } })) {
                    VStack(alignment: .leading) {
                        Text("Tools for Claude")
                        Text("Adds \(integration.mcpTools.count) tools to the afm MCP server: \(integration.mcpTools.map(\.name).joined(separator: ", ")).").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if integration.id == "github" { Button("Open GitHub") { app.pane = .github } }
                    if changedForClaude { Text("Restart Claude Code or Claude Desktop to refresh their tool list.").font(.caption).foregroundStyle(.orange) }
                }
            }
        }
    }
}

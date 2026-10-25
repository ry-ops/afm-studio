import SwiftUI
import AFMKit

struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView {
            Form {
                Toggle("Keep a local history of runs", isOn: $app.settings.historyEnabled)
                LabeledContent("Data folder") {
                    Button("Reveal in Finder") { NSWorkspace.shared.open(AFMPaths.root) }
                }
                LabeledContent("History") {
                    Button("Clear History", role: .destructive) { History.clear() }
                }
                LabeledContent("API server port") {
                    TextField("", value: $app.settings.serverPort, format: .number.grouping(.never)).frame(width: 90)
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("New chats start with") {
                    TextEditor(text: $app.settings.defaultInstructions).frame(height: 90)
                    OptionsEditor(options: $app.settings.defaultOptions, config: $app.settings.defaultConfig)
                }
                Section("Tools enabled in new chats") {
                    ForEach(ToolKind.allCases) { t in
                        Toggle(t.title, isOn: Binding(get: { app.settings.defaultTools.contains(t) }, set: { on in
                            if on { app.settings.defaultTools.append(t) } else { app.settings.defaultTools.removeAll { $0 == t } }
                        }))
                    }
                    if let w = ToolKind.riskWarning(app.settings.defaultTools) {
                        Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .tabItem { Label("Defaults", systemImage: "slider.horizontal.3") }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 520)
        .onChange(of: app.settings) { app.saveSettings() }
    }
}

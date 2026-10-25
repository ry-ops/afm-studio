import SwiftUI
import AFMKit

/// Update checks for the app. Background checks happen only when turned on in Settings.
@Observable @MainActor
final class UpdateState {
    var available: ReleaseInfo?
    var checking = false
    var message: String?
    var lastChecked: Date? = Updates.saved()?.checked
    var showSheet = false

    /// On launch and then daily, when the setting is on. Quiet: failures are ignored.
    func startBackgroundChecks(enabled: @escaping @MainActor () -> Bool) {
        Task {
            while true {
                if enabled(), let s = await Updates.checkIfDue() { apply(s, manual: false) }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    func checkNow(showResult: Bool = true) {
        guard !checking else { return }
        checking = true
        message = nil
        Task {
            do { apply(try await Updates.check(), manual: true) }
            catch { message = AFMError.from(error).message }
            checking = false
            if showResult { showSheet = true }
        }
    }

    private func apply(_ s: Updates.Status, manual: Bool) {
        lastChecked = Updates.saved()?.checked ?? Date()
        switch s {
        case .available(let r): available = r; message = nil
        case .upToDate(let v): available = nil; message = "AFM Studio \(AFMVersion.string) is up to date. The latest release is \(v)."
        case .noReleases: available = nil; message = "No releases are published yet."
        }
    }
}

/// The small button in the sidebar footer when a newer release is out.
struct UpdateBadge: View {
    @Environment(AppState.self) private var app
    var body: some View {
        if let r = app.updates.available {
            Button { app.updates.showSheet = true } label: {
                Label("Update available: \(r.version?.description ?? r.tag)", systemImage: "arrow.down.circle.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .help("See what's new in AFM Studio \(r.version?.description ?? r.tag)")
        }
    }
}

/// What's new, and how to install it for this copy of the app.
struct UpdateSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let u = app.updates
        VStack(alignment: .leading, spacing: 14) {
            if let r = u.available {
                let source = Updates.sourceCheckout()
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 34)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AFM Studio \(r.version?.description ?? r.tag) is available").font(.title3.bold())
                        Text("You have \(AFMVersion.string)" + (r.publishedAt.map { ". Released \($0.formatted(date: .abbreviated, time: .omitted))." } ?? "."))
                            .foregroundStyle(.secondary)
                    }
                }
                if !r.notes.isEmpty {
                    ScrollView { MarkdownText(text: r.notes).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                        .frame(minHeight: 140, maxHeight: 320)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                }
                if let source {
                    Text("This copy was built from \(source). Run this in Terminal to update it:").font(.callout)
                    let cmd = Updates.howToUpdate(r, source: source)
                    HStack(alignment: .top) {
                        Text(cmd).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        CopyButton(text: cmd, compact: true)
                    }
                    .padding(10).background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("Download the new version, unzip it and move AFM Studio to Applications.").font(.callout)
                }
                HStack {
                    Spacer()
                    Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
                    if source == nil, let zip = r.appZip, let url = URL(string: zip.url) {
                        Button("Download") { NSWorkspace.shared.open(url) }.buttonStyle(.borderedProminent)
                    }
                    if let url = URL(string: r.url) {
                        Button("View Release") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: u.message?.contains("up to date") == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 30)).foregroundStyle(u.message?.contains("up to date") == true ? .green : .orange)
                    Text(u.message ?? "Checking…").fixedSize(horizontal: false, vertical: true)
                }
                HStack { Spacer(); Button("OK") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

/// The Updates section in Settings > General.
struct UpdateSettings: View {
    @Environment(AppState.self) private var app
    var body: some View {
        @Bindable var app = app
        Section("Updates") {
            Toggle("Check for updates once a day", isOn: $app.settings.checkForUpdates)
            Text("Asks GitHub for the latest release. Nothing about you or your use is sent.").font(.caption).foregroundStyle(.secondary)
            LabeledContent("Version \(AFMVersion.string)") {
                HStack {
                    if app.updates.checking { ProgressView().controlSize(.small) }
                    Button("Check Now") { app.updates.checkNow(showResult: false) }.disabled(app.updates.checking)
                }
            }
            if let r = app.updates.available {
                LabeledContent("\(r.version?.description ?? r.tag) is available") {
                    Button("See What's New") { app.updates.showSheet = true }
                }
            } else if let m = app.updates.message {
                Text(m).font(.caption).foregroundStyle(.secondary)
            }
            if let d = app.updates.lastChecked {
                Text("Last checked \(d.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

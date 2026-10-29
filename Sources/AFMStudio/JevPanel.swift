import SwiftUI
import AFMKit
import AFMJev

/// Jev's key, model and spending, shown on its integration card.
struct JevPanel: View {
    @ViewState private var keyInput = ""
    @ViewState private var keyStatus = ""
    @ViewState private var model = ""
    @ViewState private var usage = JevUsage()
    @ViewState private var test: IntegrationStatus?
    @ViewState private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("API key").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                if keyStatus.isEmpty {
                    SecureField("apikey_…", text: $keyInput).textFieldStyle(.roundedBorder).frame(width: 280)
                    Button("Save to Keychain") {
                        do { try JevAuth.save(keyInput); keyInput = ""; refresh() }
                        catch { keyStatus = ""; test = IntegrationStatus(connected: false, detail: AFMError.from(error).fullDescription) }
                    }
                    .disabled(keyInput.isEmpty)
                } else {
                    Text(keyStatus).font(.system(.callout, design: .monospaced))
                    Button("Remove") { JevAuth.delete(); refresh() }
                }
            }
            HStack {
                Text("Model").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                TextField("jev-latest", text: $model).textFieldStyle(.roundedBorder).frame(width: 160)
                    .onSubmit { var s = JevSettings.load(); s.model = model.isEmpty ? JevClient.defaultModel : model; s.save() }
                Text("Pin a version such as jev-1.13.0 for repeatable results.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Spent").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                Text(usage.summary).font(.callout)
                Button("Reset tally") { JevUsage.reset(); refresh() }.controlSize(.small)
            }
            HStack {
                Button(testing ? "Testing…" : "Test connection") {
                    testing = true
                    Task { test = await JevIntegration().status(); testing = false }
                }
                .disabled(testing)
                if let test {
                    Label(test.detail, systemImage: test.connected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(test.connected ? .green : .orange).font(.callout)
                }
            }
        }
        .font(.callout)
        .onAppear(perform: refresh)
    }

    func refresh() {
        let r = JevAuth.resolve()
        keyStatus = r.key.map { "\(KeychainSecret.masked($0)) · \(JevAuth.sourceDescription)" } ?? ""
        model = JevSettings.load().model
        usage = JevUsage.load()
    }
}

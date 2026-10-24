import SwiftUI
import AFMKit

struct SchemaField: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Identifiable {
        case string, integer, number, boolean, choice, list, numberList
        var id: String { rawValue }
        var title: String {
            switch self {
            case .string: "Text"
            case .integer: "Integer"
            case .number: "Number"
            case .boolean: "Yes / No"
            case .choice: "One of…"
            case .list: "List of text"
            case .numberList: "List of numbers"
            }
        }
    }
    var id = UUID()
    var name: String
    var kind: Kind = .string
    var detail: String = ""
    var choices: String = ""
    var required = true
}

enum SchemaPreset: String, CaseIterable, Identifiable {
    case contact = "Contact card", review = "Product review", event = "Event", bug = "Bug report", recipe = "Cooking recipe", custom = "Blank"
    var id: String { rawValue }

    var title: String { rawValue.replacingOccurrences(of: " ", with: "") }

    var fields: [SchemaField] {
        switch self {
        case .contact:
            [SchemaField(name: "name"), SchemaField(name: "email"), SchemaField(name: "phone", required: false),
             SchemaField(name: "company", required: false), SchemaField(name: "role", required: false)]
        case .review:
            [SchemaField(name: "product"), SchemaField(name: "rating", kind: .integer, detail: "1 to 5"),
             SchemaField(name: "sentiment", kind: .choice, choices: "positive, neutral, negative"),
             SchemaField(name: "pros", kind: .list), SchemaField(name: "cons", kind: .list)]
        case .event:
            [SchemaField(name: "title"), SchemaField(name: "date", detail: "ISO 8601 date"), SchemaField(name: "time", required: false),
             SchemaField(name: "location"), SchemaField(name: "attendees", kind: .list)]
        case .bug:
            [SchemaField(name: "summary"), SchemaField(name: "severity", kind: .choice, choices: "low, medium, high, critical"),
             SchemaField(name: "steps_to_reproduce", kind: .list), SchemaField(name: "expected"), SchemaField(name: "actual")]
        case .recipe:
            [SchemaField(name: "dish"), SchemaField(name: "servings", kind: .integer), SchemaField(name: "minutes", kind: .integer),
             SchemaField(name: "ingredients", kind: .list), SchemaField(name: "steps", kind: .list), SchemaField(name: "vegetarian", kind: .boolean)]
        case .custom:
            [SchemaField(name: "field")]
        }
    }

    var prompt: String {
        switch self {
        case .contact: "Extract the contact details from this email signature:\n\nJordan Lee | Platform Engineer\nNorthwind Labs\njordan.lee@northwind.io · +1 608 555 0142"
        case .review: "Analyze this review: \"Battery life is incredible and it charges fast, but the case scratches easily and the app is clunky. 4 stars.\""
        case .event: "Extract the event: Team offsite at Devil's Lake State Park on 2026-11-14 at 9:30 AM with Priya, Sam, and Alex."
        case .bug: "Turn this into a bug report: When I tap Export on the Reports screen the app freezes for 10 seconds and then shows a blank PDF. It should save a PDF of the report."
        case .recipe: "Create a simple weeknight recipe using butternut squash."
        case .custom: ""
        }
    }
}

struct StructuredView: View {
    @State private var preset: SchemaPreset = .review
    @State private var fields: [SchemaField] = SchemaPreset.review.fields
    @State private var schemaName = "ProductReview"
    @State private var useRawSchema = false
    @State private var rawSchema = ""
    @State private var prompt = SchemaPreset.review.prompt
    @State private var output = ""
    @State private var result: GenerationResult?
    @State private var running = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var showSwift = false

    var schemaJSON: [String: Any] {
        var props: [String: Any] = [:]
        for f in fields where !f.name.isEmpty {
            var p: [String: Any]
            switch f.kind {
            case .string: p = ["type": "string"]
            case .integer: p = ["type": "integer"]
            case .number: p = ["type": "number"]
            case .boolean: p = ["type": "boolean"]
            case .choice: p = ["type": "string", "enum": f.choices.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }]
            case .list: p = ["type": "array", "items": ["type": "string"]]
            case .numberList: p = ["type": "array", "items": ["type": "number"]]
            }
            if !f.detail.isEmpty { p["description"] = f.detail }
            props[f.name] = p
        }
        return ["type": "object", "title": schemaName, "properties": props,
                "required": fields.filter { $0.required && !$0.name.isEmpty }.map(\.name),
                "x-order": fields.filter { !$0.name.isEmpty }.map(\.name)]
    }

    var schemaText: String { useRawSchema ? rawSchema : JSONSchemaConverter.jsonText(schemaJSON) }

    var validation: String? {
        do { _ = try JSONSchemaConverter.schema(fromJSON: schemaText); return nil } catch { return AFMError.from(error).message }
    }

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PaneHeader(title: "Structured Output", subtitle: "Guaranteed-valid JSON through on-device constrained decoding.", symbol: "curlybraces.square")
                    HStack {
                        Picker("Start from", selection: $preset) { ForEach(SchemaPreset.allCases) { Text($0.rawValue).tag($0) } }
                            .frame(maxWidth: 260)
                            .onChange(of: preset) {
                                fields = preset.fields
                                schemaName = preset.title
                                prompt = preset.prompt
                                rawSchema = JSONSchemaConverter.jsonText(schemaJSON)
                            }
                        Spacer()
                        Picker("", selection: $useRawSchema) {
                            Text("Builder").tag(false)
                            Text("JSON Schema").tag(true)
                        }
                        .pickerStyle(.segmented).frame(width: 200)
                        .onChange(of: useRawSchema) { if useRawSchema { rawSchema = JSONSchemaConverter.jsonText(schemaJSON) } }
                    }
                    if useRawSchema {
                        TextEditor(text: $rawSchema)
                            .font(.system(.callout, design: .monospaced))
                            .frame(minHeight: 240)
                            .padding(6)
                            .background(.background, in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        Card(title: "Fields", symbol: "list.bullet.rectangle") {
                            LabeledContent("Type name") { TextField("", text: $schemaName) }
                            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                                GridRow {
                                    Text("Field").gridColumnAlignment(.leading)
                                    Text("Type")
                                    Text("Choices or description")
                                    Text("Req.").help("Required")
                                    Text("")
                                }
                                .font(.caption).foregroundStyle(.secondary)
                                ForEach($fields) { $f in
                                    GridRow {
                                        TextField("name", text: $f.name).frame(minWidth: 100, maxWidth: 150)
                                        Picker("", selection: $f.kind) { ForEach(SchemaField.Kind.allCases) { Text($0.title).tag($0) } }
                                            .labelsHidden().frame(width: 130)
                                        if f.kind == .choice {
                                            TextField("a, b, c", text: $f.choices).frame(minWidth: 120)
                                        } else {
                                            TextField("optional", text: $f.detail).frame(minWidth: 120)
                                        }
                                        Toggle("", isOn: $f.required).toggleStyle(.checkbox).labelsHidden().help("Required")
                                        Button { fields.removeAll { $0.id == f.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                                    }
                                }
                            }
                            Button("Add field", systemImage: "plus.circle") { fields.append(SchemaField(name: "field\(fields.count + 1)")) }
                                .buttonStyle(.borderless)
                        }
                    }
                    if let v = validation { Label(v, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
                    Text("Prompt").font(.headline)
                    InputEditor(text: $prompt, placeholder: "What should the model generate or extract?", minHeight: 120)
                    HStack {
                        if running {
                            Button("Stop", systemImage: "stop.fill") { task?.cancel() }
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Generate JSON", systemImage: "play.fill") { run() }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.return, modifiers: .command)
                                .disabled(validation != nil || prompt.isEmpty)
                        }
                        Spacer()
                        Button("Swift @Generable code", systemImage: "swift") { showSwift = true }.disabled(useRawSchema)
                        CopyButton(text: schemaText).help("Copy JSON Schema")
                    }
                }
                .padding(22)
            }
            .frame(minWidth: 440)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("JSON").font(.headline)
                    if running { Text("streaming…").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    CopyButton(text: output)
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                ScrollView {
                    Text(output.isEmpty ? " " : output)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay { if output.isEmpty && !running { ContentUnavailableView("No JSON yet", systemImage: "curlybraces", description: Text("Pick a preset and press Generate.")) } }
                if let result { ResultStats(result: result) }
            }
            .padding(22)
            .frame(minWidth: 300)
        }
        .sheet(isPresented: $showSwift) { SwiftCodeSheet(code: swiftCode) }
    }

    func run() {
        running = true; error = nil; output = ""; result = nil
        let st = schemaText, p = prompt
        task = Task {
            do {
                let schema = try JSONSchemaConverter.schema(fromJSON: st)
                let r = try await AFM.run(GenerationRequest(prompt: p, config: ModelConfig(guardrails: .permissive), schema: schema),
                                          onPartial: { s in Task { @MainActor in output = s } })
                output = r.text
                result = r
                History.append(HistoryEntry(source: "studio", kind: "structured", title: schemaName, input: p, output: r.text, seconds: r.seconds, outputTokens: r.outputTokens))
            } catch is CancellationError {
            } catch { if !Task.isCancelled { self.error = AFMError.from(error).fullDescription } }
            running = false
        }
    }

    var swiftCode: String {
        func swiftName(_ s: String) -> String {
            let parts = s.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            guard let first = parts.first else { return "value" }
            return first.lowercased() + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        }
        var enums: [String] = []
        var lines = ["import FoundationModels", "", "@Generable", "struct \(schemaName.isEmpty ? "Output" : schemaName) {"]
        for f in fields where !f.name.isEmpty {
            let n = swiftName(f.name)
            var type: String
            switch f.kind {
            case .string: type = "String"
            case .integer: type = "Int"
            case .number: type = "Double"
            case .boolean: type = "Bool"
            case .list: type = "[String]"
            case .numberList: type = "[Double]"
            case .choice:
                type = n.prefix(1).uppercased() + n.dropFirst()
                let cases = f.choices.split(separator: ",").map { swiftName($0.trimmingCharacters(in: .whitespaces)) }
                enums.append("@Generable\nenum \(type) {\n" + cases.map { "    case \($0)" }.joined(separator: "\n") + "\n}")
            }
            if !f.required { type += "?" }
            if !f.detail.isEmpty { lines.append("    @Guide(description: \(JSONRender.quote(f.detail)))") }
            if f.name != n { lines.append("    // JSON key: \(f.name)") }
            lines.append("    var \(n): \(type)")
        }
        lines.append("}")
        let usage = """

        // Usage:
        // let session = LanguageModelSession()
        // let result = try await session.respond(to: "…", generating: \(schemaName.isEmpty ? "Output" : schemaName).self)
        // print(result.content)
        """
        return (lines + enums.map { "\n" + $0 }).joined(separator: "\n") + "\n" + usage
    }
}

struct SwiftCodeSheet: View {
    let code: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Use this schema in your own Swift app").font(.headline)
            ScrollView {
                Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            HStack { Spacer(); CopyButton(text: code); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }
}

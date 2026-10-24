import SwiftUI
import AFMKit

struct RecipesView: View {
    @Environment(AppState.self) private var app
    @State private var path: [Recipe] = []
    @State private var search = ""
    @State private var editing: Recipe?

    var filtered: [Recipe] {
        guard !search.isEmpty else { return app.recipes }
        return app.recipes.filter { ($0.title + $0.summary + $0.id).localizedCaseInsensitiveContains(search) }
    }

    var categories: [String] {
        let base = ["Understand", "Write", "Extract", "Code"]
        let extra = Set(filtered.map(\.category)).subtracting(base).sorted()
        return (base + extra).filter { c in filtered.contains { $0.category == c } }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PaneHeader(title: "Recipes", subtitle: "Ready-made tasks. Long documents are chunked and combined automatically.", symbol: "wand.and.stars")
                    ForEach(categories, id: \.self) { cat in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(cat).font(.title3.weight(.semibold))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                                ForEach(filtered.filter { $0.category == cat }) { r in
                                    Button { path.append(r) } label: { RecipeCard(recipe: r) }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button(r.isBuiltin ? "Duplicate & Edit…" : "Edit…", systemImage: "pencil") {
                                                var copy = r
                                                if r.isBuiltin { copy.id = r.id + "-custom"; copy.title = r.title + " (custom)"; copy.category = "Custom"; copy.builtin = nil }
                                                editing = copy
                                            }
                                            if !r.isBuiltin {
                                                Button("Delete", systemImage: "trash", role: .destructive) {
                                                    try? RecipeBook.shared.delete(r.id); app.reloadRecipes()
                                                }
                                            }
                                        }
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Search recipes")
            .toolbar {
                Button("New Recipe", systemImage: "plus") {
                    editing = Recipe(id: "my-recipe", title: "My recipe", summary: "What it does", category: "Custom",
                                     instructions: "You are a helpful assistant.", template: "Do the task for this text.\n\nText:\n\"\"\"\n{{input}}\n\"\"\"")
                }
                Button("Reveal Recipes Folder", systemImage: "folder") { NSWorkspace.shared.open(RecipeBook.shared.userDirectory) }
            }
            .navigationDestination(for: Recipe.self) { RecipeRunView(recipe: $0) }
        }
        .sheet(item: $editing) { r in
            RecipeEditor(recipe: r) { saved in
                try? RecipeBook.shared.save(saved)
                app.reloadRecipes()
            }
        }
    }
}

struct RecipeCard: View {
    let recipe: Recipe
    @State private var hover = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: recipe.symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 36, height: 36)
                .foregroundStyle(Color.accentColor)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(recipe.title).font(.headline)
                    if recipe.isStructured { Text("JSON").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1).background(.purple.opacity(0.18), in: Capsule()) }
                    if !recipe.isBuiltin { Text("YOURS").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1).background(.green.opacity(0.18), in: Capsule()) }
                }
                Text(recipe.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hover ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.15)))
        .scaleEffect(hover ? 1.01 : 1)
        .animation(.easeOut(duration: 0.12), value: hover)
        .onHover { hover = $0 }
        .contentShape(Rectangle())
    }
}

struct RecipeRunView: View {
    let recipe: Recipe
    @Environment(AppState.self) private var app
    @State private var input = ""
    @State private var params: [String: String] = [:]
    @State private var output = ""
    @State private var result: GenerationResult?
    @State private var running = false
    @State private var progress: String?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var options = GenOptions()
    @State private var config = ModelConfig()

    var needsInput: Bool { recipe.template.contains("{{input}}") }

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: recipe.symbol).font(.title2).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading) {
                            Text(recipe.title).font(.title2.bold())
                            Text(recipe.summary).foregroundStyle(.secondary)
                        }
                    }
                    if needsInput { InputEditor(text: $input, minHeight: 240) }
                    if !recipe.params.isEmpty {
                        Card(title: "Options", symbol: "slider.horizontal.3") {
                            ForEach(recipe.params) { p in
                                if let choices = p.choices {
                                    Picker(p.label, selection: binding(p)) { ForEach(choices, id: \.self) { Text($0).tag($0) } }
                                } else {
                                    TextField(p.label, text: binding(p), prompt: Text(p.defaultValue))
                                }
                            }
                        }
                    }
                    DisclosureGroup("Advanced") {
                        Form { OptionsEditor(options: $options, config: $config, showUseCase: recipe.useCase == nil) }.formStyle(.columns).padding(.top, 6)
                    }
                    HStack {
                        if running {
                            Button("Stop", systemImage: "stop.fill") { task?.cancel() }
                            ProgressView().controlSize(.small)
                            if let progress { Text(progress).font(.callout).foregroundStyle(.secondary) }
                        } else {
                            Button("Run \(recipe.title)", systemImage: "play.fill") { run() }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.return, modifiers: .command)
                                .disabled(needsInput && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        Spacer()
                        Text("⌘↩").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(22)
            }
            .frame(minWidth: 380)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Output").font(.headline)
                    Spacer()
                    CopyButton(text: output)
                    Button("Save…", systemImage: "square.and.arrow.down") {
                        FileLoader.save(output, name: "\(recipe.id).\(recipe.isStructured ? "json" : "md")", type: recipe.isStructured ? .json : .plainText)
                    }
                    .buttonStyle(.borderless).disabled(output.isEmpty)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                ScrollView {
                    Group {
                        if recipe.isStructured {
                            Text(output).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        } else {
                            MarkdownText(text: output)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    if output.isEmpty && !running {
                        ContentUnavailableView("No output yet", systemImage: recipe.symbol, description: Text("Run the recipe to see results here."))
                    }
                }
                if let result { ResultStats(result: result) }
            }
            .padding(22)
            .frame(minWidth: 360)
        }
        .navigationTitle(recipe.title)
        .onAppear { if params.isEmpty { params = recipe.defaults() } }
    }

    func binding(_ p: RecipeParam) -> Binding<String> {
        Binding(get: { params[p.key] ?? p.defaultValue }, set: { params[p.key] = $0 })
    }

    func run() {
        running = true
        error = nil
        output = ""
        result = nil
        progress = nil
        let text = input, ps = params, o = options, c = config, r = recipe
        task = Task {
            do {
                let res = try await RecipeRunner.run(r, input: text, params: ps, options: o, config: c,
                    onPartial: { s in Task { @MainActor in output = s } },
                    onProgress: { p in Task { @MainActor in progress = p.stage } })
                output = res.text
                result = res
                History.append(HistoryEntry(source: "studio", kind: "recipe", title: r.title, input: text, output: res.text, seconds: res.seconds, outputTokens: res.outputTokens))
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = AFMError.from(error).fullDescription }
            }
            running = false
            progress = nil
        }
    }
}

struct RecipeEditor: View {
    @State var recipe: Recipe
    let onSave: (Recipe) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var paramsText = ""
    @State private var schemaText = ""
    @State private var schemaError: String?
    @State private var temperature: Double = 0.5

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Basics") {
                    TextField("ID (used by `afm run`)", text: $recipe.id)
                    TextField("Title", text: $recipe.title)
                    TextField("Summary", text: $recipe.summary)
                    TextField("Category", text: $recipe.category)
                    TextField("SF Symbol", text: $recipe.symbol)
                }
                Section("Prompt") {
                    LabeledContent("Instructions") { TextEditor(text: $recipe.instructions).frame(minHeight: 70).font(.callout) }
                    LabeledContent("Template") { TextEditor(text: $recipe.template).frame(minHeight: 90).font(.system(.callout, design: .monospaced)) }
                    Text("Use {{input}} for the text and {{key}} for each parameter. {{key_json}} turns a comma-separated value into a JSON array.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Parameters") {
                    TextEditor(text: $paramsText).frame(minHeight: 60).font(.system(.callout, design: .monospaced))
                    Text("One per line: key = default | choice 1 | choice 2").font(.caption).foregroundStyle(.secondary)
                }
                Section("Structured output (optional JSON Schema)") {
                    TextEditor(text: $schemaText).frame(minHeight: 90).font(.system(.callout, design: .monospaced))
                    if let schemaError { Text(schemaError).font(.caption).foregroundStyle(.orange) }
                }
                Section("Behavior") {
                    LabeledContent(String(format: "Temperature %.2f", temperature)) { Slider(value: $temperature, in: 0...1.5) }
                    Toggle("Permissive guardrails", isOn: Binding(get: { recipe.permissive == true }, set: { recipe.permissive = $0 }))
                    Picker("Long documents", selection: Binding(get: { recipe.strategy }, set: { recipe.long = $0 })) {
                        Text("Summarize the parts, then combine").tag(LongStrategy.reduce)
                        Text("Process each part and join in order").tag(LongStrategy.concatenate)
                        Text("Merge JSON from every part").tag(LongStrategy.merge)
                        Text("Reject input that doesn't fit").tag(LongStrategy.reject)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Recipe") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 620, height: 720)
        .onAppear {
            paramsText = recipe.params.map { p in ([p.key + " = " + p.defaultValue] + (p.choices ?? []).filter { $0 != p.defaultValue }).joined(separator: " | ") }.joined(separator: "\n")
            schemaText = recipe.schema.map { JSONRender.pretty(json: $0) } ?? ""
            temperature = recipe.temperature ?? 0.5
        }
    }

    func save() {
        recipe.params = paramsText.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = parts.first, let eq = first.firstIndex(of: "=") else { return nil }
            let key = first[..<eq].trimmingCharacters(in: .whitespaces)
            let def = first[first.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let choices = parts.count > 1 ? [def] + parts.dropFirst() : nil
            return RecipeParam(key: key, label: key.replacingOccurrences(of: "_", with: " ").capitalized, defaultValue: def, choices: choices)
        }
        let s = schemaText.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { recipe.schema = nil } else {
            do {
                _ = try JSONSchemaConverter.schema(fromJSON: Recipe.render(s, Dictionary(uniqueKeysWithValues: recipe.params.map { ($0.key, $0.defaultValue) })))
                recipe.schema = s
            } catch {
                schemaError = AFMError.from(error).message
                return
            }
        }
        recipe.temperature = temperature
        recipe.builtin = nil
        onSave(recipe)
        dismiss()
    }
}

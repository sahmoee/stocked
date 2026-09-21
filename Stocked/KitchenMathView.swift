import SwiftUI

struct KitchenMathView: View {
    @Environment(AppSession.self) private var session
    @State private var query = ""
    private var tools: [KitchenMathTool] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return KitchenMathTool.allCases.filter { value.isEmpty || ($0.title + " " + $0.subtitle).localizedStandardContains(value) }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("Practical calculations for shopping, baking and meal prep. Your inputs stay on this device.")
                    .font(.stocked(.body)).foregroundStyle(session.themeSecondaryText)
                StockedSearchField(text: $query, prompt: "Find a calculation")
                if tools.isEmpty {
                    ToolboxEmptyState(icon: "magnifyingglass", title: "No matching calculations", message: "Try package, pan, dough, portion or price.")
                    Button("Clear search") { query = "" }.buttonStyle(StockedSecondaryButtonStyle())
                }
                ForEach(tools) { tool in
                    NavigationLink { KitchenMathCalculatorView(tool: tool) } label: {
                        ToolboxCard {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: tool.icon).font(.stocked(.title3)).frame(width: 28).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(tool.title).font(.stocked(.headline))
                                    Text(tool.subtitle).font(.stocked(.subheadline)).foregroundStyle(session.themeSecondaryText)
                                }.fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.stocked(.footnote)).accessibilityHidden(true)
                            }.frame(minHeight: 44)
                        }
                    }.buttonStyle(PressableStyle())
                }
            }.padding(18)
        }
        .stockedScreen().foregroundStyle(session.themeTextColor).tint(session.accentColor)
        .navigationTitle("Kitchen Math").navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct KitchenMathDraft: Codable {
    var inputs: [String: String] = [:]
    var originalRound = false
    var replacementRound = false
    var currency = Locale.current.currency?.identifier ?? "USD"
    var quantityUnit = "g"
    var example = false
}

struct KitchenMathCalculatorView: View {
    let tool: KitchenMathTool
    @Environment(AppSession.self) private var session
    @SceneStorage private var savedDraft: String
    @State private var draft = KitchenMathDraft()
    @State private var showReset = false
    @State private var loaded = false
    @FocusState private var focused: String?

    init(tool: KitchenMathTool) {
        self.tool = tool
        _savedDraft = SceneStorage(wrappedValue: "", "kitchenMath.\(tool.rawValue).draft.v1")
        var initial = KitchenMathDraft()
        if tool == .pans { initial.quantityUnit = "cm" }
        _draft = State(initialValue: initial)
    }

    private var fields: [KitchenMathField] {
        tool.visibleFields(originalRound: draft.originalRound, replacementRound: draft.replacementRound)
    }
    private var values: [String: Double] { draft.inputs.compactMapValues { KitchenMathCore.parse($0) } }
    private var result: KitchenMathResult? {
        KitchenMathCore.evaluate(tool, values: values, originalRound: draft.originalRound, replacementRound: draft.replacementRound)
    }
    private var hasInput: Bool { draft.inputs.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    private var emptyCount: Int { fields.filter { (draft.inputs[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(tool.subtitle).font(.stocked(.body)).foregroundStyle(session.themeSecondaryText)
                if draft.example {
                    Label("Example numbers — replace them with your own.", systemImage: "info.circle")
                        .font(.stocked(.subheadline)).foregroundStyle(session.themeSecondaryText)
                }
                choices
                ToolboxCard {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(fields) { field in input(field) }
                    }
                }
                if let result {
                    resultCard(result)
                    ShareLink(item: shareText(result)) {
                        Label("Share calculation", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }.buttonStyle(StockedSecondaryButtonStyle())
                } else {
                    ToolboxCard {
                        Label(emptyCount > 0 ? "Enter \(emptyCount) remaining \(emptyCount == 1 ? "amount" : "amounts") to calculate." : "Check the marked amounts. If they are valid, use a smaller range of quantities.",
                              systemImage: emptyCount > 0 ? "equal.circle" : "exclamationmark.circle")
                            .font(.stocked(.body)).foregroundStyle(session.themeSecondaryText)
                    }
                }
                DisclosureGroup("How this works") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(tool.guidance)
                        if let result { Text(result.formula) }
                        Text("Enter numbers without thousands separators. Calculations update as you type; your kitchen records are not changed.")
                    }.font(.stocked(.subheadline)).foregroundStyle(session.themeSecondaryText).padding(.top, 8)
                }.font(.stocked(.headline))
                Button(hasInput ? "Replace with example" : "Try an example") {
                    if hasInput { showReset = true } else { loadExample() }
                }.buttonStyle(StockedSecondaryButtonStyle())
            }
            .padding(18)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .stockedScreen().foregroundStyle(session.themeTextColor).tint(session.accentColor)
        .navigationTitle(tool.title).navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Clear all inputs", role: .destructive) { showReset = true }
                        .disabled(!hasInput)
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Calculation options")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Button("Next amount") { focusNext() }
                Spacer()
                Button("Done") { focused = nil }
            }
        }
        .confirmationDialog("Replace current amounts?", isPresented: $showReset, titleVisibility: .visible) {
            Button("Use example amounts") { loadExample() }
            Button("Clear all inputs", role: .destructive) { draft.inputs = [:]; draft.example = false; focused = nil; persist() }
            Button("Keep my amounts", role: .cancel) { }
        } message: { Text("Only this calculation’s inputs change. Inventory, recipes and groceries are untouched.") }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let data = savedDraft.data(using: .utf8), let restored = try? JSONDecoder().decode(KitchenMathDraft.self, from: data) {
                draft = restored
            }
        }
        .onChange(of: draft.originalRound) { _, _ in persist() }
        .onChange(of: draft.replacementRound) { _, _ in persist() }
        .onChange(of: draft.currency) { _, _ in persist() }
        .onChange(of: draft.quantityUnit) { _, _ in persist() }
    }

    @ViewBuilder private var choices: some View {
        if tool.usesCurrency {
            Picker("Currency", selection: $draft.currency) {
                ForEach(Array(Set([draft.currency, "USD", "CAD", "EUR", "GBP", "AUD"])).sorted(), id: \.self) { Text($0).tag($0) }
            }.font(.stocked(.body))
        }
        if [.unitPrice, .packages, .ratio, .pans].contains(tool) {
            Picker("Measurement unit", selection: $draft.quantityUnit) {
                ForEach(tool == .pans ? ["cm", "in"] : ["g", "mL", "oz", "lb", "items"], id: \.self) { Text($0).tag($0) }
            }.font(.stocked(.body))
            Text(tool == .pans ? "All dimensions must use this unit." : "Use this same unit for every quantity. Changing the label does not convert amounts.")
                .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
        }
        if tool == .pans {
            Toggle("Original pan is round", isOn: $draft.originalRound).font(.stocked(.body))
            Toggle("New pan is round", isOn: $draft.replacementRound).font(.stocked(.body))
            Text("For round pans, enter the diameter. Width is hidden because it is not used.")
                .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
        }
    }

    private func input(_ field: KitchenMathField) -> some View {
        let raw = draft.inputs[field.id] ?? ""
        let problem = raw.isEmpty ? nil : field.problem(KitchenMathCore.parse(raw))
        let unit = field.unit == "money" ? draft.currency : (field.unit == "same unit" ? draft.quantityUnit : field.unit)
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(field.title) (\(unit))").font(.stocked(.subheadline)).fontWeight(.semibold)
            TextField(field.allowsZero ? "0 or more" : "Amount", text: Binding(get: { draft.inputs[field.id] ?? "" }, set: {
                draft.inputs[field.id] = String($0.prefix(32)); draft.example = false; persist()
            }))
                .keyboardType(field.whole ? .numberPad : .decimalPad)
                .focused($focused, equals: field.id)
                .font(.stocked(.body)).monospacedDigit()
                .accessibilityLabel("\(field.title), \(unit)")
                .accessibilityHint(problem ?? (field.whole ? "Enter a whole number." : "Enter a number without thousands separators."))
                .onSubmit { focusNext() }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(.stocked(.footnote)).foregroundStyle(session.themeTextColor)
                    .accessibilityLabel("\(field.title): \(problem)")
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func resultCard(_ result: KitchenMathResult) -> some View {
        ToolboxCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Result", systemImage: "equal.circle.fill").font(.stocked(.headline)).foregroundStyle(session.accentColor)
                    .accessibilityAddTraits(.isHeader)
                Text(result.summary).font(.stocked(.title3)).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                ForEach(result.outputs) { output in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(output.label).font(.stocked(.subheadline)).foregroundStyle(session.themeSecondaryText)
                        Text(display(output)).font(.stocked(.title3)).monospacedDigit()
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }.accessibilityElement(children: .combine)
                }
                if tool == .packages && values["price"] == 0 {
                    Label("Cost is unknown because the package price is zero.", systemImage: "info.circle")
                        .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                }
            }
        }
    }

    private func display(_ output: KitchenMathOutput) -> String {
        let number = KitchenMathCore.number(output.value, decimals: output.decimals)
        let unit = output.unit == "money" ? draft.currency : (output.unit == "units" ? draft.quantityUnit : output.unit)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }
    private func shareText(_ result: KitchenMathResult) -> String {
        let amounts = fields.map { field in
            let unit = field.unit == "money" ? draft.currency : (field.unit == "same unit" ? draft.quantityUnit : field.unit)
            return "\(field.title): \(draft.inputs[field.id] ?? "") \(unit)"
        }
        let shapes = tool == .pans ? ["Original pan: \(draft.originalRound ? "round" : "rectangular")", "New pan: \(draft.replacementRound ? "round" : "rectangular")"] : []
        return (["Stocked · \(tool.title)"] + shapes + amounts + ["", result.summary] + result.outputs.map { "\($0.label): \(display($0))" } + ["", result.formula, tool.guidance]).joined(separator: "\n")
    }
    private func focusNext() {
        guard let index = fields.firstIndex(where: { $0.id == focused }), index + 1 < fields.count else { focused = nil; return }
        focused = fields[index + 1].id
    }
    private func loadExample() {
        draft.inputs = Dictionary(uniqueKeysWithValues: tool.fields.map { ($0.id, KitchenMathCore.input($0.example)) })
        draft.example = true; focused = nil; persist()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(draft), let value = String(data: data, encoding: .utf8) { savedDraft = value }
    }
}

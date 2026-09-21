// QuantityInputView.swift — reusable quantity editor for Stocked.
//
// Drop into the Add Item sheet, the barcode confirm sheet, and receipt review so every entry
// point supports flexible amounts. Type naturally ("6 cans of 8 oz", "half a bag of cheese")
// or adjust with the steppers/pickers. Binds to a ParsedAmount.
//
//     @State private var qty = ParsedAmount(count: 1, container: "item", amountEach: nil, unitEach: nil, item: "")
//     QuantityInputView(quantity: $qty)

import SwiftUI

struct QuantityInputView: View {
    @Environment(\.stockedLayout) private var layoutMetrics
    @Binding var quantity: ParsedAmount
    @State private var raw: String = ""
    @State private var validationMessage: String?
    @FocusState private var focused: Bool

    private let containerOptions = ["item", "bag", "can", "box", "pack", "jar", "bottle",
                                    "carton", "bunch", "case", "loaf", "tub", "bar", "dozen"]
    private let unitOptions = ["", "oz", "fl oz", "lb", "g", "kg", "ml", "l", "cup", "gallon", "quart", "pint"]

    var body: some View {
        let controlLayout = layoutMetrics.prefersVerticalControls || layoutMetrics.textScale > 1.3
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
        VStack(alignment: .leading, spacing: 10) {
            // Natural-language field
            HStack {
                Image(systemName: "text.cursor").foregroundStyle(.secondary)
                TextField("e.g. 6 cans of 8 oz, half a bag", text: $raw)
                    .textFieldStyle(StockedThemedTextFieldStyle())
                    .focused($focused)
                    .onSubmit { apply(raw) }
                if !raw.isEmpty {
                    Button { apply(raw) } label: { Image(systemName: "arrow.right.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tint)
                }
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(.stocked(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Structured, editable controls
            controlLayout {
                Stepper(value: $quantity.count, in: 0...QuantityParser.maximumAmount, step: stepSize) {
                    HStack(spacing: 4) {
                        Text("Qty").foregroundStyle(.secondary).font(.stocked(.subheadline))
                        Text(ParsedAmount.trim(quantity.count)).font(.stocked(.headline).monospacedDigit())
                    }
                }
                .fixedSize()

                Menu {
                    ForEach(containerOptions, id: \.self) { opt in
                        Button(opt == "item" ? "each / item" : opt) { quantity.container = opt }
                    }
                } label: {
                    Label(quantity.container == "item" ? "item" : quantity.container, systemImage: "shippingbox")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            // "each amount" (e.g. 6 cans of 8 oz)
            controlLayout {
                Text("Each").foregroundStyle(.secondary).font(.stocked(.subheadline))
                TextField("amt", value: Binding(
                    get: { quantity.amountEach ?? 0 },
                    set: { value in
                        guard value.isFinite, value >= 0, value <= QuantityParser.maximumAmount else {
                            validationMessage = "Enter a finite, nonnegative package size."; return
                        }
                        validationMessage = nil; quantity.amountEach = value == 0 ? nil : value
                    }
                ), format: .number)
                    .frame(minWidth: 72).textFieldStyle(StockedThemedTextFieldStyle())
                    .multilineTextAlignment(.trailing)
                Picker("", selection: Binding(
                    get: { quantity.unitEach ?? "" },
                    set: { quantity.unitEach = $0.isEmpty ? nil : $0 }
                )) {
                    ForEach(unitOptions, id: \.self) { u in Text(u.isEmpty ? "—" : u).tag(u) }
                }
                .labelsHidden().frame(minWidth: 90, alignment: .leading)
                Spacer()
            }

            // Live summary
            Text(quantity.display)
                .font(.stocked(.footnote).weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .onAppear { if raw.isEmpty { raw = quantity.item.isEmpty ? "" : quantity.display } }
    }

    private var stepSize: Double { quantity.count < 1 ? 0.25 : 1 }

    private func apply(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var parsed = QuantityParser.parse(text)
        validationMessage = parsed.validationMessage
        guard parsed.validationMessage == nil else { return }
        // Preserve any item name already set if the parse didn't find one.
        if parsed.item.isEmpty { parsed.item = quantity.item }
        quantity = parsed
        focused = false
    }
}

// MARK: - Compact natural-language amount field
// A one-line "type it how you'd say it" field for the Add Item sheet and barcode confirm.
// Parses "6 cans of 8 oz", "half a bag of cheese", "4 bags of chips" via QuantityParser and
// hands the structured result to the host, which maps it onto its own state.
struct NaturalQuantityField: View {
    @Environment(AppSession.self) var session
    var placeholder: String = "Type it: 6 cans of 8 oz, half a bag…"
    let onParse: (ParsedAmount) -> Void
    @State private var raw = ""
    @State private var validationMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .scaledFont(13).foregroundStyle(Color.stockedGold)
            TextField(placeholder, text: $raw)
                .textFieldStyle(.plain)
                .scaledFont(14)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { apply() }
            if !raw.isEmpty {
                Button { apply() } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .scaledFont(18).foregroundStyle(Color.stockedGold)
                }.buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        if let validationMessage {
            Label(validationMessage, systemImage: "exclamationmark.circle")
                .scaledFont(12).foregroundStyle(session.themeSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        }
    }

    private func apply() {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let parsed = QuantityParser.parse(t)
        validationMessage = parsed.validationMessage
        guard parsed.validationMessage == nil else { return }
        onParse(parsed)
        raw = ""
        focused = false
        HapticManager.select()
    }
}

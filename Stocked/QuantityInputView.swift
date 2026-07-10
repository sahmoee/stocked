// QuantityInputView.swift — reusable quantity editor for Stocked.
//
// Drop into the Add Item sheet, the barcode confirm sheet, and receipt review so every entry
// point supports flexible amounts. Type naturally ("6 cans of 8 oz", "half a bag of cheese")
// or adjust with the steppers/pickers. Binds to a StockedAmount.
//
//     @State private var qty = StockedAmount(count: 1, container: "item", amountEach: nil, unitEach: nil, item: "")
//     QuantityInputView(quantity: $qty)

import SwiftUI

struct QuantityInputView: View {
    @Binding var quantity: StockedAmount
    @State private var raw: String = ""
    @FocusState private var focused: Bool

    private let containerOptions = ["item", "bag", "can", "box", "pack", "jar", "bottle",
                                    "carton", "bunch", "case", "loaf", "tub", "bar", "dozen"]
    private let unitOptions = ["", "oz", "fl oz", "lb", "g", "kg", "ml", "l", "cup", "gallon", "quart", "pint"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Natural-language field
            HStack {
                Image(systemName: "text.cursor").foregroundStyle(.secondary)
                TextField("e.g. 6 cans of 8 oz, half a bag", text: $raw)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { apply(raw) }
                if !raw.isEmpty {
                    Button { apply(raw) } label: { Image(systemName: "arrow.right.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tint)
                }
            }

            // Structured, editable controls
            HStack(spacing: 12) {
                Stepper(value: $quantity.count, in: 0...9999, step: stepSize) {
                    HStack(spacing: 4) {
                        Text("Qty").foregroundStyle(.secondary).font(.subheadline)
                        Text(StockedAmount.trim(quantity.count)).font(.headline.monospacedDigit())
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
            HStack(spacing: 8) {
                Text("Each").foregroundStyle(.secondary).font(.subheadline)
                TextField("amt", value: Binding(
                    get: { quantity.amountEach ?? 0 },
                    set: { quantity.amountEach = $0 == 0 ? nil : $0 }
                ), format: .number)
                    .frame(width: 64).textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                Picker("", selection: Binding(
                    get: { quantity.unitEach ?? "" },
                    set: { quantity.unitEach = $0.isEmpty ? nil : $0 }
                )) {
                    ForEach(unitOptions, id: \.self) { u in Text(u.isEmpty ? "—" : u).tag(u) }
                }
                .labelsHidden().frame(width: 90)
                Spacer()
            }

            // Live summary
            Text(quantity.display)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .onAppear { if raw.isEmpty { raw = quantity.item.isEmpty ? "" : quantity.display } }
    }

    private var stepSize: Double { quantity.count < 1 ? 0.25 : 1 }

    private func apply(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var parsed = QuantityParser.parse(text)
        // Preserve any item name already set if the parse didn't find one.
        if parsed.item.isEmpty { parsed.item = quantity.item }
        quantity = parsed
        focused = false
    }
}

import SwiftUI

struct GroceryPantrySelection: Identifiable {
    var id: UUID { original.id }
    let original: LocalGroceryItem
    var included = true
    var quantity: Int
    var storage: StorageCategory
    var subZone: String?
    var initialStorage: StorageCategory
}

struct GroceryPantryReviewContext: Identifiable {
    let id = UUID()
    var selections: [GroceryPantrySelection]
}

/// Reviewing a purchase never changes either list until the final confirmation.
struct GroceryPantryReviewView: View {
    @Environment(AppSession.self) private var session
    let context: GroceryPantryReviewContext
    let onContinue: ([GroceryPantrySelection]) -> Void
    let onCancel: () -> Void
    @State private var selections: [GroceryPantrySelection]

    init(context: GroceryPantryReviewContext,
         onContinue: @escaping ([GroceryPantrySelection]) -> Void,
         onCancel: @escaping () -> Void) {
        self.context = context
        self.onContinue = onContinue
        self.onCancel = onCancel
        // A sheet's stable context deliberately seeds its own editable review draft.
        _selections = State(initialValue: context.selections)
    }

    private var selected: [GroceryPantrySelection] { selections.filter(\.included) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Choose what to put away. Unselected items stay on your grocery list. Quantities are containers; package sizes stay with each item.")
                        .foregroundStyle(session.themeSecondaryText)
                }
                ForEach($selections) { $selection in
                    Section {
                        Toggle(selection.original.name.displayNormalized, isOn: $selection.included)
                        if !selection.original.sizeText.isEmpty {
                            Text(selection.original.sizeText).foregroundStyle(session.themeSecondaryText)
                        }
                        if selection.included {
                            Stepper("Quantity: \(selection.quantity)", value: $selection.quantity,
                                    in: 1...max(999, selection.original.quantity))
                            Picker("Put away in", selection: $selection.storage) {
                                ForEach(StorageCategory.allCases, id: \.self) { category in
                                    Text(category.displayName).tag(category)
                                }
                            }
                            if let subZone = selection.subZone, !subZone.isEmpty {
                                Text("Previous location: \(subZone)")
                                    .foregroundStyle(session.themeSecondaryText)
                            }
                        }
                    }
                    .listRowBackground(session.themeCardColor)
                }
            }
            .scrollContentBackground(.hidden)
            .background(session.themeBgColor)
            .navigationTitle("Put groceries away")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue (\(selected.count))") { onContinue(selected) }
                        .disabled(selected.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

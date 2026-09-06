// TappableEditText.swift
// A universal "tap to edit" component. Displays as styled text; taps into an
// inline text field (with optional food or recipe predictive text).
// Used for inventory item names, grocery item names, and recipe titles.
//
// USAGE:
//   TappableEditText(text: $item.name, mode: .food)           // food predictive
//   TappableEditText(text: $recipe.title, mode: .recipe)      // recipe predictive
//   TappableEditText(text: $name, mode: .plain)               // plain editing
import SwiftUI

enum TappableEditMode {
    case food       // FoodPredictiveTextField — IngredientDatabase + inventory
    case recipe     // RecipePredictiveTextField — RecipeDatabase + online
    case plain      // Standard TextField
}

struct TappableEditText: View {
    @Environment(AppSession.self) var session
    @Binding var text: String
    var mode:        TappableEditMode = .food
    var font:        Font             = .system(size: 15, weight: .semibold, design: .serif)
    var color:       Color?           = nil
    var placeholder: String           = "Tap to edit"
    var onCommit:    (() -> Void)?    = nil

    @State private var isEditing = false
    @FocusState private var focused: Bool

    var displayColor: Color { color ?? session.themeTextColor }

    var body: some View {
        Group {
            if isEditing {
                editField
            } else {
                displayText
            }
        }
    }

    // MARK: - Display mode (tap to enter edit)
    private var displayText: some View {
        HStack(spacing: 4) {
            Text(text.isEmpty ? placeholder : text)
                .font(font)
                .foregroundStyle(text.isEmpty ? displayColor.opacity(0.35) : displayColor)
            Image(systemName: "pencil")
                .scaledFont(9)
                .foregroundStyle(displayColor.opacity(0.25))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeIn(duration: 0.15)) { isEditing = true }
            Task {
                try? await Task.sleep(nanoseconds: 50000000)
                focused = true
            }
        }
    }

    // MARK: - Edit mode
    @ViewBuilder
    private var editField: some View {
        switch mode {
        case .food:
            FoodPredictiveTextField(
                placeholder: placeholder,
                text: $text,
                onCommit: {
                    withAnimation { isEditing = false }
                    onCommit?()
                }
            )
            .focused($focused)

        case .recipe:
            RecipePredictiveTextField(
                placeholder: placeholder,
                text: $text,
                form: .constant(AddRecipeForm()),
                onCommit: {
                    withAnimation { isEditing = false }
                    onCommit?()
                },
                onSelect: { _ in
                    withAnimation { isEditing = false }
                    onCommit?()
                }
            )
            .focused($focused)

        case .plain:
            TextField(placeholder, text: $text)
                .font(font)
                .foregroundStyle(displayColor)
                .focused($focused)
                .onSubmit {
                    withAnimation { isEditing = false }
                    onCommit?()
                }
        }
    }
}

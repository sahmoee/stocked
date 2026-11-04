// StockedControls.swift — WIDGET EXTENSION TARGET ONLY.
// Control Center / Lock Screen / Action button controls. Each one opens an existing
// stocked:// route that StockedApp.onOpenURL already handles (grocery, inventory, cook),
// so no new app-side code or shared intents are needed.
import WidgetKit
import SwiftUI
import AppIntents

private enum StockedControlURL {
    static let grocery = URL(string: "stocked://grocery")!
    static let pantry = URL(string: "stocked://inventory")!
    static let cook = URL(string: "stocked://cook")!
}

struct GroceryListControl: ControlWidget {
    static let kind = "com.sowens.Stocked.control.grocery"
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenURLIntent(StockedControlURL.grocery)) {
                Label("Grocery List", systemImage: "cart")
            }
        }
        .displayName("Grocery List")
        .description("Open your Stocked grocery list.")
    }
}

struct PantryControl: ControlWidget {
    static let kind = "com.sowens.Stocked.control.pantry"
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenURLIntent(StockedControlURL.pantry)) {
                Label("Pantry", systemImage: "refrigerator")
            }
        }
        .displayName("Pantry")
        .description("Open your Stocked pantry.")
    }
}

struct CookControl: ControlWidget {
    static let kind = "com.sowens.Stocked.control.cook"
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenURLIntent(StockedControlURL.cook)) {
                Label("Cook", systemImage: "frying.pan")
            }
        }
        .displayName("Cook")
        .description("Open Cook in Stocked.")
    }
}

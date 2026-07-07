// StockedDefaultsKeys.swift — one registry for UserDefaults keys.
// ─────────────────────────────────────────────────────────────────────────────
// Raw string literals for defaults keys were scattered across files (cache index,
// appleUserID, etc.), which invites typos and silent collisions. New keys go here.
//
// Adoption status: RecipeImportAI's cache keys use this now. Migrating the older
// literals (appleUserID, flags) is mechanical but spread across files — tracked in
// CODE_HEALTH.md to do with a compiler.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

enum DefaultsKey {
    /// Index of cached AI recipe-import results (most-recent-first).
    static let recipeImportCacheIndex = "recipeImportAICacheIndex"
    /// Prefix for text-hash-keyed cached imports.
    static let recipeImportCacheTextPrefix = "recipeImportAICache.t."
    /// Prefix for source-URL-keyed cached imports.
    static let recipeImportCacheURLPrefix = "recipeImportAICache.u."

    // ── Kitchen Toolbox ──────────────────────────────────────────────────────
    /// Saved grocery list templates (Kitchen Toolbox → List Templates).
    static let groceryTemplates = "toolbox_grocery_templates_v1"
    /// Monthly grocery budget in dollars (Kitchen Toolbox → Grocery Budget).
    static let monthlyGroceryBudget = "toolbox_monthly_budget_v1"
}

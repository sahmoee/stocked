import SwiftUI

/// Preview never saves, shops, or starts cooking implicitly. The existing editor
/// commits a UserRecipe; its existing detail then owns all inter-hub actions.
struct RecipeFinderPreview: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let hit: FinderHit
    @State private var showBrowser = false
    @State private var draft: ImportDraft?
    @State private var imported: UserRecipe?
    @State private var showImported = false
    @State private var importError: String?
    private struct ImportDraft: Identifiable { let id = UUID(); var form: AddRecipeForm }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CachedAsyncImage(url: hit.recipe.imageURL ?? "", imageData: hit.recipe.imageData,
                                     height: 230, resolveName: hit.recipe.title, resolveCategory: hit.recipe.cuisine)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    Text(hit.recipe.title).font(.stockedSerif(30, weight: .bold, relativeTo: .title))
                    Label(hit.recipe.sourceName ?? "Original publisher", systemImage: "globe")
                        .font(.stocked(.headline)).foregroundStyle(session.themeSecondaryText)
                    if let time = hit.record.totalMinutes { Label("\(time) min total", systemImage: "clock").font(.stocked(.body)) }
                    if let rating = hit.record.rating {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill").foregroundStyle(session.themeContrastAccent)
                        if let count = hit.record.ratingCount {
                            Text("\(count) \(hit.publisherRatingCount == nil ? "recorded" : "publisher") ratings").font(.stocked(.caption))
                        }
                    }
                    if !hit.recipe.description.isEmpty { Text(hit.recipe.description).font(.stocked(.body)) }
                    if hit.record.required > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Your kitchen", systemImage: "refrigerator").font(.stocked(.headline))
                            Text("You have \(hit.record.have) of \(hit.record.required) ingredients")
                            if hit.record.missing > 0 { Text("Missing \(hit.record.missing) ingredients") }
                            if hit.record.uncertain > 0 { Text("Check \(hit.record.uncertain) quantities before cooking.") }
                        }.font(.stocked(.body)).padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RecipeCardStyle.surface(isDark: session.isDarkMode), in: RoundedRectangle(cornerRadius: 18))
                    }
                    if let importError { Text(importError).font(.stocked(.body)).foregroundStyle(session.themeSecondaryText) }
                    Button { showBrowser = true } label: {
                        Label("View Original Recipe", systemImage: "safari")
                            .frame(maxWidth: .infinity, minHeight: 48).padding(8)
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(session.themeTextColor))
                    }.buttonStyle(.plain).disabled(RecipeBrowserPolicy.url(hit.recipe.sourceURL ?? "") == nil)
                    Button(action: prepareImport) {
                        Label("Import to STOCKED", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity, minHeight: 48).padding(8)
                            .foregroundStyle(Color.stockedWhite).background(Color.stockedCharcoal, in: RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(.plain)
                    Text("Review the recipe before saving. Then use it with Inventory, Grocery List, Cook, and My Collection. The original publisher stays credited and linked.")
                        .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                }.font(.stocked(.body)).padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .background(session.themeBgColor).foregroundStyle(session.themeTextColor)
            .navigationTitle("Recipe preview").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close", systemImage: "xmark") { dismiss() } } }
            .sheet(isPresented: $showBrowser) {
                if let url = RecipeBrowserPolicy.url(hit.recipe.sourceURL ?? "") { RecipeBrowserView(initialURL: url) }
            }
            .sheet(item: $draft, onDismiss: { if imported != nil { showImported = true } }) { draft in
                CreateRecipeView(prefill: draft.form, prefillSource: hit.recipe.sourceName ?? "Original publisher",
                                 allowAIStructuring: false, onSaved: { imported = $0; AppAnalytics.shared.log(.recipeImported) })
                    .environment(session)
            }
            .navigationDestination(isPresented: $showImported) {
                if let imported { UserRecipeDetailView(recipe: imported).environment(session) }
            }
        }.stockedThemeEnvironment().qaScreen("Recipe Preview")
    }

    private func prepareImport() {
        guard let entry = hit.databaseEntry, !entry.ingredients.isEmpty, !entry.steps.isEmpty else {
            importError = "We couldn’t import this recipe. You can still view the original recipe."; return
        }
        var form = AddRecipeForm(); form.fill(from: entry)
        if let existing = session.guestStore.userRecipes.first(where: {
            FinderWebPolicy.identity($0.sourceURL ?? "") == FinderWebPolicy.identity(entry.sourceURL)
        }) {
            imported = existing; showImported = true; return
        }
        form.notes = RecipeImportQuality.summary(form)
        if let similar = RecipeImportQuality.duplicate(form, in: session.guestStore.userRecipes) {
            form.notes = "A saved recipe has a similar title: ‘\(similar.title)’. Review the source before saving.\n" + form.notes
        }
        draft = ImportDraft(form: form)
    }
}

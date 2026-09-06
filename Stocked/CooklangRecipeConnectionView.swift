import SwiftUI

struct CooklangRecipeConnectionView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PortableRecipeFileDraft?
    var body: some View {
        NavigationStack {
            CooklangConnectionPanel(background: session.themeBgColor, card: session.themeCardColor,
                foreground: session.themeTextColor, secondary: session.themeSecondaryText, accent: session.themeButtonColor) { recipe in
                    let task = Task.detached(priority: .utility) { try CooklangPrivateImport.draft(recipe) }
                    let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                    try Task.checkCancellation(); draft = value
                }
                .navigationTitle("Cooklang community").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .sheet(item: $draft) { value in PortableRecipeFilesView(incomingDraft: value, privateImportsOnly: true).environment(session) }
        }
    }
}

nonisolated enum CooklangPrivateImport {
    static func draft(_ recipe: CooklangFederationRecipe) throws -> PortableRecipeFileDraft {
        try Task.checkCancellation()
        var value = try PortableRecipeFileAdapter.parse(Data(recipe.content.utf8), filename: recipe.filename)
        if value.form.title == URL(fileURLWithPath: recipe.filename).deletingPathExtension().lastPathComponent { value.form.title = recipe.title }
        // Original Cooklang metadata wins. Federation/feed credit is additional attribution.
        if value.form.sourceURL.isEmpty { value.form.sourceURL = (recipe.sourceURL ?? recipe.enclosureURL)?.absoluteString ?? "" }
        if value.form.imageURL.isEmpty { value.form.imageURL = recipe.imageURL?.absoluteString ?? "" }
        if value.sourceName == "Cooklang file" { value.sourceName = URL(string: value.form.sourceURL)?.host ?? "Cooklang Federation" }
        value.form.notes += (value.form.notes.isEmpty ? "" : "\n\n") + recipe.attributionNote
        value.form.portableSource?.catalogueSharingApproved = false
        value.form.portableSource?.originalSourceURL = value.form.sourceURL.isEmpty ? nil : value.form.sourceURL
        try value.form.portableSource?.validateSize()
        value.warnings.append("This is an index-provided copy. Review source credits, amounts and any advanced Cooklang warnings. Saving here is private and never approves public catalogue sharing.")
        try Task.checkCancellation()
        return value
    }
}

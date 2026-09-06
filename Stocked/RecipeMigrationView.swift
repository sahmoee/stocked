import SwiftUI
import UniformTypeIdentifiers

struct RecipeMigrationView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var review = RecipeMigrationReview()
    @State private var showFiles = false
    @State private var editing: RecipeMigrationCandidate?
    @State private var confirmSave = false
    @State private var confirmUndo = false
    @State private var showAll = false

    private var selectedCount: Int { review.candidates.filter { $0.selected && $0.duplicateReason == nil && $0.requiredReview == nil && $0.status != "Saved" }.count }
    private var busy: Bool { review.isLoading || review.isSaving }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Bring your recipe collection")
                        .font(.stocked(.title2))
                    Text("Choose a recipe export from Mealie, Tandoor, Paprika or Recipya, or several recipe JSON files. Stocked reads supported ZIP, gzip and JSON files on this device. It never signs in to another service or pays for AI.")
                        .font(.stocked(.body)).foregroundStyle(session.themeSecondaryText)
                    Button { showFiles = true } label: {
                        Label("Choose exports or recipe files", systemImage: "folder")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).tint(session.themeButtonColor).disabled(busy)
                    Text("Review up to 250 recipes at a time. Saving adds selected recipes privately to your household; it does not replace your collection or publish to the Stocked catalogue.")
                        .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                    if busy {
                        ProgressView(review.isLoading ? "Reading recipe exports…" : "Applying one recipe at a time…")
                        Button("Stop here") { review.stop() }.buttonStyle(.bordered)
                    }
                    if !review.message.isEmpty {
                        Text(review.message).font(.stocked(.body)).accessibilityAddTraits(.updatesFrequently)
                    }
                    if !review.warnings.isEmpty {
                        DisclosureGroup("Import notes (\(review.warnings.count))") {
                            ForEach(Array(review.warnings.enumerated()), id: \.offset) { _, warning in
                                Text(warning).font(.stocked(.footnote)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                            }
                        }
                    }
                    if !review.candidates.isEmpty {
                        HStack {
                            Text("\(selectedCount) selected of \(review.candidates.count)").font(.stocked(.headline))
                            Spacer()
                            Button("Clear selection") {
                                for index in review.candidates.indices { review.candidates[index].selected = false }
                            }.disabled(busy)
                        }
                        LazyVStack(spacing: 12) {
                            ForEach(Array(review.candidates.prefix(showAll ? 250 : 40))) { candidate in candidateRow(candidate) }
                        }
                        if review.candidates.count > 40 && !showAll {
                            Button("Show all \(review.candidates.count) recipes") { showAll = true }
                                .frame(minHeight: 44)
                        }
                        Button("Save \(selectedCount) selected recipes privately") { confirmSave = true }
                            .buttonStyle(.borderedProminent).tint(session.themeButtonColor)
                            .disabled(busy || selectedCount == 0 || !HouseholdSync.shared.can(.recipeEdit))
                        Text("Duplicates are skipped again when you save, including recipes another household member adds during review. To resume after closing the app, choose the same export again; already-saved recipes stay unselected.")
                            .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                    }
                    if review.undoCount > 0 {
                        Button("Undo recent unchanged imports (\(review.undoCount))") { confirmUndo = true }
                            .buttonStyle(.bordered).disabled(busy || !HouseholdSync.shared.can(.recipeEdit))
                        Text("Undo covers the newest 250 imports during this visit. Older imports stay saved. Recipes edited or cooked after import are kept.")
                            .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                    }
                }.padding(20).foregroundStyle(session.themeTextColor)
            }
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle("Recipe collection import").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(busy ? "Stop and close" : "Done") { if busy { review.stop() }; dismiss() }
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): showAll = false; review.load(urls, store: session.guestStore)
                case .failure: review.message = "Files couldn’t be opened. Try choosing the export again."
                }
            }
            .sheet(item: $editing) { candidate in
                CreateRecipeView(prefill: candidate.editForm, prefillSource: candidate.recipe.sourceName ?? "Recipe export",
                    allowAIStructuring: false,
                    onReviewed: { review.acceptEdit($0, candidateID: candidate.id, store: session.guestStore) },
                    initialImageData: candidate.recipe.imageData, forcePrivateSave: true)
                    .environment(session)
            }
            .confirmationDialog("Add \(selectedCount) private recipes?", isPresented: $confirmSave, titleVisibility: .visible) {
                Button("Save selected recipes") { review.saveSelected(store: session.guestStore) }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Existing recipes stay unchanged. Selected recipes join your household library. Source files are parsed locally, and no recipe is published publicly.")
            }
            .confirmationDialog("Undo recent unchanged additions?", isPresented: $confirmUndo, titleVisibility: .visible) {
                Button("Remove unchanged imports", role: .destructive) { review.undo(store: session.guestStore) }
                Button("Cancel", role: .cancel) { }
            } message: { Text("Undo checks the newest 250 imports from this visit and removes only recipes still exactly as imported. Older imports, subsequent edits, cooking history and other household recipes stay.") }
            .onChange(of: session.guestStore.recipeRevision) { _, _ in
                if !busy { review.refreshDuplicates(store: session.guestStore) }
            }
            .onDisappear { if busy { review.stop() } }
        }
    }

    private func candidateRow(_ candidate: RecipeMigrationCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { review.candidates.first(where: { $0.id == candidate.id })?.selected ?? false }, set: { value in
                if let index = review.candidates.firstIndex(where: { $0.id == candidate.id }) { review.candidates[index].selected = value }
            })) {
                Text(candidate.recipe.title).font(.stocked(.headline))
            }.disabled(busy || candidate.duplicateReason != nil || candidate.requiredReview != nil || candidate.status == "Saved")
            Text("\(candidate.recipe.ingredients.count) ingredients · \(candidate.recipe.instructions.count) steps\(candidate.recipe.imageData == nil ? "" : " · photo included")")
                .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
            if let name = candidate.recipe.sourceName, !name.isEmpty {
                Text("Source: \(name)").font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
            }
            if let duplicate = candidate.duplicateReason { Label(duplicate, systemImage: "doc.on.doc").font(.stocked(.footnote)) }
            if let required = candidate.requiredReview { Label(required, systemImage: "checklist").font(.stocked(.footnote)) }
            if !candidate.status.isEmpty { Text(candidate.status).font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText) }
            if !candidate.warnings.isEmpty {
                DisclosureGroup("Review notes") {
                    ForEach(Array(candidate.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning).font(.stocked(.footnote)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Button("Review ingredients, steps and credits") { editing = candidate }
                .disabled(busy || candidate.status == "Saved").frame(minHeight: 44)
        }.padding(14).background(RecipeCardStyle.surface(isDark: session.isDarkMode), in: RoundedRectangle(cornerRadius: 18))
    }
}

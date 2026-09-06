import SwiftUI
import UniformTypeIdentifiers

/// Files enter the same editable recipe form and GuestDataStore as other private imports.
/// Selecting a file never saves it, replaces a recipe, calls AI, or fetches its publisher.
struct PortableRecipeFilesView: View {
    var incomingDraft: PortableRecipeFileDraft? = nil
    var privateImportsOnly = false
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var showMigration = false
    @State private var showCooklangConnection = false
    @State private var draft: PortableRecipeFileDraft?
    @State private var editorDraft: PortableRecipeFileDraft?
    @State private var allowDuplicate = false
    @State private var approvedDuplicateIDs = Set<UUID>()
    @State private var message: String?
    @State private var isWorking = false
    @State private var task: Task<Void, Never>?
    @State private var search = ""
    @State private var exportFile: ExportFile?
    private struct ExportFile: Identifiable { let id = UUID(); let url: URL }

    private var duplicate: UserRecipe? {
        guard let draft else { return nil }
        if let hash = draft.form.portableSource?.contentHash,
           let match = session.guestStore.userRecipes.first(where: { $0.portableSource?.contentHash == hash }) { return match }
        return RecipeImportQuality.duplicate(draft.form, in: session.guestStore.userRecipes)
    }

    /// User recipes are already the authoritative local snapshot. Only 60 rows enter the view.
    private var exportRecipes: [UserRecipe] {
        var recipes: [UserRecipe] = []
        for recipe in session.guestStore.userRecipes {
            if search.isEmpty || recipe.title.localizedCaseInsensitiveContains(search) { recipes.append(recipe) }
            if recipes.count == 60 { break }
        }
        return recipes
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Bring a recipe with you")
                        .font(.stocked(.title2)).foregroundStyle(session.themeTextColor)
                    Text("Read one Cooklang (.cook), recipe JSON, saved HTML, or text file. Everything is read on your device. Review it before saving.")
                        .font(.stocked(.body)).foregroundStyle(session.themeSecondaryText)
                    Button { showImporter = true } label: {
                        Label("Choose a recipe file", systemImage: "doc.badge.plus")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).tint(session.themeButtonColor).disabled(isWorking)
                    Text("Up to 48 KB per recipe. For multiple recipes or another app’s export, use the archive option below.")
                        .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                    Button { showMigration = true } label: {
                        Label("Bring recipes from another app", systemImage: "archivebox")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.bordered).tint(session.themeButtonColor).disabled(isWorking)
                    if incomingDraft == nil {
                        Button { showCooklangConnection = true } label: {
                            Label("Explore Cooklang community recipes", systemImage: "network")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.bordered).tint(session.themeButtonColor).disabled(isWorking)
                    }

                    if isWorking { ProgressView("Reading file…").tint(session.themeButtonColor) }
                    if let message { Text(message).font(.stocked(.body)).foregroundStyle(session.themeSecondaryText) }
                    if let draft { importReview(draft) }

                    Divider()
                    Text("Take your recipes anywhere")
                        .font(.stocked(.title2)).foregroundStyle(session.themeTextColor)
                    Text("Export your current recipe as Cooklang or Schema.org JSON. Export original keeps the exact imported text, comments, and extra metadata. Attached photos are included in full Kitchen Transfer backups; these text exports keep web image links.")
                        .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                    TextField("Find a saved recipe", text: $search)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Find a recipe to export")
                    if session.guestStore.userRecipes.isEmpty {
                        Text("Save a recipe first, then export it here.").foregroundStyle(session.themeSecondaryText)
                    }
                    LazyVStack(spacing: 10) {
                        ForEach(exportRecipes) { recipe in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(recipe.title).font(.stocked(.headline))
                                    Text(recipe.sourceName ?? "My recipe").font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                                }
                                Spacer()
                                Menu {
                                    Button("Current recipe · Cooklang") { export(recipe, format: "cook") }
                                    Button("Current recipe · Recipe JSON") { export(recipe, format: "json") }
                                    if recipe.portableSource?.originalText.isEmpty == false {
                                        Button(recipe.portableSource?.format == "migration" ? "Imported source text" : "Original imported file") { export(recipe, format: "original") }
                                    }
                                } label: {
                                    Label("Export", systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
                                        .frame(minWidth: 44, minHeight: 44)
                                }.accessibilityLabel("Export \(recipe.title)")
                            }.padding(14)
                                .background(RecipeCardStyle.surface(isDark: session.isDarkMode), in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    if exportRecipes.count == 60 {
                        Text("Showing the first 60 matches. Search to find another recipe.")
                            .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                    }
                    Link("Cooklang format · Cooklang contributors", destination: URL(string: "https://cooklang.org/docs/spec/")!)
                        .font(.stocked(.footnote))
                    Link("Recipe format · Schema.org contributors", destination: URL(string: "https://schema.org/Recipe")!)
                        .font(.stocked(.footnote))
                }.padding(20)
            }
            .foregroundStyle(session.themeTextColor)
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle("Recipe Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { read(url) }
                case .failure: message = "The file couldn’t be opened. Choose it again from Files."
                }
            }
            .sheet(item: $editorDraft) { draft in
                CreateRecipeView(prefill: draft.form, prefillSource: draft.sourceName, allowAIStructuring: false,
                    forcePrivateSave: privateImportsOnly, validateBeforeSave: validatePrivateImport) { recipe in
                    message = "Saved \(recipe.title). Your existing recipes were kept."
                    self.draft = nil; allowDuplicate = false
                }.environment(session)
            }
            .sheet(item: $exportFile) { file in ShareSheet(items: [file.url]) }
            .sheet(isPresented: $showMigration) { RecipeMigrationView().environment(session) }
            .sheet(isPresented: $showCooklangConnection) { CooklangRecipeConnectionView().environment(session) }
            .task { if let incomingDraft { draft = incomingDraft } }
            .onDisappear { task?.cancel() }
        }
    }

    private func importReview(_ draft: PortableRecipeFileDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.form.title).font(.stocked(.headline))
            Text("\(draft.form.ingredients.count) ingredients · \(draft.form.steps.count) steps")
                .font(.stocked(.body))
            if !draft.form.sourceURL.isEmpty { RecipeBrowserLink(url: draft.form.sourceURL) }
            if !draft.form.author.isEmpty { Text("By \(draft.form.author)").font(.stocked(.footnote)) }
            if !draft.form.license.isEmpty { Text("Recipe license: \(draft.form.license)").font(.stocked(.footnote)) }
            if !draft.form.imageAttribution.isEmpty { Text("Photo: \(draft.form.imageAttribution)").font(.stocked(.footnote)) }
            ForEach(Array(draft.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "info.circle").font(.stocked(.footnote))
                    .foregroundStyle(session.themeSecondaryText).fixedSize(horizontal: false, vertical: true)
            }
            if let duplicate {
                Text("Looks familiar: “\(duplicate.title)” is already saved. This may be the same file, source, or title.")
                    .font(.stocked(.body))
                Toggle("I want to review a separate copy", isOn: $allowDuplicate)
                Text("The saved recipe stays unchanged. Cancel to keep only that one.")
                    .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
            }
            Button("Review and edit") {
                let keys = RecipeMigrationIdentity(id: draft.id, title: draft.form.title, sourceURL: draft.form.sourceURL, contentHash: draft.form.portableSource?.contentHash).keys
                approvedDuplicateIDs = allowDuplicate ? Set(session.guestStore.userRecipes.filter {
                    !keys.isDisjoint(with: RecipeMigrationIdentity(id: $0.id, title: $0.title, sourceURL: $0.attributedSourceURL, contentHash: $0.portableSource?.contentHash).keys)
                }.map(\.id)) : []
                editorDraft = draft
            }
                .buttonStyle(.borderedProminent).tint(session.themeButtonColor)
                .disabled(duplicate != nil && !allowDuplicate)
            Button("Cancel this import", role: .cancel) { self.draft = nil; allowDuplicate = false }
                .frame(minHeight: 44)
        }.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RecipeCardStyle.surface(isDark: session.isDarkMode), in: RoundedRectangle(cornerRadius: 18))
    }

    private func read(_ url: URL) {
        task?.cancel(); message = nil; draft = nil; allowDuplicate = false; isWorking = true
        task = Task {
            let worker = Task.detached(priority: .utility) { try PortableRecipeFileAdapter.read(url: url) }
            do {
                let parsed = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                draft = parsed
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func validatePrivateImport(_ recipe: UserRecipe) throws {
        guard privateImportsOnly else { return }
        try RecipeImportCommitPolicy.validate(
            RecipeMigrationIdentity(id: recipe.id, title: recipe.title, sourceURL: recipe.attributedSourceURL, contentHash: recipe.portableSource?.contentHash),
            existing: session.guestStore.userRecipes.lazy.map { RecipeMigrationIdentity(id: $0.id, title: $0.title, sourceURL: $0.attributedSourceURL, contentHash: $0.portableSource?.contentHash) },
            approvedDuplicateIDs: approvedDuplicateIDs, canEdit: HouseholdSync.shared.authorize(.recipeEdit))
    }

    private func export(_ recipe: UserRecipe, format: String) {
        task?.cancel(); message = nil; isWorking = true
        task = Task {
            do {
                let url = try await Task.detached(priority: .utility) {
                    let data: Data, filename: String
                    if format == "original", let source = recipe.portableSource {
                        data = Data(source.originalText.utf8); filename = source.filename
                    } else {
                        data = format == "json" ? try PortableRecipeFileAdapter.schemaData(recipe)
                            : Data(PortableCooklang.export(PortableRecipeFileAdapter.cooklangRecipe(recipe)).utf8)
                        let safeTitle = recipe.title.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r")).joined(separator: "-")
                        filename = String(safeTitle.prefix(100)) + "." + format
                    }
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StockedRecipe-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent)
                    try data.write(to: url, options: [.atomic, .completeFileProtection])
                    return url
                }.value
                guard !Task.isCancelled else { return }
                exportFile = ExportFile(url: url)
            } catch { message = "This recipe couldn’t be exported. Please try again." }
            isWorking = false
        }
    }
}

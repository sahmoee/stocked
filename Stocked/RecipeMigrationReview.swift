import Foundation
import CryptoKit
import Observation

nonisolated struct RecipeMigrationCandidate: Identifiable, Sendable {
    var id: UUID
    var filename: String
    var recipe: UserRecipe
    var warnings: [String]
    var selected = true
    var duplicateReason: String?
    var requiredReview: String?
    var status = ""

    var identity: RecipeMigrationIdentity {
        RecipeMigrationIdentity(id: id, title: recipe.title, sourceURL: recipe.attributedSourceURL,
                                contentHash: recipe.portableSource?.contentHash)
    }

    static func from(_ item: KitchenMigrationItem) throws -> Self {
        let parsed = try PortableRecipeFileAdapter.parse(item.recipeJSON, filename: "recipe.json")
        let form = parsed.form
        let normalized = (try? JSONSerialization.jsonObject(with: item.recipeJSON)) as? [String: Any]
        var source = try PortableRecipeSource(format: "migration", filename: item.filename,
                                               originalText: item.originalText ?? "")
        // With no exact source text, this fingerprint identifies the normalized recipe only.
        if item.originalText == nil {
            source.contentHash = SHA256.hash(data: item.recipeJSON).map { String(format: "%02x", $0) }.joined()
        }
        source.originalSourceURL = form.sourceURL.isEmpty ? nil : form.sourceURL
        source.catalogueSharingApproved = false
        try source.validateSize()
        var recipe = UserRecipe(title: form.title, description: form.description,
            cookTime: form.cookTime, prepTime: form.prepTime,
            servings: RecipePageMarkup.servings(form.servings) ?? 4, difficulty: "", cuisine: form.cuisine,
            tags: form.tags, ingredients: form.ingredients.map { line in
                let amount = ParsedQuantity.parse(line)
                return RecipeIngredient(name: amount.baseName.isEmpty ? line : amount.baseName,
                    amount: amount.amount > 0 ? amount.display : "",
                    quantity: amount.amount > 0 ? amount.amount : nil,
                    unit: amount.canonicalUnit.isEmpty ? nil : amount.canonicalUnit)
            }, instructions: form.steps, notes: form.notes,
            imageData: item.localImage, imageURL: form.imageURL.isEmpty ? nil : form.imageURL)
        recipe.sourceURL = nil; recipe.sourceName = parsed.sourceName
        let publisherObject = normalized?["publisher"] as? [String: Any]
        let publisher = (publisherObject?["name"] as? String ?? normalized?["publisher"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !publisher.isEmpty { recipe.sourceName = String(publisher.prefix(2000)) }
        recipe.portableSource = source
        recipe.author = form.author.isEmpty ? nil : form.author
        recipe.license = form.license.isEmpty ? nil : form.license
        recipe.imageAttribution = form.imageAttribution.isEmpty ? nil : form.imageAttribution
        if !form.category.isEmpty { recipe.categories = [form.category] }
        if !form.totalTime.isEmpty { recipe.notes = [recipe.notes, "Publisher total time: \(form.totalTime)"].filter { !$0.isEmpty }.joined(separator: "\n") }
        if !form.servings.isEmpty { recipe.notes = [recipe.notes, "Publisher yield: \(form.servings)"].filter { !$0.isEmpty }.joined(separator: "\n") }
        recipe.notes = privateNotes(recipe.notes)
        var warnings = item.warnings + parsed.warnings.filter {
            !$0.hasPrefix("One recipe is read") && !$0.hasPrefix("Original file and extra metadata")
        }
        if RecipePageMarkup.servings(form.servings) == nil { warnings.append("Serving count needs review; the editor starts at 4 until you confirm it.") }
        if item.originalText == nil { warnings.append("This is a normalized recipe preview. The original archive is not copied into the recipe.") }
        else { warnings.append("Preserved source text is the extracted recipe entry; the ZIP or gzip container itself is not copied.") }
        if let image = item.localImage, image.count > 180_000 {
            warnings.append("The full photo is kept on this device and in backups. Household size limits may prevent this photo from reaching other devices.")
        }
        if let nutrition = normalized?["nutrition"] as? [String: Any] {
            let values = nutrition.keys.sorted().compactMap { key -> String? in
                guard key != "@type", let value = nutrition[key], value is String || value is NSNumber else { return nil }
                return "\(key): \(value)"
            }
            if !values.isEmpty {
                recipe.notes = [recipe.notes, "Nutrition supplied in export (not recalculated): " + values.joined(separator: "; ")].filter { !$0.isEmpty }.joined(separator: "\n")
                warnings.append("Source nutrition is preserved in notes. It has not been recalculated or applied to the nutrition calculator.")
            }
        }
        let needsServings = RecipePageMarkup.servings(form.servings) == nil
        return Self(id: item.id, filename: item.filename, recipe: recipe, warnings: warnings,
                    selected: !needsServings,
                    requiredReview: needsServings ? "Confirm the serving count in Review before selecting this recipe." : nil)
    }

    var editForm: AddRecipeForm {
        var form = AddRecipeForm()
        form.title = recipe.title; form.description = recipe.description
        form.cookTime = recipe.cookTime; form.prepTime = recipe.prepTime; form.servings = String(recipe.servings)
        form.cuisine = recipe.cuisine; form.category = recipe.categories?.first ?? ""; form.tags = recipe.tags
        form.ingredients = recipe.ingredients.map { [$0.amount, $0.name].filter { !$0.isEmpty }.joined(separator: " ") }
        form.steps = recipe.instructions; form.notes = recipe.notes; form.imageURL = recipe.imageURL ?? ""
        form.sourceURL = recipe.attributedSourceURL ?? ""; form.portableSource = recipe.portableSource
        form.author = recipe.author ?? ""; form.license = recipe.license ?? ""; form.imageAttribution = recipe.imageAttribution ?? ""
        form.originalText = recipe.portableSource?.originalText ?? ""
        return form
    }

    static func privateNotes(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?im)^(\s*)source\s*:"#, with: "$1Original reference:", options: .regularExpression)
    }
}

@MainActor @Observable final class RecipeMigrationReview {
    var candidates: [RecipeMigrationCandidate] = []
    var warnings: [String] = []
    var message = ""
    var isLoading = false
    var isSaving = false
    var completed = 0
    var undoCount: Int { savedFingerprints.count }
    private var savedFingerprints: [UUID: String] = [:]
    private var undoOrder: [UUID] = []
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func stop() {
        task?.cancel(); generation = UUID(); isLoading = false; isSaving = false
        message = "Stopped. Recipes already saved are kept. Review the remaining rows or choose the same files again to continue safely."
    }

    func load(_ urls: [URL], store: GuestDataStore) {
        task?.cancel(); let token = UUID(); generation = token
        isLoading = true; message = ""; candidates = []; warnings = []; completed = 0
        task = Task {
            let worker = Task.detached(priority: .utility) { () -> ([RecipeMigrationCandidate], [String]) in
                var rows: [RecipeMigrationCandidate] = [], warnings: [String] = []
                var retainedBytes = 0
                let previewBudget = 32 * 1024 * 1024
                var budgetReached = false
                if urls.count > 20 { warnings.append("Only the first 20 files were read. Choose the remaining files in a second batch.") }
                for url in urls.prefix(20) {
                    try Task.checkCancellation()
                    if rows.count == 250 || budgetReached { warnings.append("This preview reached its size limit. Save it, then choose the remaining files."); break }
                    do {
                        let batch = try KitchenMigration.read(url: url)
                        warnings += batch.warnings
                        for item in batch.items {
                            try Task.checkCancellation()
                            guard rows.count < 250 else { warnings.append("Some recipes exceed this 250-recipe batch. They were not imported."); break }
                            // Include decoded fields and source text, not just compressed archive size.
                            let footprint = item.recipeJSON.count * 3 + (item.localImage?.count ?? 0) + (item.originalText?.utf8.count ?? 0) * 2
                            guard footprint <= previewBudget - retainedBytes else {
                                warnings.append("The 32 MB preview limit was reached. Some later recipes were not loaded; use a smaller export or choose remaining files in another batch.")
                                budgetReached = true; break
                            }
                            do { rows.append(try RecipeMigrationCandidate.from(item)); retainedBytes += footprint }
                            catch { warnings.append("\(item.filename): \(error.localizedDescription)") }
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { warnings.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                }
                return (rows, Array(warnings.prefix(100)))
            }
            do {
                let (rows, warnings) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, generation == token else { return }
                candidates = rows; self.warnings = warnings
                refreshDuplicates(store: store)
                message = rows.isEmpty ? "No usable recipes were found. Existing recipes are unchanged." : "Review the recipes below. Duplicates are left unselected."
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                message = "The import was interrupted. Choose the files again; nothing was changed."
            }
            if generation == token { isLoading = false }
        }
    }

    func refreshDuplicates(store: GuestDataStore) {
        let existing = store.userRecipes.map(Self.identity)
        let active = candidates.filter { $0.status != "Saved" }.map(\.identity)
        let reasons = RecipeMigrationSafety.duplicateReasons(incoming: active, existing: existing)
        for index in candidates.indices {
            candidates[index].duplicateReason = reasons[candidates[index].id]
            if reasons[candidates[index].id] != nil || candidates[index].status == "Saved" { candidates[index].selected = false }
        }
    }

    func acceptEdit(_ recipe: UserRecipe, candidateID: UUID, store: GuestDataStore) {
        guard !isSaving, let index = candidates.firstIndex(where: { $0.id == candidateID }) else { return }
        var edited = recipe
        if edited.portableSource == nil { edited.portableSource = candidates[index].recipe.portableSource }
        let originalURL = edited.attributedSourceURL
        edited.portableSource?.catalogueSharingApproved = false
        edited.portableSource?.originalSourceURL = originalURL
        edited.sourceURL = nil; edited.notes = RecipeMigrationCandidate.privateNotes(edited.notes)
        candidates[index].recipe = edited
        candidates[index].status = "Reviewed"
        candidates[index].requiredReview = nil
        candidates[index].selected = true
        refreshDuplicates(store: store)
    }

    func saveSelected(store: GuestDataStore) {
        guard !isSaving, !isLoading, HouseholdSync.shared.authorize(.recipeEdit) else {
            message = "You need permission to edit household recipes before importing."; return
        }
        refreshDuplicates(store: store)
        let selected = candidates.filter { $0.selected && $0.duplicateReason == nil && $0.requiredReview == nil && $0.status != "Saved" }
        guard !selected.isEmpty else { message = "Select at least one new recipe."; return }
        task?.cancel(); let token = UUID(); generation = token; isSaving = true
        task = Task {
            defer { store.flushPendingSaves() }
            var knownRevision = store.recipeRevision
            var known = Set(store.userRecipes.flatMap { Self.identity($0).keys })
            var skipped = 0
            for candidate in selected {
                guard !Task.isCancelled, generation == token else { break }
                guard HouseholdSync.shared.authorize(.recipeEdit) else { message = "Import stopped because recipe access changed. Completed recipes are kept."; break }
                if knownRevision != store.recipeRevision {
                    known = Set(store.userRecipes.flatMap { Self.identity($0).keys })
                    knownRevision = store.recipeRevision
                }
                guard candidate.identity.keys.isDisjoint(with: known) else {
                    skipped += 1; setStatus(candidate.id, "Skipped: already saved"); continue
                }
                var recipe = candidate.recipe
                recipe.portableSource?.catalogueSharingApproved = false
                recipe.sourceURL = nil
                store.addUserRecipe(recipe)
                guard let saved = store.userRecipes.first(where: { $0.id == recipe.id }) else {
                    message = "A recipe could not be saved. Completed recipes are kept; check household permissions before retrying."; break
                }
                let savedRevision = store.recipeRevision
                completed += 1; setStatus(candidate.id, "Saved")
                let retained = RecipeMigrationSafety.retainingNewest(undoOrder, appending: saved.id)
                let keep = Set(retained)
                for oldID in undoOrder where !keep.contains(oldID) { savedFingerprints.removeValue(forKey: oldID) }
                undoOrder = retained
                // Track the actual stamped record, not the pre-save draft, for conservative undo.
                if let hash = await Task.detached(priority: .utility, operation: { Self.fingerprint(saved) }).value,
                   undoOrder.contains(saved.id) {
                    savedFingerprints[saved.id] = hash
                }
                guard !Task.isCancelled, generation == token else { break }
                // Do not claim a newer revision seen during hashing belongs to our known-key set.
                known.formUnion(Self.identity(saved).keys); knownRevision = savedRevision
                message = "Saved \(completed) recipe\(completed == 1 ? "" : "s"). \(skipped) duplicate\(skipped == 1 ? "" : "s") skipped."
                await Task.yield()
            }
            if generation == token { isSaving = false; refreshDuplicates(store: store) }
        }
    }

    func undo(store: GuestDataStore) {
        guard !isSaving, !isLoading, !savedFingerprints.isEmpty, HouseholdSync.shared.authorize(.recipeEdit) else { return }
        task?.cancel(); let token = UUID(); generation = token; isSaving = true
        let saved = savedFingerprints
        let snapshot = store.userRecipes.filter { saved[$0.id] != nil }
        task = Task {
            let current = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: snapshot.compactMap { recipe in Self.fingerprint(recipe).map { (recipe.id, $0) } })
            }.value
            let eligible = RecipeMigrationSafety.unchangedAdditionIDs(saved: saved, current: current)
            var removed = 0
            for before in snapshot where eligible.contains(before.id) {
                guard !Task.isCancelled, generation == token, HouseholdSync.shared.authorize(.recipeEdit) else { break }
                // Recheck immediately before removal, including edits received while hashing off-main.
                guard let now = store.userRecipes.first(where: { $0.id == before.id }), now == before else { continue }
                store.deleteUserRecipe(id: before.id)
                if !store.userRecipes.contains(where: { $0.id == before.id }) {
                    savedFingerprints.removeValue(forKey: before.id); undoOrder.removeAll { $0 == before.id }; removed += 1
                }
                await Task.yield()
            }
            if generation == token {
                isSaving = false
                for index in candidates.indices where !store.userRecipes.contains(where: { $0.id == candidates[index].recipe.id }) {
                    if candidates[index].status == "Saved" { candidates[index].status = "Undone" }
                }
                message = "Removed \(removed) unchanged import\(removed == 1 ? "" : "s"). Later edits and other recipes were kept."
                refreshDuplicates(store: store)
            }
        }
    }

    private func setStatus(_ id: UUID, _ value: String) {
        if let index = candidates.firstIndex(where: { $0.id == id }) { candidates[index].status = value; candidates[index].selected = false }
    }

    private nonisolated static func identity(_ recipe: UserRecipe) -> RecipeMigrationIdentity {
        RecipeMigrationIdentity(id: recipe.id, title: recipe.title, sourceURL: recipe.attributedSourceURL,
                                contentHash: recipe.portableSource?.contentHash)
    }
    private nonisolated static func fingerprint(_ recipe: UserRecipe) -> String? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(recipe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

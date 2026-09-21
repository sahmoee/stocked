import Foundation
import CryptoKit
import ImageIO

/// Original interoperability code. Producer schema references are recorded in THIRD_PARTY_NOTICES.
/// Parsing only creates review candidates; callers own private storage, merge, and sharing approval.
nonisolated struct KitchenMigrationItem: Identifiable, Sendable {
    let id: UUID
    let filename: String
    let recipeJSON: Data
    let localImage: Data?
    /// Exact UTF-8 recipe entry, possibly decompressed; never the enclosing archive or a fabricated original.
    let originalText: String?
    let warnings: [String]
}

nonisolated struct KitchenMigrationBatch: Sendable {
    let items: [KitchenMigrationItem]
    let warnings: [String]
}

nonisolated enum KitchenMigration {
    static let maximumRecipes = 250
    static let maximumRecipeBytes = 48 * 1024
    static let maximumBytes = 32 * 1024 * 1024
    private static let entryBytes = 8 * 1024 * 1024
    private static let maximumEntries = 500

    enum MigrationError: LocalizedError {
        case tooLarge, tooManyRecipes, noRecipes, malformed, unsupported
        var errorDescription: String? {
            switch self {
            case .tooLarge: "This transfer is too large. Export a smaller selection (up to 32 MB total and 8 MB per file)."
            case .tooManyRecipes: "Choose an export with at most 250 recipes and 500 files."
            case .noRecipes: "No supported recipes were found. Choose a recipe export from Mealie, Tandoor, Paprika, or Recipya, or Schema.org Recipe JSON."
            case .malformed: "This recipe file is incomplete or unreadable. Export it again and retry."
            case .unsupported: "Choose a recipe JSON, gzip, or ZIP export. Database backups, PDFs, and application settings cannot become recipes."
            }
        }
    }

    static func read(url: URL) throws -> KitchenMigrationBatch {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        return try decode(data, filename: url.lastPathComponent)
    }

    static func decode(_ data: Data, filename: String) throws -> KitchenMigrationBatch {
        guard data.count <= maximumBytes else { throw MigrationError.tooLarge }
        try Task.checkCancellation()
        var state = State()
        if isZIP(data) {
            try state.archive(data, prefix: "", depth: 0)
        } else {
            try state.charge(data.count)
            try state.document(data, name: safeName(filename), siblings: [:])
        }
        try Task.checkCancellation()
        guard !state.items.isEmpty else { throw MigrationError.noRecipes }
        if state.skipped > 0 { state.warn("\(state.skipped) unsupported or incomplete file(s) were skipped; nothing was saved automatically.") }
        if state.duplicates > 0 { state.warn("\(state.duplicates) identical recipe(s) appeared more than once and were included once. Changed versions remain separate for review.") }
        state.warn("Only recipe content and declared credits are transferred. Check quantities, steps, notes, and photos before saving. Meal plans, account settings, and application permissions are not imported.")
        return KitchenMigrationBatch(items: state.items, warnings: state.warnings)
    }

    private struct State {
        var items: [KitchenMigrationItem] = []
        var warnings: [String] = []
        var signatures: Set<String> = []
        var expanded = 0
        var retained = 0
        var entries = 0
        var candidates = 0
        var skipped = 0
        var duplicates = 0

        mutating func warn(_ message: String) {
            if warnings.count < 64 { warnings.append(message) }
        }

        mutating func charge(_ bytes: Int) throws {
            guard bytes >= 0, bytes <= maximumBytes - expanded else { throw MigrationError.tooLarge }
            expanded += bytes
        }

        mutating func archive(_ data: Data, prefix: String, depth: Int) throws {
            // Tandoor wraps each recipe in one inner ZIP. Further nesting is never needed.
            guard depth <= 1 else { throw MigrationError.unsupported }
            let contents = try KitchenArchive.readContents(data)
            let files = contents.entries
            guard contents.entryCount <= maximumEntries - entries else { throw MigrationError.tooManyRecipes }
            entries += contents.entryCount
            for file in files { try charge(file.data.count) }
            let siblings = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.data) })
            for file in files {
                try Task.checkCancellation()
                if file.name.hasPrefix("__MACOSX/") || file.name.split(separator: "/").last?.hasPrefix(".") == true { continue }
                if isZIP(file.data) {
                    guard depth == 0 else { throw MigrationError.unsupported }
                    try archive(file.data, prefix: prefix + file.name + "/", depth: depth + 1)
                    continue
                }
                let ext = URL(fileURLWithPath: file.name).pathExtension.lowercased()
                if isGZIP(file.data) || ["json", "jsonld", "paprikarecipe", "gz"].contains(ext) {
                    do {
                        try document(file.data, name: file.name, siblings: siblings, displayPrefix: prefix)
                    } catch is CancellationError { throw CancellationError() }
                    catch let error as MigrationError {
                        if error == .tooLarge || error == .tooManyRecipes { throw error }
                        skipped += 1
                        warn("\(safeName(prefix + file.name)): \(error.localizedDescription)")
                    } catch {
                        // A corrupt compressed member is an invalid archive, not a successful partial transfer.
                        throw error
                    }
                } else if !["jpg", "jpeg", "png", "webp", "gif", "avif"].contains(ext) {
                    skipped += 1
                }
            }
        }

        mutating func document(_ data: Data, name: String, siblings: [String: Data], displayPrefix: String = "") throws {
            guard data.count <= entryBytes else { throw MigrationError.tooLarge }
            var bytes = data
            var filename = name
            if isGZIP(bytes) {
                bytes = try KitchenArchive.gunzip(bytes, limit: entryBytes)
                try charge(bytes.count)
                filename += ".json"
            }
            guard let raw = String(data: bytes, encoding: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: bytes) else { throw MigrationError.malformed }
            let nodes: [[String: Any]]
            let exact: String?
            if let array = object as? [[String: Any]] {
                guard array.count <= maximumRecipes else { throw MigrationError.tooManyRecipes }
                nodes = array; exact = nil
            } else if let value = object as? [String: Any] {
                if let wrapped = value["recipes"] as? [[String: Any]], kind(value) == nil {
                    guard wrapped.count <= maximumRecipes else { throw MigrationError.tooManyRecipes }
                    nodes = wrapped; exact = nil
                    warn("This is a converted JSON recipe collection. Each recognized recipe is reviewed separately; the collection is not treated as an original single recipe.")
                } else if !isRecipe(value), let graph = value["@graph"] as? [[String: Any]] {
                    guard graph.count <= maximumEntries else { throw MigrationError.tooManyRecipes }
                    nodes = graph.filter(isRecipe); exact = nil
                } else { nodes = [value]; exact = raw }
            } else { throw MigrationError.noRecipes }
            var found = false
            var unrecognized = 0
            for (index, node) in nodes.enumerated() {
                try Task.checkCancellation()
                guard let kind = kind(node) else { unrecognized += 1; continue }
                candidates += 1
                guard candidates <= maximumRecipes else { throw MigrationError.tooManyRecipes }
                found = true
                let suffix = nodes.count > 1 ? " [\(index + 1)].json" : ""
                try add(node, kind: kind, raw: exact, path: name, filename: displayPrefix + filename + suffix, siblings: siblings)
            }
            if !found { throw MigrationError.noRecipes }
            skipped += unrecognized
        }

        mutating func add(_ node: [String: Any], kind: Kind, raw: String?, path: String, filename: String, siblings: [String: Data]) throws {
            var warnings: [String] = []
            let output: [String: Any]
            do { output = try normalize(node, kind: kind, warnings: &warnings) }
            catch let error as MigrationError {
                if error == .tooLarge || error == .tooManyRecipes { throw error }
                skipped += 1; warn("\(safeName(filename)): missing a title, ingredients, or directions; skipped."); return
            }
            let json = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes])
            guard json.count <= maximumRecipeBytes else { throw MigrationError.tooLarge }
            let photo = localImage(node, kind: kind, path: path, siblings: siblings, warnings: &warnings)
            var original: String?
            if let raw, raw.utf8.count <= maximumRecipeBytes, !hasInlinePhoto(node),
               let escaped = try? JSONEncoder().encode(raw), escaped.count <= 60 * 1024 {
                original = raw
            } else {
                warnings.append("The complete original could not be kept separately (bulk JSON, size, or an embedded photo). The reviewed recipe is a normalized snapshot; retain your export for the remaining metadata.")
            }
            // Compare canonical input as well: never discard distinct source metadata merely because
            // two exports normalize to the same ingredients and steps.
            let canonical = try JSONSerialization.data(withJSONObject: node, options: [.sortedKeys, .withoutEscapingSlashes])
            var hash = SHA256(); hash.update(data: canonical)
            if let photo { hash.update(data: photo) }
            let signature = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard signatures.insert(signature).inserted else { duplicates += 1; return }
            let size = json.count + (original?.utf8.count ?? 0) + (photo?.count ?? 0)
            guard size <= maximumBytes - retained else { throw MigrationError.tooLarge }
            retained += size
            if photo == nil { warnings.append("No supported local photo was found. Remote photos are not downloaded during transfer; add a photo after review if needed.") }
            items.append(KitchenMigrationItem(id: UUID(), filename: safeName(filename), recipeJSON: json,
                localImage: photo, originalText: original, warnings: warnings))
        }
    }

    private enum Kind { case schema, mealie, tandoor, paprika }

    private static func kind(_ value: [String: Any]) -> Kind? {
        if value["recipe_ingredient"] is [Any] && value["recipe_instructions"] is [Any] { return .mealie }
        if let rows = value["recipeIngredient"] as? [[String: Any]], value["recipeInstructions"] is [[String: Any]],
           rows.contains(where: { $0["display"] != nil || $0["food"] != nil || $0["originalText"] != nil }) { return .mealie }
        if isRecipe(value) { return .schema }
        if let steps = value["steps"] as? [[String: Any]], steps.contains(where: { $0["instruction"] is String && $0["ingredients"] is [Any] }) { return .tandoor }
        if value["ingredients"] is String && value["directions"] is String { return .paprika }
        return nil
    }

    private static func isRecipe(_ value: [String: Any]) -> Bool {
        let types = value["@type"] as? [String] ?? (value["@type"] as? String).map { [$0] } ?? []
        return types.contains { $0.split(separator: "/").last?.lowercased() == "recipe" }
    }

    private static func normalize(_ value: [String: Any], kind: Kind, warnings: inout [String]) throws -> [String: Any] {
        let title = string(value["name"])
        guard !title.isEmpty, title.utf8.count <= 2_000 else { throw MigrationError.malformed }
        var result: [String: Any] = ["@context": "https://schema.org", "@type": "Recipe", "name": title]
        put(&result, "description", string(value["description"]))
        var ingredients: [String] = [], steps: [String] = [], notes: [String] = []
        var source = "", picture = "", yield = ""
        switch kind {
        case .schema:
            ingredients = strings(value["recipeIngredient"])
            steps = try instructionTexts(value["recipeInstructions"])
            source = link(value["url"] ?? value["mainEntityOfPage"] ?? value["@id"])
            picture = firstImage(value["image"])
            yield = scalar(value["recipeYield"])
            for key in ["prepTime", "cookTime", "totalTime", "recipeCategory", "recipeCuisine", "keywords"] {
                if let text = value[key] as? String { put(&result, key, text) }
                else if let array = value[key] as? [String] { result[key] = array }
            }
            if let comment = value["comment"] as? [String: Any] { notes = [string(comment["text"])] }
        case .mealie:
            let rows = (value["recipe_ingredient"] ?? value["recipeIngredient"]) as? [[String: Any]] ?? []
            guard rows.count <= 500 else { throw MigrationError.tooManyRecipes }
            for row in rows {
                let display = string(row["display"])
                let original = string(row["original_text"] ?? row["originalText"])
                let fallback = joined([number(row["quantity"]), scalar(row["unit"]), scalar(row["food"]), string(row["note"])])
                let line = !display.isEmpty ? display : !original.isEmpty ? original : fallback
                if !line.isEmpty { ingredients.append(line) }
                let heading = string(row["title"])
                if !heading.isEmpty { notes.append("Ingredient section: \(heading)") }
                if row["referenced_recipe"] is [String: Any] || row["referencedRecipe"] is [String: Any] {
                    warnings.append("An ingredient refers to another recipe. Check that its separate recipe was also exported.")
                }
            }
            let rowsSteps = (value["recipe_instructions"] ?? value["recipeInstructions"]) as? [[String: Any]] ?? []
            guard rowsSteps.count <= 500 else { throw MigrationError.tooManyRecipes }
            guard rowsSteps.contains(where: { !string($0["text"]).isEmpty }) else { throw MigrationError.malformed }
            steps = rowsSteps.map { joined([string($0["title"]), string($0["text"])], separator: "\n") }.filter { !$0.isEmpty }
            source = string(value["org_url"] ?? value["orgURL"])
            // Mealie's image field is a version marker, not an original publisher URL.
            yield = number(value["recipe_servings"] ?? value["recipeServings"], positiveOnly: true)
            if yield.isEmpty { yield = string(value["recipe_yield"] ?? value["recipeYield"]) }
            for (dest, snake, camel) in [("prepTime", "prep_time", "prepTime"), ("cookTime", "cook_time", "cookTime"), ("totalTime", "total_time", "totalTime")] {
                put(&result, dest, string(value[snake] ?? value[camel]))
            }
            result["keywords"] = names(value["tags"])
            result["recipeCategory"] = names(value["recipe_category"] ?? value["recipeCategory"])
            if let rawNotes = value["notes"] as? [[String: Any]] {
                notes += rawNotes.map { joined([string($0["title"]), string($0["text"])], separator: "\n") }
            }
        case .tandoor:
            let rows = ordered(value["steps"] as? [[String: Any]] ?? [])
            guard rows.count <= 500 else { throw MigrationError.tooManyRecipes }
            guard rows.contains(where: { !string($0["instruction"]).isEmpty }) else { throw MigrationError.malformed }
            for step in rows {
                let text = joined([string(step["name"]), string(step["instruction"])], separator: "\n")
                if !text.isEmpty { steps.append(text) }
                let parts = ordered(step["ingredients"] as? [[String: Any]] ?? [])
                guard parts.count <= 500 - ingredients.count else { throw MigrationError.tooManyRecipes }
                for part in parts {
                    let line = joined([truth(part["no_amount"]) ? "" : number(part["amount"]), truth(part["no_amount"]) ? "" : scalar(part["unit"]), scalar(part["food"]), string(part["note"])])
                    if truth(part["is_header"]) { if !line.isEmpty { notes.append("Ingredient section: \(line)") } }
                    else if !line.isEmpty { ingredients.append(line) }
                }
            }
            source = string(value["source_url"])
            yield = joined([number(value["servings"], positiveOnly: true), string(value["servings_text"])])
            result["keywords"] = names(value["keywords"])
            // Keep the producer labels: waiting time can mean resting/chilling, not cooking.
            let work = number(value["working_time"], positiveOnly: true)
            let wait = number(value["waiting_time"], positiveOnly: true)
            if !work.isEmpty { notes.append("Working time (Tandoor): \(work) minutes") }
            if !wait.isEmpty { notes.append("Waiting time (Tandoor): \(wait) minutes") }
        case .paprika:
            ingredients = lines(string(value["ingredients"]))
            steps = lines(string(value["directions"]))
            source = string(value["source_url"])
            picture = string(value["image_url"])
            yield = string(value["servings"])
            for (dest, from) in [("prepTime", "prep_time"), ("cookTime", "cook_time")] { put(&result, dest, string(value[from])) }
            result["keywords"] = strings(value["categories"])
            notes = [string(value["notes"])]
            let nutrition = string(value["nutritional_info"])
            if !nutrition.isEmpty { notes.append("Nutrition from export (not recalculated): \(nutrition)") }
            let publisher = string(value["source"])
            if !publisher.isEmpty { result["publisher"] = ["@type": "Organization", "name": publisher] }
        }
        guard !ingredients.isEmpty, !steps.isEmpty else { throw MigrationError.malformed }
        guard ingredients.count <= 500, steps.count <= 500 else { throw MigrationError.tooManyRecipes }
        result["recipeIngredient"] = ingredients
        result["recipeInstructions"] = steps.map { ["@type": "HowToStep", "text": $0] }
        put(&result, "recipeYield", yield)
        put(&result, "url", webURL(source))
        if !source.isEmpty && webURL(source).isEmpty { warnings.append("The source link was not a complete HTTP(S) address and was left out. Check the original export for attribution.") }
        let author = authorName(value["author"])
        let license = scalar(value["license"])
        let imageObject = value["image"] as? [String: Any]
        let credit = string(value["imageAttribution"] ?? imageObject?["creditText"])
        for (key, text) in [("author", author), ("license", license), ("imageAttribution", credit)] {
            guard text.count <= 2_000 else { throw MigrationError.tooLarge }
            put(&result, key, text)
        }
        if let publisher = value["publisher"], !scalar(publisher).isEmpty {
            result["publisher"] = ["@type": "Organization", "name": scalar(publisher)]
        }
        if !webURL(picture).isEmpty {
            var image = ["@type": "ImageObject", "url": webURL(picture)]
            if !credit.isEmpty { image["creditText"] = credit }
            result["image"] = image
        }
        if let nutrition = value["nutrition"] as? [String: Any], kind == .schema {
            var safe: [String: Any] = ["@type": "NutritionInformation"]
            for key in ["calories", "carbohydrateContent", "cholesterolContent", "fatContent", "fiberContent", "proteinContent", "saturatedFatContent", "servingSize", "sodiumContent", "sugarContent", "transFatContent", "unsaturatedFatContent"] {
                put(&safe, key, scalar(nutrition[key]))
            }
            if safe.count > 1 { result["nutrition"] = safe }
        } else if let nutrition = value["nutrition"] as? [String: Any], !nutrition.isEmpty {
            // Mealie/Tandoor nutrition units and serving bases differ. Preserve labels as notes;
            // do not silently turn a bare number into grams or per-serving facts.
            let fields = nutrition.keys.sorted().compactMap { key -> String? in
                let text = scalar(nutrition[key]); return text.isEmpty ? nil : "\(key): \(text)"
            }
            if !fields.isEmpty { notes.append("Nutrition from export (check units and serving size):\n" + fields.joined(separator: "\n")) }
        }
        let note = notes.filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !note.isEmpty { result["comment"] = ["@type": "Comment", "text": note] }
        return result
    }

    private static func instructionTexts(_ value: Any?, depth: Int = 0) throws -> [String] {
        guard depth < 8 else { throw MigrationError.malformed }
        if let text = value as? String { return lines(text) }
        if let array = value as? [Any] {
            guard array.count <= 500 else { throw MigrationError.tooManyRecipes }
            var result: [String] = []
            for item in array {
                try Task.checkCancellation()
                let next = try instructionTexts(item, depth: depth + 1)
                guard next.count <= 500 - result.count else { throw MigrationError.tooManyRecipes }
                result += next
            }
            return result
        }
        if let object = value as? [String: Any] {
            if let nested = object["itemListElement"] {
                return try instructionTexts(nested, depth: depth + 1)
            }
            let text = string(object["text"])
            return text.isEmpty ? [] : [text]
        }
        return []
    }

    private static func localImage(_ node: [String: Any], kind: Kind, path: String, siblings: [String: Data], warnings: inout [String]) -> Data? {
        if let encoded = node["photo_data"] as? String, !encoded.isEmpty {
            guard encoded.utf8.count <= entryBytes * 4 / 3 + 8,
                  let data = Data(base64Encoded: encoded), validPhoto(data) else {
                warnings.append("The embedded photo was not a supported, bounded JPEG or PNG; it was skipped."); return nil
            }
            return data
        }
        let pieces = path.split(separator: "/")
        let directory = pieces.dropLast().map(String.init).joined(separator: "/")
        let prefix = directory.isEmpty ? "" : directory + "/"
        var candidates: [String] = []
        switch kind {
        case .mealie:
            candidates = ["jpg", "jpeg", "png", "webp"].map { prefix + "images/original." + $0 }
        case .tandoor:
            candidates = ["jpg", "jpeg", "png", "webp"].map { prefix + "image." + $0 }
        case .schema, .paprika:
            let raw = kind == .paprika ? string(node["image_url"]) : firstImage(node["image"])
            // Recipya puts the URL's UUID photo filename beside recipe.json. Match only that
            // selected recipe directory, never an arbitrary image elsewhere in the archive.
            if let name = URL(string: raw)?.lastPathComponent, !name.isEmpty, !name.contains("/") {
                candidates.append(prefix + name)
            }
        }
        var unsupported = false
        for name in candidates {
            if let bytes = siblings[name] {
                if validPhoto(bytes) { return bytes }
                unsupported = true
            }
        }
        if unsupported { warnings.append("A local photo used an unsupported format or size. Original photo bytes were not converted; add a JPEG or PNG after review.") }
        return nil
    }

    private static func validPhoto(_ data: Data) -> Bool {
        guard data.count > 8, data.count <= entryBytes,
              data.starts(with: [0xFF, 0xD8, 0xFF]) || data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384, width <= 40_000_000 / height else { return false }
        return true
    }

    private static func hasInlinePhoto(_ value: Any, depth: Int = 0) -> Bool {
        guard depth < 8 else { return true }
        if let text = value as? String { return text.lowercased().hasPrefix("data:") }
        if let array = value as? [Any] { return array.contains { hasInlinePhoto($0, depth: depth + 1) } }
        guard let node = value as? [String: Any] else { return false }
        for (key, value) in node {
            if ["photo_data", "photoData", "imageData"].contains(key), !string(value).isEmpty { return true }
            if hasInlinePhoto(value, depth: depth + 1) { return true }
        }
        return false
    }

    private static func firstImage(_ value: Any?) -> String {
        // Recipya's Image marshaler exposes either a string or a list, depending on count.
        let first = link(value)
        return first.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
    }
    private static func link(_ value: Any?, depth: Int = 0) -> String {
        guard depth < 8 else { return "" }
        if let array = value as? [Any] { return link(array.first, depth: depth + 1) }
        if let object = value as? [String: Any] { return link(object["url"] ?? object["contentUrl"] ?? object["@id"], depth: depth + 1) }
        return string(value)
    }
    private static func webURL(_ text: String) -> String {
        guard text.utf8.count <= 4_096, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return "" }
        return url.absoluteString
    }
    private static func isZIP(_ data: Data) -> Bool { data.starts(with: [0x50, 0x4B, 0x03, 0x04]) || data.starts(with: [0x50, 0x4B, 0x05, 0x06]) }
    private static func isGZIP(_ data: Data) -> Bool { data.starts(with: [0x1F, 0x8B]) }
    private static func safeName(_ name: String) -> String {
        String(String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(240))
    }
    private static func put(_ object: inout [String: Any], _ key: String, _ text: String) { if !text.isEmpty { object[key] = text } }
    private static func string(_ value: Any?) -> String { (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func scalar(_ value: Any?, depth: Int = 0) -> String {
        guard depth < 8 else { return "" }
        if value is String { return string(value) }
        if let array = value as? [Any] { return scalar(array.first, depth: depth + 1) }
        if let object = value as? [String: Any] { return scalar(object["name"] ?? object["url"] ?? object["contentUrl"] ?? object["@id"], depth: depth + 1) }
        return number(value)
    }
    private static func number(_ value: Any?, positiveOnly: Bool = false) -> String {
        if let text = value as? String {
            guard !positiveOnly || (Double(text).map { $0.isFinite && $0 > 0 } ?? false) else { return "" }
            return text
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, !positiveOnly || number.doubleValue > 0 else { return "" }
        return number.stringValue
    }
    private static func truth(_ value: Any?) -> Bool { (value as? NSNumber)?.boolValue == true }
    private static func strings(_ value: Any?) -> [String] {
        if let array = value as? [String] { return array.map { string($0) }.filter { !$0.isEmpty } }
        if let text = value as? String { return lines(text) }
        return []
    }
    private static func names(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).map { scalar($0) }.filter { !$0.isEmpty }
    }
    private static func authorName(_ value: Any?) -> String {
        if let array = value as? [Any] { return array.map { scalar($0) }.filter { !$0.isEmpty }.joined(separator: ", ") }
        return scalar(value)
    }
    private static func lines(_ text: String) -> [String] { text.components(separatedBy: .newlines).map { string($0) }.filter { !$0.isEmpty } }
    private static func joined(_ parts: [String], separator: String = " ") -> String { parts.filter { !$0.isEmpty }.joined(separator: separator) }
    private static func ordered(_ rows: [[String: Any]]) -> [[String: Any]] {
        rows.enumerated().sorted { lhs, rhs in
            let a = Double(number(lhs.element["order"])) ?? Double(lhs.offset)
            let b = Double(number(rhs.element["order"])) ?? Double(rhs.offset)
            return a == b ? lhs.offset < rhs.offset : a < b
        }.map(\.element)
    }
}

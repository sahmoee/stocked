import Foundation
import CryptoKit

/// The original is private provenance, separate from edited fields and recipe notes.
/// Older clients may omit this optional field; they can still read the recipe itself.
nonisolated struct PortableRecipeSource: Codable, Equatable, Sendable {
    var format: String
    var filename: String
    var originalText: String
    var contentHash: String
    /// File imports are private unless the save review explicitly approves public publication.
    var catalogueSharingApproved: Bool? = nil
    /// Private file source kept off the legacy public sourceURL field until sharing is approved.
    var originalSourceURL: String? = nil

    init(format: String, filename: String, originalText: String) throws {
        guard originalText.utf8.count <= PortableCooklang.maximumBytes,
              let escaped = try? JSONEncoder().encode(originalText), escaped.count <= 60 * 1024 else {
            throw PortableCooklang.ParseError.tooLarge
        }
        self.format = format
        self.filename = String(URL(fileURLWithPath: filename).lastPathComponent.prefix(180))
        self.originalText = originalText
        self.contentHash = SHA256.hash(data: Data(originalText.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func validateSize() throws {
        guard try JSONEncoder().encode(self).count <= 64 * 1024 else { throw PortableCooklang.ParseError.tooLarge }
    }
}

extension UserRecipe {
    /// For user-facing attribution/export only. Publication must continue to read sourceURL,
    /// which stays nil for private file imports so older clients cannot publish them by accident.
    nonisolated var attributedSourceURL: String? {
        if let sourceURL, !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return sourceURL }
        return portableSource?.originalSourceURL
    }
}

nonisolated struct PortableRecipeFileDraft: Identifiable, Sendable {
    let id = UUID()
    var form: AddRecipeForm
    var sourceName: String
    var warnings: [String]
}

nonisolated enum PortableRecipeFileAdapter {
    enum FileError: LocalizedError {
        case encoding, unsupported, noRecipe
        var errorDescription: String? {
            switch self {
            case .encoding: "This file is not UTF-8 text. Export it as UTF-8 and try again."
            case .unsupported: "Choose one .cook, .json, .html, or .txt recipe file. For recipe archives, use Bring recipes from another app. Stocked backups use Kitchen Transfer."
            case .noRecipe: "No usable recipe was found. Try a single Schema.org Recipe file or paste the recipe text."
            }
        }
    }

    static func read(url: URL) throws -> PortableRecipeFileDraft {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // Read one bounded chunk: metadata can lie and cloud files may have an unknown size.
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: PortableCooklang.maximumBytes + 1) ?? Data()
        return try parse(bytes, filename: url.lastPathComponent)
    }

    static func parse(_ data: Data, filename: String) throws -> PortableRecipeFileDraft {
        guard data.count <= PortableCooklang.maximumBytes else { throw PortableCooklang.ParseError.tooLarge }
        guard let raw = String(data: data, encoding: .utf8) else { throw FileError.encoding }
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let fallback = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        var form = AddRecipeForm(), sourceName = "Imported file", warnings: [String] = []
        if ext == "cook" {
            let parsed = try PortableCooklang.parse(raw, fallbackTitle: fallback)
            form.title = parsed.title; form.description = parsed.description; form.servings = parsed.servings
            form.sourceURL = absoluteWebURL(parsed.sourceURL)
            form.imageURL = absoluteWebURL(parsed.imageURL)
            form.prepTime = parsed.prepTime; form.cookTime = parsed.cookTime; form.tags = parsed.tags
            form.ingredients = parsed.ingredients.map(\.displayLine); form.steps = parsed.steps
            form.notes = parsed.notes.joined(separator: "\n"); warnings = parsed.warnings
            form.author = parsed.author; form.license = parsed.license; form.imageAttribution = parsed.imageAttribution
            sourceName = parsed.sourceName.isEmpty ? "Cooklang file" : parsed.sourceName
        } else if ["json", "html", "htm"].contains(ext) {
            let html: String
            if ext == "json" {
                guard let json = try? JSONSerialization.jsonObject(with: data),
                      let normalized = try? JSONSerialization.data(withJSONObject: json),
                      let jsonText = String(data: normalized, encoding: .utf8) else { throw FileError.noRecipe }
                html = "<script type=\"application/ld+json\">\(jsonText)</script>"
            } else { html = raw }
            let source = structuredSource(in: html)
            guard let web = JSONLDRecipeParser.parse(html: html, pageURL: source.url), !web.steps.isEmpty else { throw FileError.noRecipe }
            form.title = web.title; form.description = web.description; form.ingredients = web.ingredients
            form.steps = web.steps.map(\.text); form.servings = web.servings; form.prepTime = web.prepTime
            form.cookTime = web.cookTime; form.totalTime = web.totalTime; form.tags = web.tags
            form.category = web.category; form.cuisine = web.cuisine; form.sourceURL = source.url
            form.imageURL = web.imageURL.isEmpty ? source.image : web.imageURL
            sourceName = source.url.isEmpty ? "Recipe file" : web.sourceName
            form.author = source.author; form.license = source.license; form.imageAttribution = source.imageAttribution
            form.notes = source.notes
            warnings.append("One recipe is read from each file. For multiple recipes or archives, use Bring recipes from another app.")
        } else if ext == "txt" {
            form = RecipeTextParser.parse(raw)
            warnings.append("Plain text is matched by headings and line layout. Check every amount and step.")
        } else { throw FileError.unsupported }
        guard !form.steps.isEmpty else { throw FileError.noRecipe }
        guard form.ingredients.count <= 500, form.steps.count <= 500 else { throw PortableCooklang.ParseError.tooManyItems }
        if form.title.isEmpty { form.title = fallback }
        form.originalText = raw
        form.portableSource = try PortableRecipeSource(format: ext, filename: filename, originalText: raw)
        form.portableSource?.originalSourceURL = form.sourceURL.isEmpty ? nil : form.sourceURL
        try form.portableSource?.validateSize()
        if form.imageURL.isEmpty { warnings.append("No photo was included. You can save this private recipe and add a photo later.") }
        if form.sourceURL.isEmpty { warnings.append("No original web link was supplied. Add publisher details in notes if needed.") }
        warnings.append("Original file and extra metadata stay available under Export original. Edited Cooklang exports use the basic format.")
        return PortableRecipeFileDraft(form: form, sourceName: sourceName, warnings: warnings)
    }

    /// Inspect only bounded Recipe nodes, never arbitrarily treat the first URL in a file as its source.
    private static func structuredSource(in html: String) -> (url: String, image: String, author: String, license: String, imageAttribution: String, notes: String) {
        guard let regex = try? NSRegularExpression(pattern: #"<script[^>]*type=["']application/ld\+json["'][^>]*>([\s\S]*?)</script>"#, options: .caseInsensitive) else { return ("", "", "", "", "", "") }
        func recipeNode(_ value: Any, depth: Int = 0) -> [String: Any]? {
            guard depth < 8 else { return nil }
            if let array = value as? [Any] {
                for item in array.prefix(200) { if let recipe = recipeNode(item, depth: depth + 1) { return recipe } }
            }
            guard let object = value as? [String: Any] else { return nil }
            let types = (object["@type"] as? [String]) ?? (object["@type"] as? String).map { [$0] } ?? []
            if types.contains(where: { $0.split(separator: "/").last?.lowercased() == "recipe" }) { return object }
            for key in ["@graph", "mainEntity", "mainEntityOfPage"] {
                if let nested = object[key], let recipe = recipeNode(nested, depth: depth + 1) { return recipe }
            }
            return nil
        }
        func scalar(_ value: Any?, depth: Int = 0) -> String {
            guard depth < 8 else { return "" }
            if let text = value as? String { return text }
            if let array = value as? [Any] { return scalar(array.first, depth: depth + 1) }
            if let object = value as? [String: Any] { return (object["url"] ?? object["contentUrl"] ?? object["@id"] ?? object["name"]) as? String ?? "" }
            return ""
        }
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).prefix(32) {
            guard let range = Range(match.range(at: 1), in: html), let data = String(html[range]).data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data), let node = recipeNode(value) else { continue }
            let source = absoluteWebURL(scalar(node["url"] ?? node["mainEntityOfPage"] ?? node["@id"]))
            let image = absoluteWebURL(scalar(node["image"]))
            let author = node["author"] as? [String: Any]
            let name = author?["name"] as? String ?? (node["author"] as? String ?? "")
            let imageObject = node["image"] as? [String: Any]
            let imageCredit = (imageObject?["creditText"] as? String) ?? (node["imageAttribution"] as? String) ?? ""
            let comment = node["comment"] as? [String: Any]
            let notes = comment?["text"] as? String ?? ""
            return (source, image, name, scalar(node["license"]), imageCredit, notes)
        }
        return ("", "", "", "", "", "")
    }

    private static func absoluteWebURL(_ raw: String) -> String {
        // Cooklang pictures commonly name adjacent local files. A filename such as soup.jpg
        // is not permission to invent https://soup.jpg or reach outside the selected document.
        guard let scheme = URL(string: raw)?.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return "" }
        return RecipeBrowserPolicy.url(raw)?.absoluteString ?? ""
    }

    static func cooklangRecipe(_ recipe: UserRecipe) -> PortableCooklangRecipe {
        var output = PortableCooklangRecipe(title: recipe.title, description: recipe.description,
            sourceURL: recipe.attributedSourceURL ?? "", sourceName: recipe.sourceName ?? "", author: recipe.author ?? "",
            license: recipe.license ?? "", imageAttribution: recipe.imageAttribution ?? "", imageURL: recipe.imageURL ?? "",
            servings: String(recipe.servings), prepTime: recipe.prepTime, cookTime: recipe.cookTime,
            tags: recipe.tags, steps: recipe.instructions, notes: recipe.notes.isEmpty ? [] : [recipe.notes])
        output.ingredients = recipe.ingredients.map { ingredient in
            // Preserve an unparsed amount verbatim; never invent a conversion during export.
            let quantity = ingredient.quantity.map { String($0) } ?? ingredient.amount
            let unit = ingredient.quantity == nil ? "" : (ingredient.unit ?? "")
            return PortableCooklangIngredient(name: ingredient.name, quantity: quantity, unit: unit, preparation: ingredient.prep ?? "")
        }
        return output
    }

    static func schemaData(_ recipe: UserRecipe) throws -> Data {
        var object: [String: Any] = ["@context": "https://schema.org", "@type": "Recipe", "name": recipe.title,
            "description": recipe.description, "recipeYield": String(recipe.servings),
            "recipeIngredient": recipe.ingredients.map { [$0.amount, $0.name].filter { !$0.isEmpty }.joined(separator: " ") },
            "recipeInstructions": recipe.instructions.map { ["@type": "HowToStep", "text": $0] }, "keywords": recipe.tags]
        if let source = recipe.attributedSourceURL, !source.isEmpty { object["url"] = source }
        if let author = recipe.author, !author.isEmpty { object["author"] = author }
        if let name = recipe.sourceName, !name.isEmpty { object["publisher"] = ["@type": "Organization", "name": name] }
        if let license = recipe.license, !license.isEmpty { object["license"] = license }
        if let image = recipe.imageURL, !image.isEmpty {
            var picture = ["@type": "ImageObject", "url": image]
            if let credit = recipe.imageAttribution, !credit.isEmpty { picture["creditText"] = credit }
            object["image"] = picture
        }
        // Display times may be prose, so preserve them as text notes instead of invalid ISO durations.
        let note = [recipe.notes, recipe.prepTime.isEmpty ? "" : "Prep time: \(recipe.prepTime)", recipe.cookTime.isEmpty ? "" : "Cook time: \(recipe.cookTime)"]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        if !note.isEmpty { object["comment"] = ["@type": "Comment", "text": note] }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

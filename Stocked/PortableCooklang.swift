import Foundation

/// Independently implemented subset of the Cooklang specification.
/// Format credit: Cooklang contributors, https://cooklang.org/docs/spec/ (MIT specification).
/// No copied parser, network service, or AI dependency. The complete original stays available
/// for export because extensions and complex YAML are deliberately not interpreted here.
nonisolated struct PortableCooklangIngredient: Equatable, Sendable {
    var name: String
    var quantity = ""
    var unit = ""
    var preparation = ""
    var displayLine: String {
        [quantity, unit, name, preparation.isEmpty ? "" : "(\(preparation))"]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

nonisolated struct PortableCooklangRecipe: Equatable, Sendable {
    var title = ""
    var description = ""
    var sourceURL = ""
    var sourceName = ""
    var author = ""
    var license = ""
    var imageAttribution = ""
    var imageURL = ""
    var servings = ""
    var prepTime = ""
    var cookTime = ""
    var tags: [String] = []
    var ingredients: [PortableCooklangIngredient] = []
    var steps: [String] = []
    var notes: [String] = []
    var warnings: [String] = []
    var originalText = ""
}

nonisolated enum PortableCooklang {
    /// Fits in a household operation even after JSON escaping, alongside normal recipe fields.
    static let maximumBytes = 48 * 1024
    enum ParseError: LocalizedError {
        case tooLarge, empty, noSteps, tooManyItems
        var errorDescription: String? {
            switch self {
            case .tooLarge: "Choose a recipe file smaller than 48 KB."
            case .empty: "This recipe file is empty."
            case .noSteps: "No cooking steps were found. Check the file or paste its recipe text."
            case .tooManyItems: "Choose a single recipe with no more than 500 ingredients and 500 steps."
            }
        }
    }

    static func parse(_ text: String, fallbackTitle: String) throws -> PortableCooklangRecipe {
        guard text.utf8.count <= maximumBytes else { throw ParseError.tooLarge }
        guard !trim(text).isEmpty else { throw ParseError.empty }
        var recipe = PortableCooklangRecipe(title: fallbackTitle, originalText: text)
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        if lines.first?.hasPrefix("\u{FEFF}") == true { lines[0].removeFirst() }
        var metadata: [String: String] = [:]
        var start = 0
        if trim(lines.first ?? "") == "---", let end = lines.dropFirst().firstIndex(where: { trim($0) == "---" }) {
            var listKey = ""
            for line in lines[1..<end] {
                let value = trim(line)
                if value.isEmpty || value.hasPrefix("#") { continue }
                if value.hasPrefix("- "), listKey == "tags" {
                    recipe.tags.append(unquote(trim(String(value.dropFirst(2)))))
                } else if let colon = value.firstIndex(of: ":"), !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                    let key = trim(String(value[..<colon])).lowercased()
                    let content = trim(String(value[value.index(after: colon)...]))
                    metadata[key] = unquote(content); listKey = key
                    if content == "|" || content == ">" { recipe.warnings.append("Some multi-line metadata is kept in the original file only.") }
                } else { recipe.warnings.append("Some advanced metadata is kept in the original file only.") }
            }
            start = end + 1
        } else if trim(lines.first ?? "") == "---" {
            recipe.warnings.append("The metadata header is not closed. Review the imported steps.")
        }

        var stepLines: [String] = []
        var inBlockComment = false
        func flushStep() {
            let step = trim(stepLines.joined(separator: " ").replacingOccurrences(of: "\\ ", with: "\n"))
            if !step.isEmpty { recipe.steps.append(step) }
            stepLines.removeAll(keepingCapacity: true)
        }
        for raw in lines.dropFirst(start) {
            let clean = stripComments(raw, inBlock: &inBlockComment)
            let line = trim(clean)
            if line.hasPrefix(">>") {
                let meta = trim(String(line.dropFirst(2)))
                if let colon = meta.firstIndex(of: ":") {
                    metadata[trim(String(meta[..<colon])).lowercased()] = unquote(trim(String(meta[meta.index(after: colon)...])))
                }
                continue
            }
            if line.isEmpty {
                if trim(raw).isEmpty { flushStep() }
                continue
            }
            if line.hasPrefix(">") {
                flushStep(); recipe.notes.append(trim(String(line.dropFirst()))); continue
            }
            if line.hasPrefix("=") {
                flushStep()
                let heading = trim(line.trimmingCharacters(in: CharacterSet(charactersIn: "=")))
                if !heading.isEmpty { recipe.notes.append("Section: \(heading)") }
                continue
            }
            stepLines.append(render(line, recipe: &recipe))
        }
        flushStep()
        if inBlockComment { recipe.warnings.append("An unfinished comment was found; review the original file.") }
        func first(_ keys: String...) -> String { keys.compactMap { metadata[$0] }.first(where: { !$0.isEmpty }) ?? "" }
        let title = first("title", "name"); if !title.isEmpty { recipe.title = title }
        recipe.description = first("description")
        recipe.sourceURL = first("source", "source_url", "url")
        recipe.sourceName = first("source_name", "publisher")
        recipe.author = first("author")
        recipe.license = first("license", "licence")
        recipe.imageAttribution = first("image_attribution", "image credit")
        recipe.imageURL = first("image", "image_url")
        recipe.servings = first("servings", "yield")
        recipe.prepTime = first("prep time", "prep_time", "preptime")
        recipe.cookTime = first("cook time", "cook_time", "cooktime", "time")
        if let tags = metadata["tags"], !tags.isEmpty {
            if let data = tags.data(using: .utf8), let list = try? JSONDecoder().decode([String].self, from: data) {
                recipe.tags += list
            } else {
                recipe.tags += tags.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .components(separatedBy: ",").map { unquote(trim($0)) }.filter { !$0.isEmpty }
                if tags.contains("\"") || tags.contains("'") { recipe.warnings.append("Check tags with quotes or commas against the original file.") }
            }
        }
        recipe.tags = Array(NSOrderedSet(array: recipe.tags)) as? [String] ?? recipe.tags
        recipe.warnings = Array(NSOrderedSet(array: recipe.warnings)) as? [String] ?? recipe.warnings
        guard !recipe.steps.isEmpty else { throw ParseError.noSteps }
        guard recipe.ingredients.count <= 500, recipe.steps.count <= 500 else { throw ParseError.tooManyItems }
        if recipe.ingredients.isEmpty { recipe.warnings.append("No marked ingredients were found. Add or check ingredients before saving.") }
        if recipe.servings.isEmpty { recipe.warnings.append("No serving count was supplied. Confirm it in the recipe editor.") }
        return recipe
    }

    /// Portable basic syntax for edited recipes. The untouched original has its own export action.
    static func export(_ recipe: PortableCooklangRecipe) -> String {
        func quote(_ value: String) -> String {
            let data = try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed, .withoutEscapingSlashes])
            let string = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            return String(string.dropFirst().dropLast())
        }
        var lines = ["---", "title: \(quote(recipe.title))"]
        let values = [("description", recipe.description), ("source", recipe.sourceURL), ("source_name", recipe.sourceName),
                      ("author", recipe.author), ("license", recipe.license), ("image_attribution", recipe.imageAttribution),
                      ("image", recipe.imageURL), ("servings", recipe.servings), ("prep_time", recipe.prepTime), ("cook_time", recipe.cookTime)]
        for (key, value) in values where !value.isEmpty { lines.append("\(key): \(quote(value))") }
        if !recipe.tags.isEmpty { lines.append("tags: [\(recipe.tags.map(quote).joined(separator: ", "))]") }
        lines += ["---", ""]
        for note in recipe.notes { lines += note.components(separatedBy: .newlines).map { "> \($0)" } }
        if !recipe.notes.isEmpty { lines.append("") }
        let ingredients = recipe.ingredients.map { ingredient in
            let safeName = safeComponent(ingredient.name)
            let quantity = safeComponent(ingredient.quantity)
            let unit = safeComponent(ingredient.unit)
            let amount = unit.isEmpty ? quantity : "\(quantity)%\(unit)"
            let preparation = ingredient.preparation.isEmpty ? "" : "(\(ingredient.preparation.replacingOccurrences(of: ")", with: "")))"
            return "@\(safeName){\(amount)}\(preparation)"
        }
        if !ingredients.isEmpty { lines += ["Gather \(ingredients.joined(separator: ", ")).", ""] }
        for step in recipe.steps {
            // Escape literal markup so existing instructions do not create phantom ingredients.
            lines += [step.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "@", with: "\\@")
                .replacingOccurrences(of: "#", with: "\\#")
                .replacingOccurrences(of: "~", with: "\\~"), ""]
        }
        return lines.joined(separator: "\n")
    }

    private static func render(_ line: String, recipe: inout PortableCooklangRecipe) -> String {
        let chars = Array(line)
        var result = "", i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count, "@#~\\".contains(chars[i + 1]) {
                result.append(chars[i + 1]); i += 2; continue
            }
            let marker = chars[i]
            guard "@#~".contains(marker) else { result.append(chars[i]); i += 1; continue }
            let nameStart = i + 1
            var end = nameStart
            while end < chars.count, chars[end] != "{", chars[end] != "@", chars[end] != "#", chars[end] != "~" { end += 1 }
            var name = "", amount = "", consumed = i + 1
            if end < chars.count, chars[end] == "{", let close = chars[(end + 1)...].firstIndex(of: "}") {
                name = trim(String(chars[nameStart..<end])); amount = String(chars[(end + 1)..<close]); consumed = close + 1
            } else {
                if end < chars.count, chars[end] == "{" { recipe.warnings.append("An ingredient or timer amount is not closed. Check it against the original file.") }
                var single = nameStart
                while single < chars.count, chars[single].isLetter || chars[single].isNumber || chars[single] == "_" || chars[single] == "-" { single += 1 }
                name = String(chars[nameStart..<single]); consumed = single
            }
            if name.isEmpty && amount.isEmpty { result.append(marker); i += 1; continue }
            var preparation = ""
            if consumed < chars.count, chars[consumed] == "(", let close = chars[(consumed + 1)...].firstIndex(of: ")") {
                preparation = String(chars[(consumed + 1)..<close]); consumed = close + 1
            }
            let parts = amount.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let quantity = trim(parts.first ?? ""), unit = trim(parts.count > 1 ? parts[1] : "")
            if marker == "@" {
                if name.hasPrefix("./") || name.hasPrefix("../") { recipe.warnings.append("Linked recipes are kept as ingredient references; their files are not loaded automatically.") }
                let ingredient = PortableCooklangIngredient(name: name, quantity: quantity, unit: unit, preparation: preparation)
                recipe.ingredients.append(ingredient)
                result += name + (preparation.isEmpty ? "" : " (\(preparation))")
            } else if marker == "#" { result += name }
            else { result += [quantity, unit, name.isEmpty ? "" : "(\(name))"].filter { !$0.isEmpty }.joined(separator: " ") }
            i = consumed
        }
        return result
    }

    private static func stripComments(_ line: String, inBlock: inout Bool) -> String {
        var result = "", index = line.startIndex
        while index < line.endIndex {
            let tail = line[index...]
            if inBlock {
                if tail.hasPrefix("-]") { inBlock = false; index = line.index(index, offsetBy: 2) }
                else { index = line.index(after: index) }
            } else if tail.hasPrefix("[-") { inBlock = true; index = line.index(index, offsetBy: 2) }
            else if tail.hasPrefix("--") { break }
            else { result.append(line[index]); index = line.index(after: index) }
        }
        return result
    }
    private static func trim(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func unquote(_ value: String) -> String {
        if value.hasPrefix("\""), let data = value.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) { return decoded }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") { return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        return value
    }
    private static func safeComponent(_ value: String) -> String {
        value.replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
            .replacingOccurrences(of: "%", with: " percent ").replacingOccurrences(of: "\n", with: " ")
    }
}

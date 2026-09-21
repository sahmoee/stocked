import Foundation

@main @MainActor struct KitchenMigrationChecks {
    static var checks = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        do { let result = try condition(); precondition(result, message); checks += 1 }
        catch { fatalError("\(message): \(error)") }
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        func bytes(_ file: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(file)) }
        func read(_ file: String) throws -> KitchenMigrationBatch { try KitchenMigration.decode(bytes(file), filename: file) }
        func json(_ item: KitchenMigrationItem) throws -> [String: Any] { try JSONSerialization.jsonObject(with: item.recipeJSON) as! [String: Any] }
        func fails(_ file: String, _ message: String) {
            do { _ = try read(file); fatalError(message) } catch { checks += 1 }
        }
        let photo = try bytes("photo.png")
        let schema = try read("schema.json")
        let s = try json(schema.items[0])
        expect(schema.items.count == 1 && s["name"] as? String == "Fixture café rice", "Schema UTF-8 title")
        expect(s["url"] as? String == "https://example.org/Recipes/Case", "Case-sensitive original URL")
        expect(s["author"] as? String == "Fixture Writer" && s["license"] as? String == "CC BY 4.0", "Declared author and license")
        expect(s["imageAttribution"] as? String == "Fixture Photographer", "Declared image credit")
        expect((s["image"] as? [String: String])?["url"] == "https://example.org/data/images/photo.png", "Image URL wins over caption")
        expect((s["comment"] as? [String: String])?["text"] == "A private family note.", "Private notes retained for review")
        expect(s["recipeIngredient"] as? [String] == ["1 cup cooked rice", "1 cup dry rice"], "Preparation distinctions preserved")
        expect(schema.items[0].originalText == String(data: try bytes("schema.json"), encoding: .utf8), "Exact original entry")
        let mealie = try read("mealie.zip"); let m = try json(mealie.items[0])
        expect(m["recipeIngredient"] as? [String] == ["1 cup cooked rice chilled", "2 eggs, beaten"], "Mealie food, quantity, and display priority")
        expect(m["recipeYield"] as? String == "4", "Mealie servings")
        expect(m["user_id"] == nil && m["household_id"] == nil && m["image"] == nil, "Do not normalize account IDs or image version as public facts")
        expect(mealie.items[0].localImage == photo, "Mealie exact original image bytes")
        let tandoor = try read("tandoor.zip"); let t = try json(tandoor.items[0])
        expect(tandoor.items.count == 1 && tandoor.items[0].localImage != nil, "Tandoor nested ZIP")
        expect((t["recipeInstructions"] as? [[String: String]])?.first?["text"] == "Mix\nMix ingredients.", "Tandoor step ordering")
        expect(t["recipeIngredient"] as? [String] == ["0.5 cup dry rice rinsed", "salt"], "Tandoor no_amount does not invent a quantity or unit")
        expect(t["cookTime"] == nil && ((t["comment"] as? [String: String])?["text"] ?? "").contains("Waiting time"), "Do not call resting time cooking")
        let paprika = try read("paprika.paprikarecipes"); let p = try json(paprika.items[0])
        expect(paprika.items.count == 1 && paprika.items[0].localImage == photo, "Paprika ZIP plus gzip and exact inline photo")
        expect(paprika.items[0].originalText == nil && !paprika.items[0].warnings.isEmpty, "Embedded photo never becomes raw source text")
        expect((p["publisher"] as? [String: String])?["name"] == "Fixture Publisher", "Paprika publisher not invented author")
        let plain = try read("plain.paprikarecipe")
        expect(plain.items[0].filename.hasSuffix(".json") && plain.items[0].originalText?.hasPrefix("{") == true, "Gzip source export is explicitly JSON text")
        let recipya = try read("recipya.zip")
        expect(recipya.items[0].localImage == photo, "Recipya folder photo matches URL filename")
        let duplicates = try read("duplicates.zip")
        expect(duplicates.items.count == 1 && duplicates.warnings.contains(where: { $0.contains("identical") }), "Canonical exact duplicates reported")
        expect(try read("changed.json").items.count == 2, "Different source metadata kept for review")
        let array = try read("array.json")
        expect(array.items.count == 2 && array.items.allSatisfy { $0.originalText == nil }, "No fabricated originals for array entries")
        expect(try read("graph.json").items.count == 1, "Only Recipe graph nodes")
        expect(try read("wrapper.json").items.count == 4, "Legacy converted recipe collection wrapper")
        expect((try json(read("aliased-mealie.json").items[0]))["recipeIngredient"] as? [String] == ["1 cup cooked rice chilled", "2 eggs, beaten"], "Aliased Mealie structured ingredients take precedence over generic Recipe marker")
        expect(try read("image-isolation.zip").items[0].localImage == nil, "Never attach neighboring recipe photo")
        expect(try read("huge-photo.zip").items[0].localImage == nil, "Pixel bomb photo rejected before decode")
        expect(try read("webp.zip").items[0].localImage == nil, "Unsupported photo not silently converted")
        expect(try read("partial.zip").items.count == 1, "Malformed and settings entries excluded")
        expect(try read("big-original.json").items[0].originalText == nil, "Oversized original omitted while normalized snapshot remains usable")
        expect(try read("inline-array-photo.json").items[0].originalText == nil, "Inline photo arrays excluded from raw provenance")
        fails("too-many.json", "Recipe count limit")
        fails("too-large.json", "Normalized recipe size limit")
        fails("no-recipes.zip", "Settings-only archive must not succeed")
        fails("deep.zip", "Nested depth bound")
        fails("too-many-entries.zip", "Whole import entry count")
        fails("too-many-directories.zip", "Whole import includes directory entries")
        fails("heading-only.json", "A section heading alone is not cooking directions")
        fails("gzip-budget.zip", "Whole import gzip expanded budget")
        fails("nested-budget.zip", "Whole import nested ZIP expanded budget")
        do { _ = try KitchenMigration.decode(Data(repeating: 0, count: KitchenMigration.maximumBytes + 1), filename: "large.zip"); fatalError("Input bound") }
        catch { checks += 1 }
        let cancelled = Task.detached { () throws -> KitchenMigrationBatch in
            while !Task.isCancelled { await Task.yield() }
            return try KitchenMigration.decode(Data("{}".utf8), filename: "cancelled.json")
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancellation must propagate") }
        catch is CancellationError { checks += 1 }
        print("Kitchen migration checks passed: \(checks)")
    }
}

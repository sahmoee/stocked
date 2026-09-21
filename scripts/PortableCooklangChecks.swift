// Native check: xcrun swiftc Stocked/PortableCooklang.swift scripts/PortableCooklangChecks.swift -o /tmp/stocked-cooklang-checks
import Foundation

@main struct PortableCooklangChecks {
    static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            count += 1; precondition(value(), "FAILED: \(message)")
        }
        let source = """
        ---
        title: "Weeknight soup"
        servings: 2
        author: "Kitchen author"
        license: "CC BY 4.0"
        image_attribution: "Photo creator"
        tags:
          - easy
          - vegetables
        custom-field: preserve me
        ---
        > A note for next time.

        = Base =
        Mix @onion{1}(finely chopped) with @olive oil{1/2%tbsp} in a #large pan{}.
        Stir @salt to taste. -- stop before the comment

        Add @water{2%cup}. [- private reminder -] Simmer for ~soup{10%minutes}.
        """
        let parsed = try PortableCooklang.parse(source, fallbackTitle: "Fallback")
        check(parsed.title == "Weeknight soup", "YAML title")
        check(parsed.servings == "2", "servings")
        check(parsed.tags == ["easy", "vegetables"], "YAML tags")
        check(parsed.steps.count == 2, "paragraph steps")
        check(parsed.ingredients.count == 4, "repeated lines preserve ingredients")
        check(parsed.ingredients[0].preparation == "finely chopped", "preparation separated")
        check(parsed.ingredients[1].quantity == "1/2" && parsed.ingredients[1].unit == "tbsp", "fraction retained")
        check(parsed.ingredients[2].name == "salt", "single-word ingredient")
        check(parsed.steps[0].contains("large pan"), "cookware rendered")
        check(parsed.steps[1].contains("10 minutes (soup)"), "timer readable")
        check(!parsed.steps.joined().contains("private reminder"), "comments excluded from steps")
        check(parsed.originalText == source, "original byte-for-byte including unknown metadata and comments")
        check(parsed.notes.contains("Section: Base"), "section retained as note")
        check(parsed.author == "Kitchen author" && parsed.license == "CC BY 4.0" && parsed.imageAttribution == "Photo creator", "credits retained")
        let legacy = try PortableCooklang.parse(">> title: Old style\n>> source: https://example.com/recipe\n\nUse @egg{2} and @egg{1}.", fallbackTitle: "file")
        check(legacy.title == "Old style" && legacy.sourceURL == "https://example.com/recipe", "legacy metadata")
        check(legacy.ingredients.count == 2, "same ingredient not silently merged")
        let linked = try PortableCooklang.parse("Use @./sauce{100%g}.", fallbackTitle: "Sauce")
        check(linked.warnings.contains(where: { $0.contains("Linked recipes") }), "linked recipes explicit warning")
        let escaped = try PortableCooklang.parse("Write \\@hello, \\#tag and \\~later.", fallbackTitle: "Literal")
        check(escaped.ingredients.isEmpty && escaped.steps[0].contains("@hello"), "escaped markers do not create phantom ingredients")
        let malformed = try PortableCooklang.parse("Mix @rice{2. [- unfinished", fallbackTitle: "Broken")
        check(malformed.warnings.contains(where: { $0.contains("unfinished comment") }), "unclosed comment warning")
        let exported = PortableCooklang.export(parsed)
        let roundTrip = try PortableCooklang.parse(exported, fallbackTitle: "Export")
        check(roundTrip.title == parsed.title && roundTrip.author == parsed.author && roundTrip.license == parsed.license, "basic export credits and title")
        check(roundTrip.ingredients.map(\.name) == parsed.ingredients.map(\.name), "basic export ingredients")
        check(roundTrip.steps.count == parsed.steps.count + 1, "explicit gather step in basic export")
        check(roundTrip.tags == parsed.tags, "basic export tag round trip")
        check(roundTrip.imageAttribution == parsed.imageAttribution, "photo credit round trip")
        let comments = try PortableCooklang.parse("Mix @rice{1%cup}.\n-- comment without a blank paragraph\nStir gently.", fallbackTitle: "Rice")
        check(comments.steps.count == 1, "comments do not invent paragraph boundaries")
        let quotedTags = try PortableCooklang.parse("---\ntags: [\"fish, seafood\", \"quick\"]\n---\nCook gently.", fallbackTitle: "Fish")
        check(quotedTags.tags == ["fish, seafood", "quick"], "quoted comma tag preserved")
        do { _ = try PortableCooklang.parse(Array(repeating: "@rice{1}", count: 501).joined(separator: " "), fallbackTitle: "Many"); preconditionFailure("unbounded ingredients accepted") }
        catch PortableCooklang.ParseError.tooManyItems { count += 1 }
        do { _ = try PortableCooklang.parse(String(repeating: "x", count: PortableCooklang.maximumBytes + 1), fallbackTitle: "large"); preconditionFailure("oversize accepted") }
        catch PortableCooklang.ParseError.tooLarge { count += 1 }
        do { _ = try PortableCooklang.parse(" ", fallbackTitle: "empty"); preconditionFailure("empty accepted") }
        catch PortableCooklang.ParseError.empty { count += 1 }
        do { _ = try PortableCooklang.parse("---\ntitle: Only metadata\n---", fallbackTitle: "empty"); preconditionFailure("no steps accepted") }
        catch PortableCooklang.ParseError.noSteps { count += 1 }
        print("Portable Cooklang: \(count) native checks passed")
    }
}

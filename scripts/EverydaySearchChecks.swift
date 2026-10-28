import Foundation

@main
struct EverydaySearchChecks {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label)
            checks += 1
        }
        let pantry = ["Jalapeño peppers", "Produce", "Refrigerator", "Crisper drawer"]
        check(SearchNormalization.discoveryMatches(pantry, query: "jalapeno"), "accent insensitive")
        check(SearchNormalization.discoveryMatches(pantry, query: "pepers"), "deletion typo")
        check(SearchNormalization.discoveryMatches(pantry, query: "pepppers"), "insertion typo")
        check(SearchNormalization.discoveryMatches(pantry, query: "peppars"), "substitution typo")
        check(SearchNormalization.discoveryMatches(pantry, query: "peppres"), "adjacent transposition")
        check(SearchNormalization.discoveryMatches(pantry, query: "produce crisper"), "terms span category/location")
        check(SearchNormalization.discoveryMatches(pantry, query: "  JALAPEÑO\nCRISPER  "), "case and whitespace")
        check(SearchNormalization.discoveryMatches(pantry, query: "refrigerater"), "location typo")
        check(!SearchNormalization.discoveryMatches(pantry, query: "peppers freezer"), "all terms required")
        check(!SearchNormalization.discoveryMatches(["milk"], query: "sil"), "short words cannot fuzzy match")
        check(!SearchNormalization.discoveryMatches(["peppers"], query: "pappars"), "two typos rejected")
        check(SearchNormalization.discoveryMatches(pantry, query: ""), "empty query")
        check(!SearchNormalization.discoveryMatches([], query: "milk"), "empty record")
        check(!SearchNormalization.matches("peppers", query: "pepers"), "exact search remains strict for non-discovery consumers")
        check(SearchNormalization.fold("  Crème  ") == "creme", "identity folding unchanged")
        check(!SearchNormalization.discoveryMatches([String(repeating: "a", count: 100)], query: String(repeating: "a", count: 99) + "b"), "oversized fuzzy terms disabled")
        check(!SearchNormalization.discoveryMatches(pantry, query: "---"), "punctuation does not match everything")
        print("Everyday search: \(checks) checks passed")
    }
}

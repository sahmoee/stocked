// RecipeQuality.swift — Score how complete/usable a recipe is (#9 source).
//
// Recipes come from many sources of varying quality. A recipe with no steps, no cook time, and one
// ingredient is not worth surfacing the way a complete one is. This scores a recipe on the fields
// it actually has, so the app can rank better recipes higher and badge thin ones as "needs review".
//
// Pure and additive: pairs with SourceConfidence (the SourceBadge it returns) and is read by
// ranking/sorting code. Nothing depends on it until adopted.

import Foundation

enum RecipeQuality {

    /// A 0...100 completeness score plus the reasons behind it.
    struct Score {
        let value: Int                 // 0...100
        let reasons: [String]          // human-readable notes on what's missing
        var badge: SourceBadge {
            switch value {
            case 80...:   return .verified     // complete and usable
            case 50..<80: return .estimated    // usable but thin
            default:      return .needsReview  // missing too much
            }
        }
    }

    /// Score a recipe on the presence and richness of its fields.
    static func score(_ r: GeneratedRecipe) -> Score {
        var points = 0
        var reasons: [String] = []

        // Title (10)
        if !r.title.trimmingCharacters(in: .whitespaces).isEmpty { points += 10 }
        else { reasons.append("missing title") }

        // Ingredients (30): presence + enough of them
        if r.ingredients.isEmpty {
            reasons.append("no ingredients")
        } else {
            points += 18
            if r.ingredients.count >= 3 { points += 12 }
            else { reasons.append("very few ingredients") }
        }

        // Steps (30): presence + enough detail
        if r.steps.isEmpty {
            reasons.append("no steps")
        } else {
            points += 18
            if r.steps.count >= 3 { points += 12 }
            else { reasons.append("very few steps") }
        }

        // Cook time (10)
        if !r.cookTime.trimmingCharacters(in: .whitespaces).isEmpty { points += 10 }
        else { reasons.append("no cook time") }

        // Servings (5)
        if r.servings > 0 { points += 5 }
        else { reasons.append("no servings") }

        // Image (10)
        let hasImage = (r.imageURL?.isEmpty == false) || (r.imageData != nil)
        if hasImage { points += 10 }
        else { reasons.append("no image") }

        // Tips (5) — nice-to-have
        if !r.tips.trimmingCharacters(in: .whitespaces).isEmpty { points += 5 }

        return Score(value: min(points, 100), reasons: reasons)
    }

    /// Convenience: order recipes best-quality first. Stable for equal scores.
    static func ranked(_ recipes: [GeneratedRecipe]) -> [GeneratedRecipe] {
        recipes
            .map { ($0, score($0).value) }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    /// True if a recipe is complete enough to surface prominently.
    static func isHighQuality(_ r: GeneratedRecipe) -> Bool { score(r).value >= 80 }
}

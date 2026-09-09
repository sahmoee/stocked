// Native fixture check: xcrun swiftc Stocked/RecipeDisplayPolicy.swift scripts/RecipeImagePolicyChecks.swift -o /tmp/stocked-image-policy-checks
// Title validation is outside this image-only fixture; production image policy is compiled unchanged.
import Foundation
nonisolated enum RecipeQuality {
    static func hasMeaningfulTitle(_ title: String) -> Bool { !title.isEmpty }
}
@main struct RecipeImagePolicyChecks {
    static func main() {
        let stock = "https://food.fnr.sndimg.com/content/dam/images/food/editorial/homepage/fn-feature.jpg.rend.hgtvcom.1280.1280.suffix/1474463768097.webp"
        let variants = [stock, stock.replacingOccurrences(of: "1280.1280", with: "616.462"),
            "https://food.fnr.sndimg.com/content/dam/images/food/editorial/homepage/fn-feature.jpg?width=640",
            "https://food.fnr.sndimg.com/content/dam/images/food/editorial/homepage/fn%2Dfeature.jpg"]
        for value in variants {
            precondition(RecipeDisplayPolicy.isKnownPublisherPlaceholder(value))
            precondition(!RecipeDisplayPolicy.isLikelyRecipeImageURL(value))
            precondition(!RecipeDisplayPolicy.isPresentable(title: "Vegetable Soup", imageURL: value,
                imageData: Data([1]), ingredients: 3, steps: 1))
        }
        let dish = "https://food.fnr.sndimg.com/content/dam/images/food/fullset/2018/4/1/2/LS-Library_Roasted-Garlic-Bread_s4x3.jpg.rend.hgtvcom.1280.1280.suffix/1522678795843.webp"
        precondition(RecipeDisplayPolicy.isLikelyRecipeImageURL(dish, sourceURL: "https://www.foodnetwork.com/recipes/garlic-bread"))
        precondition(!RecipeDisplayPolicy.isKnownPublisherPlaceholder("https://other.example/content/dam/images/food/editorial/homepage/fn-feature.jpg"))
        precondition(!RecipeDisplayPolicy.isKnownPublisherPlaceholder("https://food.fnr.sndimg.com/content/dam/images/food/fullset/fn-feature-chicken.jpg"))
        precondition(RecipeDisplayPolicy.isPresentable(title: "Personal Soup", imageURL: nil,
            imageData: Data([1]), ingredients: 3, steps: 1))
        precondition(!RecipeDisplayPolicy.isLikelyRecipeImageURL("https://publisher.example/logo.png"))
        print("Recipe image policy checks passed: stock variants/cached bytes rejected; dish photos and personal images retained")
    }
}

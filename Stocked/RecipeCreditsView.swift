import SwiftUI

struct RecipeCreditsView: View {
    @Environment(AppSession.self) private var session
    let recipe: UserRecipe
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let source = RecipeBrowserPolicy.url(recipe.attributedSourceURL ?? "") {
                Link(recipe.sourceName?.isEmpty == false ? recipe.sourceName! : "Original recipe", destination: source)
            } else if let name = recipe.sourceName, !name.isEmpty {
                Text("Source: \(name)")
            }
            if let author = recipe.author, !author.isEmpty { Text("Recipe by \(author)") }
            if let credit = recipe.imageAttribution, !credit.isEmpty { Text("Photo: \(credit)") }
            if let license = recipe.license, !license.isEmpty {
                Text("Source license: \(license)")
                if let url = RecipeBrowserPolicy.url(license) { Link("Read source license", destination: url) }
            }
        }.font(.caption).foregroundStyle(session.themeSecondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

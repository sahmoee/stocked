import SwiftUI

struct OpenKitchenCreditsView: View {
    @Environment(AppSession.self) private var session
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Built with thanks").font(.title2.bold())
                Text("Stocked's portable recipe and planning tools use original app code and open formats. No external AI subscription is needed for these tools.")
                credit("Cooklang", "The Cooklang community created the portable .cook recipe format. Stocked supports a reviewed subset and keeps original imported text for export.", "https://cooklang.org/docs/spec/")
                credit("Cooklang Federation contributors", "Community recipe discovery uses the project's documented search API. Stocked's client is original code; the GPL-licensed Federation server is not bundled. Recipes retain their own author and source credits.", "https://github.com/cooklang/federation")
                credit("Grocy contributors", "The optional connection uses Grocy's documented API with an original client. No Grocy code or database is bundled. The Grocy project is MIT-licensed.", "https://github.com/grocy/grocy/blob/master/grocy.openapi.json")
                credit("IETF CalDAV and WebDAV contributors", "Calendar connections follow RFC 4791 by Cyrus Daboo, Bernard Desruisseaux and Lisa Dusseault, and WebDAV RFC 4918 edited by Lisa Dusseault. Stocked uses original code and Apple system frameworks.", "https://www.rfc-editor.org/rfc/rfc4791.html")
                credit("Schema.org", "Recipe files and publisher imports use the Recipe vocabulary. Recipe text and images still belong to their authors; importing a file does not grant permission to republish it.", "https://schema.org/Recipe")
                credit("ZIP format · PKWARE", "Stocked reads standard ZIP exports using original app code informed by the ZIP format specification. No files are extracted or run.", "https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT")
                credit("zlib · Jean-loup Gailly and Mark Adler", "Archive decompression uses the zlib library supplied by Apple. No new service, account or paid package is needed.", "https://zlib.net/zlib_license.html")
                credit("Mealie contributors", "Recipe export compatibility uses independently implemented readers. Mealie's application code is not bundled, and recipe authors retain their own rights.", "https://docs.mealie.io/")
                credit("Tandoor Recipes contributors", "Stocked can review supported recipe export archives without installing a Tandoor server or copying its application code.", "https://docs.tandoor.dev/features/import_export/")
                credit("Paprika Recipe Manager", "Supported local recipe exports can be reviewed in Stocked. Paprika's app, name and file format belong to their owners; Stocked does not connect to a Paprika account.", "https://www.paprikaapp.com/")
                credit("Recipya contributors", "Supported Recipe JSON exports use the open Schema.org vocabulary. Stocked's migration reader is original code, not a bundled Recipya server.", "https://github.com/reaper47/recipya")
                credit("Open Food Facts & Open Prices contributors", "Food and community price databases: ODbL. Individual database contents: Database Contents License where specified by Open Food Facts. Product images follow their stated Creative Commons Attribution-ShareAlike license. Keep source and image credits when sharing.", "https://openfoodfacts.github.io/documentation/docs/Product-Opener/api/tutorials/license-be-on-the-legal-side/")
                credit("USDA FoodData Central", "Nutrition data from the US Department of Agriculture is public domain (CC0). Availability and source dates are shown where provided; missing facts are not zero.", "https://fdc.nal.usda.gov/api-guide/")
                credit("OpenStreetMap contributors", "Map and community-price location data is credited to OpenStreetMap contributors under ODbL.", "https://www.openstreetmap.org/copyright")
                credit("IETF calendar standard", "Stocked exports calendar files using the iCalendar format described by RFC 5545.", "https://www.rfc-editor.org/rfc/rfc5545")
                credit("Open kitchen projects", "Thanks to Mealie, Tandoor Recipes, KitchenOwl and Grocy for ideas around portable recipes, pantry-aware shopping and shared kitchens. Their application code is not bundled in these tools.", "https://github.com/grocy/grocy")
                Text("Publisher names, marks and content belong to their owners. Other optional Stocked services retain their own terms. No affiliation or endorsement is implied.").font(.caption)
            }.padding(20).foregroundStyle(session.themeTextColor)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Sources & credits").navigationBarTitleDisplayMode(.inline)
    }
    private func credit(_ title: String, _ detail: String, _ url: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(session.themeSecondaryText)
            if let link = URL(string: url) { Link("Source & terms", destination: link) }
        }
    }
}

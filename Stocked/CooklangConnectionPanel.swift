import SwiftUI

/// Shared iOS/Mac presentation; each host supplies its complete current theme and
/// routes reviewed text into its existing private file-import owner.
struct CooklangConnectionPanel: View {
    let background: Color
    let card: Color
    let foreground: Color
    let secondary: Color
    let accent: Color
    let onReview: (CooklangFederationRecipe) async throws -> Void
    @AppStorage("cooklangFederationEndpoint_v1") private var savedEndpoint = CooklangFederationPolicy.defaultEndpoint
    @State private var endpointText = CooklangFederationPolicy.defaultEndpoint
    @State private var didLoadEndpoint = false
    @State private var query = ""
    @State private var activeQuery = ""
    @State private var activeEndpoint: URL?
    @State private var results: CooklangFederationPage?
    @State private var selected: CooklangFederationRecipe?
    @State private var busy = false
    @State private var message = ""
    @State private var generation = UUID()
    @State private var task: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Recipes from the Cooklang community", systemImage: "network")
                    .font(.title2.bold())
                Text("Search the free Cooklang Federation recipe index, then review a recipe before adding a private copy to your household.")
                    .foregroundStyle(secondary)
                DisclosureGroup("Recipe index connection") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("HTTPS Federation address", text: $endpointText)
                            .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                            .accessibilityLabel("Cooklang Federation HTTPS address")
                        Button("Use the Cooklang community index") { endpointText = CooklangFederationPolicy.defaultEndpoint }
                            .frame(minHeight: 44)
                        Text("A custom address must run the Cooklang Federation API. CookCLI's local recipe server is a different service. Stocked stores only this address on this device; no password or token is used.")
                            .font(.footnote).foregroundStyle(secondary)
                    }.padding(.top, 8)
                }
                TextField("Search recipes, for example lentil soup", text: $query)
                    .textFieldStyle(.roundedBorder).onSubmit { search(page: 1, startNew: true) }
                    .accessibilityLabel("Cooklang community recipe search")
                Button { search(page: 1, startNew: true) } label: {
                    Label("Search this index", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("cooklang-federation-search")
                Text("Searching sends your search words to the address above. Your saved recipes, shopping list and household details are not sent. Results and source text are unverified community content; check ingredients and original credits.")
                    .font(.footnote).foregroundStyle(secondary)
                if busy {
                    ProgressView("Reading the recipe index…")
                    Button("Stop") { cancel(); message = "Stopped. Nothing was added to your library." }.frame(minHeight: 44)
                }
                if !message.isEmpty { Text(message).font(.callout).accessibilityAddTraits(.updatesFrequently) }
                if let selected {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(selected.title).font(.headline)
                        if !selected.feedName.isEmpty { Text("Collection: \(selected.feedName)").font(.subheadline) }
                        if let source = selected.sourceURL ?? selected.enclosureURL { Link("Open original recipe source", destination: source) }
                        Text("The next screen shows the recipe, checks saved duplicates and lets you review its credits. It will not publish publicly.")
                            .font(.footnote).foregroundStyle(secondary)
                        Button("Review private import") { prepare(selected) }
                            .buttonStyle(.borderedProminent).disabled(busy)
                        Button("Close this recipe") { self.selected = nil }.disabled(busy).frame(minHeight: 44)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(card, in: RoundedRectangle(cornerRadius: 16))
                }
                if let results {
                    Text("\(results.cards.count) loaded results for ‘\(activeQuery)’ · page \(results.page)")
                        .font(.headline).accessibilityAddTraits(.updatesFrequently)
                    if let activeEndpoint { Text(activeEndpoint.host ?? "Recipe index").font(.footnote).foregroundStyle(secondary) }
                    if let warning = results.warning { Text(warning).font(.footnote).foregroundStyle(secondary) }
                    if results.cards.isEmpty { Text("No matches on this page. Try another recipe name or a broader search.").foregroundStyle(secondary) }
                    LazyVStack(spacing: 12) {
                        ForEach(results.cards) { item in
                            Button { load(item) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.title).font(.headline)
                                    if let summary = item.summary, !summary.isEmpty { Text(summary).font(.subheadline).foregroundStyle(secondary) }
                                    if !item.tags.isEmpty { Text(item.tags.prefix(8).joined(separator: " · ")).font(.footnote).foregroundStyle(secondary) }
                                    Label("Read recipe from index", systemImage: "book").font(.footnote)
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(16)
                                    .background(card, in: RoundedRectangle(cornerRadius: 16))
                            }.buttonStyle(.plain).disabled(busy)
                        }
                    }
                    HStack {
                        if results.page > 1 { Button("Previous page") { search(page: results.page - 1, startNew: false) }.frame(minHeight: 44) }
                        Spacer()
                        if results.hasMore { Button("Next page") { search(page: results.page + 1, startNew: false) }.frame(minHeight: 44) }
                    }.disabled(busy)
                    Text("One page is kept at a time, up to 20 recipes. Search is limited to 10 pages; narrow your words to find more specific recipes. No photos or publisher pages are downloaded during search.")
                        .font(.footnote).foregroundStyle(secondary)
                }
                Link("Cooklang Federation · project and API", destination: URL(string: "https://github.com/cooklang/federation")!)
                    .font(.footnote)
                Text("Cooklang contributors maintain the index. Recipe authors retain their rights. Stocked uses an original API client and does not include the Federation server's GPL code.")
                    .font(.footnote).foregroundStyle(secondary)
            }.padding(20).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
                .foregroundStyle(foreground)
        }.background(background.ignoresSafeArea()).tint(accent)
            .onAppear {
                guard !didLoadEndpoint else { return }; didLoadEndpoint = true
                if let valid = try? CooklangFederationPolicy.endpoint(savedEndpoint) { endpointText = valid.absoluteString }
                else { savedEndpoint = CooklangFederationPolicy.defaultEndpoint }
            }
            .onDisappear { cancel() }
    }

    private func cancel() { task?.cancel(); generation = UUID(); busy = false }
    private func start(_ operation: @escaping @MainActor () async throws -> Void) {
        task?.cancel(); generation = UUID(); let token = generation; busy = true; message = ""
        task = Task {
            defer { if generation == token { busy = false } }
            do { try await operation() }
            catch is CancellationError { }
            catch { if !Task.isCancelled && generation == token { message = error.localizedDescription } }
        }
    }
    private func search(page: Int, startNew: Bool) {
        do {
            let endpoint = try startNew ? CooklangFederationPolicy.endpoint(endpointText) : activeEndpoint ?? CooklangFederationPolicy.endpoint(endpointText)
            let text = startNew ? query : activeQuery
            _ = try CooklangFederationPolicy.searchURL(endpoint: endpoint, query: text, page: page)
            // Persist only a validated credential-free endpoint after explicit search,
            // never arbitrary draft text (which might accidentally contain a password).
            if startNew { savedEndpoint = endpoint.absoluteString }
            selected = nil
            start {
                let value = try await CooklangFederationClient.search(endpoint: endpoint, query: text, page: page)
                try Task.checkCancellation()
                activeEndpoint = endpoint; activeQuery = text; results = value
            }
        } catch { message = error.localizedDescription }
    }
    private func load(_ card: CooklangFederationCard) {
        guard let endpoint = activeEndpoint else { return }
        start {
            let value = try await CooklangFederationClient.recipe(endpoint: endpoint, id: card.id)
            try Task.checkCancellation(); selected = value
        }
    }
    private func prepare(_ recipe: CooklangFederationRecipe) {
        start { try await onReview(recipe); try Task.checkCancellation() }
    }
}

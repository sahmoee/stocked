import SwiftUI

/// A price lookup never sends household contents or uses the retailer/AI gateways.
actor CommunityPricesClient {
    static let shared = CommunityPricesClient()
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    enum Failure: LocalizedError {
        case unavailable, invalidBarcode, limited, invalidResponse
        var errorDescription: String? {
            switch self {
            case .invalidBarcode: "Enter a barcode with 8, 12, 13 or 14 digits."
            case .limited: "Community prices are busy. Try again later."
            case .unavailable: "Community prices aren't available right now. Your saved prices are still available."
            case .invalidResponse: "That response couldn't be read. Your saved prices haven't changed."
            }
        }
    }

    func lookup(_ input: String) async throws -> CommunityPriceResponse {
        let barcode = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard [8, 12, 13, 14].contains(barcode.count), barcode.utf8.allSatisfy({ (48...57).contains($0) }) else { throw Failure.invalidBarcode }
        let request: URLRequest? = await MainActor.run {
            guard let base = StockedWorkerClient.url(), base.scheme == "https" else { return nil }
            var request = URLRequest(url: base.appendingPathComponent("prices/community"), timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(["barcode": barcode])
            BuildConfig.authorizeWorkerRequest(&request)
            return request
        }
        guard let request else { throw Failure.unavailable }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard http.statusCode != 429 else { throw Failure.limited }
        guard http.statusCode == 200 else { throw Failure.unavailable }
        var body = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard body.count < 256 * 1024 else { throw Failure.invalidResponse }
            body.append(byte)
        }
        try Task.checkCancellation()
        let result = try JSONDecoder().decode(CommunityPriceResponse.self, from: body)
        guard result.barcode == barcode, result.observations.count <= 25,
              Set(result.observations.map(\.id)).count == result.observations.count,
              result.observations.allSatisfy({ $0.price.isFinite && $0.price >= 0 && $0.currency.count == 3
                  && $0.currency.utf8.allSatisfy({ (65...90).contains($0) }) }) else { throw Failure.invalidResponse }
        return result
    }
}

struct CommunityPricesView: View {
    @Environment(AppSession.self) private var session
    @State private var barcode = ""
    @State private var result: CommunityPriceResponse?
    @State private var problem = ""
    @State private var loading = false
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("See prices other people reported for a barcode. These may be from another store, date, package size or currency.")
                    .foregroundStyle(session.themeSecondaryText)
                TextField("Barcode", text: $barcode).keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Product barcode")
                Button(loading ? "Cancel lookup" : "Look up community prices") {
                    if loading { cancel() } else { lookup() }
                }.frame(minHeight: 44)
                Text("Only the barcode is sent to the Stocked server and Open Prices. Your household list and receipt images stay out of this lookup.")
                    .font(.caption).foregroundStyle(session.themeSecondaryText)
                if loading { ProgressView("Checking prices…") }
                if !problem.isEmpty { Text(problem).foregroundStyle(session.themeSecondaryText) }
                if let result {
                    Text("Barcode \(result.barcode)").font(.headline)
                    if result.observations.isEmpty { Text("No community prices found. You can still track prices from your own receipts.") }
                    ForEach(result.observations) { item in
                        ToolboxCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.price, format: .currency(code: item.currency)).font(.title2.bold())
                                Text([item.store, item.city, item.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                Text("Reported: \(item.observedAt ?? "date unknown")")
                                if let unit = item.pricePer { Text("Price basis: \(priceBasis(unit))") }
                                if item.discounted {
                                    Label(discountDescription(item.discountType), systemImage: "tag")
                                    if let regular = item.regularPrice, regular.isFinite, regular >= 0 {
                                        Text("Reported regular price: \(regular.formatted(.currency(code: item.currency)))")
                                            .font(.caption)
                                    }
                                }
                                if let url = safeLink(item.sourceURL) { Link("View price source", destination: url) }
                            }
                        }
                    }
                    Text(result.note).font(.caption)
                    Text("\(result.cached ? "Cached lookup" : "Checked"): \(result.fetchedAt)").font(.caption)
                    if result.moreAvailable { Text("Showing recent reports. More may be available at the source.").font(.caption) }
                    Link("Open Prices contributors · ODbL", destination: URL(string: "https://prices.openfoodfacts.org/")!)
                    Link("Database license", destination: URL(string: "https://opendatacommons.org/licenses/odbl/1-0/")!)
                    Link("Location data © OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                }
            }.padding(20).foregroundStyle(session.themeTextColor)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Community prices").navigationBarTitleDisplayMode(.inline)
        .onDisappear { cancel() }
    }

    private func safeLink(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host == "prices.openfoodfacts.org" else { return nil }
        return url
    }
    private func priceBasis(_ value: String) -> String {
        switch value {
        case "UNIT": "per item"
        case "KILOGRAM": "per kilogram"
        case "LITER": "per liter"
        default: value.lowercased().replacingOccurrences(of: "_", with: " ")
        }
    }
    private func discountDescription(_ value: String?) -> String {
        switch value {
        case "LOYALTY_PROGRAM": "Discount requires a store membership"
        case "QUANTITY": "Discount may require buying several"
        case "EXPIRES_SOON": "Discounted because it expires soon"
        case "SECOND_HAND": "Reported as a secondhand item"
        case "PICK_IT_YOURSELF": "Discount requires picking it yourself"
        default: "Reported as a discount — check the source"
        }
    }
    private func cancel() { generation = UUID(); task?.cancel(); task = nil; loading = false }
    private func lookup() {
        cancel()
        let token = generation, input = barcode
        result = nil; problem = ""; loading = true
        task = Task {
            defer { if generation == token { loading = false } }
            do {
                let value = try await CommunityPricesClient.shared.lookup(input)
                guard !Task.isCancelled, generation == token else { return }
                result = value
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                problem = (error as? CommunityPricesClient.Failure)?.errorDescription ?? "The lookup couldn't finish. Try again when connected."
            }
        }
    }
}

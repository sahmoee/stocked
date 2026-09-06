// GroceryStoreFinderView.swift — MapKit store finder with proper permission request.
import SwiftUI
import Combine
import MapKit
import CoreLocation
import Contacts

struct NearbyGroceryStore: Identifiable {
    let id = UUID()
    let name: String; let address: String; let distance: String
    let coordinate: CLLocationCoordinate2D
    let retailer: GroceryRetailerProfile?
    var providerLocationID: String? = nil
    var hasLiveCatalog: Bool = false
}

@MainActor
@Observable
class GroceryStoreFinder: NSObject, CLLocationManagerDelegate {
    var stores:     [NearbyGroceryStore] = []
    var isSearching = false
    var error:      String?
    var locationAuthorized = false
    var locationDenied     = false
    var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.33, longitude: -122.03),
        span:   MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1))

    let locationManager = CLLocationManager()  // internal for delegate fix
    private var userLocation: CLLocation?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = kCLDistanceFilterNone
    }

    // Keep delegate alive
    private func ensureDelegate() {
        if locationManager.delegate == nil {
            locationManager.delegate = self
        }
    }

    func requestLocationAndSearch() {
        ensureDelegate()
        let status = locationManager.authorizationStatus
        switch status {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationAuthorized = true
            locationDenied = false
            locationManager.requestLocation()
        case .denied, .restricted:
            locationDenied = true
            error = "Location access denied. Enter a zip code to search."
        @unknown default:
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func searchByZip(_ zip: String) {
        error = nil
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = zip
        MKLocalSearch(request: req).start { [weak self] response, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let firstItem = response?.mapItems.first {
                    let coord = self.coordinate(of: firstItem)
                    let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                    self.region = MKCoordinateRegion(center: coord,
                        span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1))
                    self.searchStores(near: loc)
                } else {
                    self.error = "Zip code not found. Try again."
                }
            }
        }
    }

    // Deployment target is iOS 26+, so we use the modern non-deprecated APIs directly:
    // .location for the coordinate and .address / .addressRepresentations for display.
    private func coordinate(of item: MKMapItem) -> CLLocationCoordinate2D {
        item.location.coordinate          // CLLocation is non-optional in iOS 26
    }

    // Returns a display-ready, framework-formatted address line.
    private func displayAddress(of item: MKMapItem, fallbackName: String) -> String {
        if let short = item.address?.shortAddress, !short.isEmpty { return short }
        if let full = item.address?.fullAddress, !full.isEmpty { return full }
        if let city = item.addressRepresentations?.cityWithContext, !city.isEmpty { return city }
        return fallbackName
    }

    /// Reverse-geocode the searched location once and persist the two-letter home state, so the
    /// grocery cart-handoff picker can rank in-region banners first. Best-effort and non-blocking.
    private func persistHomeState(from location: CLLocation) {
        CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
            guard let admin = placemarks?.first?.administrativeArea, !admin.isEmpty else { return }
            let code = GroceryKnowledgeBase.stateCode(admin)
            UserDefaults.standard.set(code, forKey: "stockedHomeState")
        }
    }

    private func searchStores(near location: CLLocation) {
        isSearching = true; error = nil; stores = []
        persistHomeState(from: location)
        // Start at 5 mi (~0.072°), expand to 10 mi then 20 mi if fewer than 3 results
        searchWithRadius(near: location, latDelta: 0.072, attempt: 1)
    }

    private func searchWithRadius(near location: CLLocation, latDelta: Double, attempt: Int) {
        let req = MKLocalSearch.Request()
        // Query PLUS a point-of-interest category filter. The old plain-text query
        // "grocery store supermarket" returned only a single best match on many devices;
        // filtering by the foodMarket POI category returns the full set of nearby stores.
        req.naturalLanguageQuery = "grocery"
        req.resultTypes = .pointOfInterest
        req.pointOfInterestFilter = MKPointOfInterestFilter(including: [.foodMarket])
        req.region = MKCoordinateRegion(center: location.coordinate,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: latDelta))
        MKLocalSearch(request: req).start { [weak self] response, err in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let items = response?.mapItems ?? []
                // Filter to stores within the actual radius
                let maxMeters = latDelta * 111_000 * 0.85
                let nearby = items.filter { item in
                    let coord = self.coordinate(of: item)
                    let sl = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                    return location.distance(from: sl) <= maxMeters
                }
                // Expand if fewer than 3 results and under 3 attempts
                if nearby.count < 3 && attempt < 3 {
                    let nextDelta: Double = attempt == 1 ? 0.145 : 0.29
                    self.searchWithRadius(near: location, latDelta: nextDelta, attempt: attempt + 1)
                    return
                }
                self.isSearching = false
                guard !items.isEmpty else {
                    self.error = err?.localizedDescription ?? "No stores found nearby."; return
                }
                self.region = MKCoordinateRegion(center: location.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: latDelta * 1.2, longitudeDelta: latDelta * 1.2))
                let source = nearby.isEmpty ? items : nearby
                self.stores = source.prefix(20)
                    .compactMap { item -> NearbyGroceryStore? in
                        let name  = item.name ?? "Grocery Store"
                        let coord = self.coordinate(of: item)
                        let sl    = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                        let d     = location.distance(from: sl)
                        let ds    = d < 1609
                            ? String(format: "%.0f ft", d * 3.281)
                            : String(format: "%.1f mi", d / 1609.34)
                        let adr   = self.displayAddress(of: item, fallbackName: name)
                        return NearbyGroceryStore(name: name, address: adr, distance: ds, coordinate: coord,
                                                  retailer: GroceryKnowledgeBase.retailer(matching: name))
                    }
                    .sorted {
                        let da = Double($0.distance.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).joined()) ?? 999
                        let db = Double($1.distance.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).joined()) ?? 999
                        return da < db
                    }
                Task { await self.mergeKrogerStores(near: location, radiusMiles: max(5, Int(latDelta * 86))) }
            }
        }
    }

    private func mergeKrogerStores(near location: CLLocation, radiusMiles: Int) async {
        let kroger = await KrogerRetailClient.shared.locations(near: location.coordinate,
                                                               radiusMiles: min(100, radiusMiles), limit: 30)
        guard !kroger.isEmpty else { return }
        var merged = stores
        for locationRecord in kroger {
            guard let lat = locationRecord.latitude, let lon = locationRecord.longitude else { continue }
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            let storeLocation = CLLocation(latitude: lat, longitude: lon)
            let meters = location.distance(from: storeLocation)
            let distance = meters < 1609 ? String(format: "%.0f ft", meters * 3.281)
                                         : String(format: "%.1f mi", meters / 1609.34)
            if let index = merged.firstIndex(where: {
                $0.name.localizedCaseInsensitiveContains(locationRecord.name)
                || locationRecord.name.localizedCaseInsensitiveContains($0.name)
                || CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
                    .distance(from: storeLocation) < 80
            }) {
                merged[index].providerLocationID = locationRecord.locationId
                merged[index].hasLiveCatalog = true
            } else {
                merged.append(NearbyGroceryStore(
                    name: locationRecord.name, address: locationRecord.address.display,
                    distance: distance, coordinate: coordinate,
                    retailer: GroceryKnowledgeBase.retailer(matching: locationRecord.name),
                    providerLocationID: locationRecord.locationId, hasLiveCatalog: true))
            }
        }
        stores = merged.sorted {
            CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude).distance(from: location)
            < CLLocation(latitude: $1.coordinate.latitude, longitude: $1.coordinate.longitude).distance(from: location)
        }.prefix(30).map { $0 }
    }

    // CLLocationManagerDelegate
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else { return }
        Task { @MainActor in self.userLocation = loc; self.searchStores(near: loc) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.error = "Location error. Try entering a zip code." }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let s = self.locationManager.authorizationStatus
            self.locationAuthorized = s == .authorizedWhenInUse || s == .authorizedAlways
            self.locationDenied     = s == .denied || s == .restricted
            if self.locationAuthorized {
                self.locationManager.requestLocation()
            }
        }
    }
}

struct GroceryStoreFinderView: View {
    @Environment(AppSession.self) private var session
    let embedded: Bool

    @State private var finder = GroceryStoreFinder()
    @State private var zipInput = ""
    @State private var showMap  = false
    @State private var showAllStores = false

    init(embedded: Bool = false) {
        self.embedded = embedded
    }

    var body: some View {
        Group {
            if embedded {
                finderContent
            } else {
                ScrollView(showsIndicators: false) { finderContent }
            }
        }
        .onAppear {
            // Only auto-search if already authorized — don't silently request permission.
            let status = CLLocationManager().authorizationStatus
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                finder.requestLocationAndSearch()
            }
        }
    }

    private var finderContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Grocery stores near you")
                    .scaledFont(16, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                Spacer()
                Button { withAnimation { showMap.toggle() } } label: {
                    Image(systemName: showMap ? "list.bullet" : "map.fill")
                        .scaledFont(16).foregroundStyle(Color.stockedGold)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 12)

            // Zip search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(session.themeTextColor.opacity(0.4))
                TextField("Enter zip code", text: $zipInput)
                    .scaledFont(14).foregroundStyle(session.themeTextColor)
                    .keyboardType(.numberPad)
                    .onSubmit { if !zipInput.isEmpty { finder.searchByZip(zipInput) } }
                if !zipInput.isEmpty {
                    Button { finder.searchByZip(zipInput) } label: {
                        Text("Search").scaledFont(12, weight: .semibold)
                            .foregroundStyle(Color.stockedWhite)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.stockedCharcoal).clipShape(Capsule())
                    }
                }
            }
            .padding(11).background(session.themeCardColor).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            .padding(.horizontal, 24).padding(.bottom, 10)

            // Use location button
            Button {
                finder.requestLocationAndSearch()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "location.fill").scaledFont(13)
                    Text(finder.locationAuthorized ? "Refresh Location" : "Use My Location")
                        .scaledFont(13, weight: .semibold)
                }
                .foregroundStyle(Color.stockedWhite)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(finder.locationDenied ? Color.stockedCharcoal.opacity(0.5) : Color.stockedCharcoal)
                .clipShape(Capsule())
            }
            .padding(.horizontal, 24).padding(.bottom, 12)
            .disabled(finder.locationDenied)

            if finder.locationDenied {
                Text("Location denied in Settings. Use a zip code instead.")
                    .scaledFont(11).foregroundStyle(.red)
                    .padding(.horizontal, 24).padding(.bottom, 8)
            }

            if finder.isSearching {
                HStack { Spacer(); ProgressView().tint(Color.stockedCharcoal); Spacer() }.padding(.top, 24)
            } else if let err = finder.error {
                Text(err).scaledFont(12).foregroundStyle(.red).padding(.horizontal, 24)
            } else if showMap && !finder.stores.isEmpty {
                Map(position: .constant(.region(finder.region))) {
                    ForEach(finder.stores) { store in
                        Annotation(store.name, coordinate: store.coordinate) {
                            ZStack {
                                Circle().fill(Color.stockedGold).frame(width: 30, height: 30)
                                    .shadow(color: .black.opacity(0.2), radius: 3)
                                Image(systemName: "cart.fill").scaledFont(13).foregroundStyle(.white)
                            }
                        }
                    }
                }
                .frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 24).padding(.bottom, 12)
                storeList
            } else if !finder.stores.isEmpty {
                storeList
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "cart.fill").scaledFont(32).foregroundStyle(session.themeTextColor.opacity(0.2))
                    Text("Use your location or enter a zip code").scaledFont(13)
                        .foregroundStyle(session.themeTextColor.opacity(0.45)).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.top, 24)
            }
        }
        .padding(.top, embedded ? 8 : 0)
    }

    private var visibleStores: [NearbyGroceryStore] {
        if !embedded || showAllStores { return finder.stores }
        return Array(finder.stores.prefix(5))
    }

    private var storeList: some View {
        VStack(spacing: 0) {
            ForEach(Array(visibleStores.enumerated()), id: \.element.id) { i, store in
                if i > 0 { Divider().padding(.leading, 68).padding(.horizontal, 24) }
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.stockedCharcoal).frame(width: 42, height: 42)
                        Image(systemName: "storefront.fill").scaledFont(16).foregroundStyle(Color.stockedGold)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.name).scaledFont(14, weight: .semibold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                        Text(store.address).scaledFont(11)
                            .foregroundStyle(session.themeTextColor.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                        if let retailer = store.retailer {
                            Text("Known labels: " + retailer.privateLabels.prefix(3).joined(separator: " · "))
                                .scaledFont(10).foregroundStyle(session.themeTextColor.opacity(0.42))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if store.hasLiveCatalog {
                            Label("Live price, availability, images & aisle data", systemImage: "checkmark.seal.fill")
                                .scaledFont(9.5, weight: .semibold).foregroundStyle(Color.stockedGold)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    Text(store.distance).scaledFont(11, weight: .semibold).foregroundStyle(Color.stockedGold)
                }
                .padding(.horizontal, 24).padding(.vertical, 11)
            }

            if embedded && finder.stores.count > 5 {
                Divider().padding(.horizontal, 24)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showAllStores.toggle() }
                } label: {
                    HStack {
                        Text(showAllStores ? "Show fewer stores" : "Show all \(finder.stores.count) stores")
                            .scaledFont(12.5, weight: .semibold)
                        Spacer()
                        Image(systemName: showAllStores ? "chevron.up" : "chevron.down")
                            .scaledFont(11, weight: .semibold)
                    }
                    .foregroundStyle(Color.stockedGold)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
        }
        .background(session.themeCardColor)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20).padding(.bottom, 12)
    }
}

#Preview { ZStack { Color.stockedBg.ignoresSafeArea(); ScrollView { GroceryStoreFinderView().padding(.top, 20) } } }

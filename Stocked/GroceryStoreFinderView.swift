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

    private func searchStores(near location: CLLocation) {
        isSearching = true; error = nil; stores = []
        // Start at 5 mi (~0.072°), expand to 10 mi then 20 mi if fewer than 3 results
        searchWithRadius(near: location, latDelta: 0.072, attempt: 1)
    }

    private func searchWithRadius(near location: CLLocation, latDelta: Double, attempt: Int) {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = "grocery store supermarket"
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
                        return NearbyGroceryStore(name: name, address: adr, distance: ds, coordinate: coord)
                    }
                    .sorted {
                        let da = Double($0.distance.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).joined()) ?? 999
                        let db = Double($1.distance.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).joined()) ?? 999
                        return da < db
                    }
            }
        }
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
    @State private var finder = GroceryStoreFinder()
    @State private var zipInput = ""
    @State private var showMap  = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Grocery Stores Near You")
                    .font(.system(size: 16, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Spacer()
                Button { withAnimation { showMap.toggle() } } label: {
                    Image(systemName: showMap ? "list.bullet" : "map.fill")
                        .font(.system(size: 16)).foregroundStyle(Color.stockedGold)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 12)

            // Zip search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(session.themeTextColor.opacity(0.4))
                TextField("Enter zip code", text: $zipInput)
                    .font(.system(size: 14)).foregroundStyle(session.themeTextColor)
                    .keyboardType(.numberPad)
                    .onSubmit { if !zipInput.isEmpty { finder.searchByZip(zipInput) } }
                if !zipInput.isEmpty {
                    Button { finder.searchByZip(zipInput) } label: {
                        Text("Search").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.stockedWhite)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.stockedCharcoal).clipShape(Capsule())
                    }
                }
            }
            .padding(11).background(Color.stockedWhite.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            .padding(.horizontal, 24).padding(.bottom, 10)

            // Use location button
            Button {
                finder.requestLocationAndSearch()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "location.fill").font(.system(size: 13))
                    Text(finder.locationAuthorized ? "Refresh Location" : "Use My Location")
                        .font(.system(size: 13, weight: .semibold))
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
                    .font(.system(size: 11)).foregroundStyle(.red)
                    .padding(.horizontal, 24).padding(.bottom, 8)
            }

            if finder.isSearching {
                HStack { Spacer(); ProgressView().tint(Color.stockedCharcoal); Spacer() }.padding(.top, 24)
            } else if let err = finder.error {
                Text(err).font(.system(size: 12)).foregroundStyle(.red).padding(.horizontal, 24)
            } else if showMap && !finder.stores.isEmpty {
                Map(position: .constant(.region(finder.region))) {
                    ForEach(finder.stores) { store in
                        Annotation(store.name, coordinate: store.coordinate) {
                            ZStack {
                                Circle().fill(Color.stockedGold).frame(width: 30, height: 30)
                                    .shadow(color: .black.opacity(0.2), radius: 3)
                                Image(systemName: "cart.fill").font(.system(size: 13)).foregroundStyle(.white)
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
                    Image(systemName: "cart.fill").font(.system(size: 32)).foregroundStyle(session.themeTextColor.opacity(0.2))
                    Text("Use your location or enter a zip code").font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.45)).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.top, 24)
            }
        } // end VStack
        } // end ScrollView
        .onAppear {
            // Only auto-search if already authorized — don't silently request permission
            let status = CLLocationManager().authorizationStatus
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                finder.requestLocationAndSearch()
            }
        }
    }

    private var storeList: some View {
        VStack(spacing: 0) {
            ForEach(Array(finder.stores.enumerated()), id: \.element.id) { i, store in
                if i > 0 { Divider().padding(.leading, 68).padding(.horizontal, 24) }
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.stockedCharcoal).frame(width: 42, height: 42)
                        Image(systemName: "storefront.fill").font(.system(size: 16)).foregroundStyle(Color.stockedGold)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.name).font(.system(size: 14, weight: .semibold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Text(store.address).font(.system(size: 11))
                            .foregroundStyle(session.themeTextColor.opacity(0.5)).lineLimit(1)
                    }
                    Spacer()
                    Text(store.distance).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.stockedGold)
                }
                .padding(.horizontal, 24).padding(.vertical, 11)
            }
        }
        .background(Color.stockedWhite.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 20).padding(.bottom, 12)
    }
}

#Preview { ZStack { Color.stockedBg.ignoresSafeArea(); ScrollView { GroceryStoreFinderView().padding(.top, 20) } } }

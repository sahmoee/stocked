import SwiftUI
@preconcurrency import UserNotifications

struct CommunityPriceWatchesView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = CommunityPriceWatchStore.shared
    @State private var edit: WatchEditorRequest?
    @State private var removal: CommunityPriceWatch?
    @State private var error = ""
    @State private var permission = "Checking notification access…"

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("Save your price targets").font(.stocked(.title2))
                Text("Check recent community reports when you choose. These are dated reports, not live quotes or a promise of stock. Nothing runs while Stocked is closed.")
                    .foregroundStyle(session.themeSecondaryText)
                Button("Add a price check") { edit = .init(value: CommunityPriceWatch(), baseline: nil) }.buttonStyle(.borderedProminent)
                Button(store.refreshing == nil ? "Check saved prices now" : "Stop checking") {
                    if store.refreshing == nil { store.refresh() } else { store.cancel() }
                }.disabled(store.watches.isEmpty)
                Toggle("Alert me after a check finds a match", isOn: Binding(get: { store.alertsEnabled }, set: {
                    store.alertsEnabled = $0
                    if $0 { NotificationPermissionCoordinator.promptFromUserAction() }
                }))
                Text(permission).font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                Button("Check notification access") { Task { await readPermission() } }.font(.stocked(.footnote))
                if store.refreshing != nil { ProgressView("Checking community prices…") }
                if !store.status.isEmpty { Text(store.status).font(.stocked(.footnote)) }
                if !error.isEmpty { Text(error).font(.stocked(.footnote)) }
                ForEach(store.watches.prefix(50)) { value in
                    ToolboxCard { watchCard(value) }
                }
                Text("Saved checks and results stay on this device and are separate from receipt prices and your household records. No currency conversion is used. Only the barcode goes to Stocked’s server and Open Prices; location and target filtering happen here. Device-only checks are not included in Kitchen Transfer backups.")
                    .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                Link("Open Prices contributors · ODbL", destination: URL(string: "https://prices.openfoodfacts.org/")!)
                Link("Location data © OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                Link("Database license", destination: URL(string: "https://opendatacommons.org/licenses/odbl/1-0/")!)
            }.padding(20).foregroundStyle(session.themeTextColor)
        }
        .background(session.themeBgColor.ignoresSafeArea()).tint(session.themeButtonColor)
        .navigationTitle("Saved price checks").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $edit) { request in
            CommunityPriceWatchEditor(value: request.value) { try store.save($0, baseline: request.baseline) }.environment(session)
        }
        .confirmationDialog("Remove this saved price check?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            if let removal { Button("Remove", role: .destructive) { do { try store.remove(removal) } catch { self.error = error.localizedDescription } } }
        } message: { Text("Its saved result and alerts are removed from this device. Your receipts and household prices stay.") }
        .task { await readPermission() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store.cancel() } else { Task { await readPermission() } }
        }
        .onDisappear { store.cancel() }
    }
    @ViewBuilder private func watchCard(_ value: CommunityPriceWatch) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(value.label).font(.stocked(.headline))
                    Text("At or below \(value.targetPrice.formatted(.currency(code: value.currency))) · \(value.basis.label.lowercased())")
                    Text("Barcode \(value.barcode)").font(.stocked(.caption))
                    Text([value.country, value.city].filter { !$0.isEmpty }.joined(separator: " · ").isEmpty ? "Any location — may be far from you" : [value.country, value.city].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.stocked(.footnote))
                }
                Spacer()
                Menu {
                    Button("Edit") { edit = .init(value: value, baseline: value) }
                    Button(value.paused ? "Resume" : "Pause") {
                        do { var changed = value; changed.paused.toggle(); try store.save(changed, baseline: value) }
                        catch { self.error = error.localizedDescription }
                    }
                    Button("Remove…", role: .destructive) { removal = value }
                } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("Options for \(value.label)")
            }
            if value.paused { Text("Paused").font(.stocked(.footnote)) }
            if let date = value.lastSuccess {
                Text("Last successful check: \(date.formatted(date: .abbreviated, time: .shortened))").font(.stocked(.footnote))
            } else { Text("Not checked yet").font(.stocked(.footnote)) }
            if let failure = value.failure {
                Label(failure, systemImage: "exclamationmark.arrow.triangle.2.circlepath").font(.stocked(.footnote))
                if value.match != nil { Text("Previous result below — not refreshed.").font(.stocked(.footnote)) }
            }
            if let match = value.match {
                Text(match.price, format: .currency(code: match.currency)).font(.stocked(.title2))
                Text("Reported \(match.observedAt ?? "date unknown") · \(value.basis.label.lowercased())")
                Text([match.store, match.city, match.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                if match.discounted { Text("Discount reported; check store membership, quantity and other conditions at the source.").font(.stocked(.footnote)) }
                if let url = URL(string: match.sourceURL), url.scheme == "https", url.host == "prices.openfoodfacts.org" {
                    Link("Check the original price report", destination: url)
                }
            } else if value.lastSuccess != nil { Text("No qualifying report at or below your target in the latest check.") }
            Text("Reports from the last \(value.maximumAgeDays) days. \(value.includeDiscounts ? "Discounts included." : "Discounts excluded.") \(value.excludedCount) reports excluded for age, location, currency or price basis.")
                .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
            Button("Check this barcode") { store.refresh(value.id) }.disabled(value.paused || store.refreshing != nil)
        }
    }
    private func readPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: permission = "Notifications allowed. Only a newly found match can create an alert after an explicit check."
        case .denied: permission = "Notifications are off in iOS Settings. Saved results still work here."
        default: permission = "Turn on alerts to request notification access; results work without it."
        }
    }
}

private struct WatchEditorRequest: Identifiable {
    let value: CommunityPriceWatch
    let baseline: CommunityPriceWatch?
    var id: UUID { value.id }
}
private struct CommunityPriceWatchEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State var value: CommunityPriceWatch
    let save: (CommunityPriceWatch) throws -> Void
    @State private var error = ""
    @State private var discard = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Your target") {
                    TextField("Name", text: $value.label)
                    TextField("Barcode", text: $value.barcode).keyboardType(.numberPad)
                    TextField("Currency code, such as USD", text: $value.currency).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    TextField("Maximum price", value: $value.targetPrice, format: .number).keyboardType(.decimalPad)
                    Picker("Price basis", selection: $value.basis) { ForEach(CommunityPriceWatch.Basis.allCases, id: \.self) { Text($0.label).tag($0) } }
                }.listRowBackground(session.themeCardColor)
                Section("Which reports count?") {
                    TextField("Country code, such as US (optional)", text: $value.country).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    TextField("City (optional exact match)", text: $value.city)
                    Stepper("Last \(value.maximumAgeDays) days", value: $value.maximumAgeDays, in: 1...365)
                    Toggle("Include discounts", isOn: $value.includeDiscounts)
                    Text("Unknown dates or price bases are excluded. Blank location fields allow reports anywhere. A discount may have extra conditions.").font(.stocked(.footnote))
                }.listRowBackground(session.themeCardColor)
                if !error.isEmpty { Text(error).listRowBackground(session.themeCardColor) }
            }
            .scrollContentBackground(.hidden).background(session.themeBgColor.ignoresSafeArea())
            .foregroundStyle(session.themeTextColor).navigationTitle("Price check").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { discard = true } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { do { try save(value); dismiss() } catch { self.error = error.localizedDescription } } }
            }
            .interactiveDismissDisabled()
            .confirmationDialog("Discard this draft?", isPresented: $discard, titleVisibility: .visible) { Button("Discard", role: .destructive) { dismiss() } }
        }.tint(session.themeButtonColor)
    }
}

import SwiftUI

struct FreeKitchenConnectionsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ConnectionCanvas {
                Text("Connect services you already have") .font(.stocked(.title2))
                Text("Use your own Grocy or CalDAV server. Stocked adds no subscription or hosted AI charge. These connections run only when you ask, and credentials stay on this device.")
                    .foregroundStyle(session.themeSecondaryText)
                NavigationLink { GrocyConnectionView() } label: {
                    ToolboxCard { Label("Grocy inventory and shopping", systemImage: "shippingbox").frame(minHeight: 44) }
                }
                NavigationLink { CalDAVConnectionView() } label: {
                    ToolboxCard { Label("Meals on your calendar", systemImage: "calendar").frame(minHeight: 44) }
                }
                Text("Grocy reads become reviewed additions to Stocked. Calendar publishing sends meal names, dates and servings to your selected calendar. Neither connection makes automatic changes in the background.")
                    .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
            }.navigationTitle("Free connections").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(session.accentColor)
    }
}

private struct GrocyConnectionView: View {
    @Environment(AppSession.self) private var session
    @State private var credentials: KitchenConnectionCredentials?
    @State private var choices: [GrocyReviewChoice] = []
    @State private var reasons: [String: String] = [:]
    @State private var visible = 40
    @State private var message = ""
    @State private var busy = false
    @State private var loadedAt: Date?
    @State private var showSetup = false
    @State private var confirmImport = false
    @State private var confirmDisconnect = false
    @State private var work: Task<Void, Never>?
    @State private var generation = UUID()
    private var selectedCount: Int { choices.filter(\.selected).count }

    var body: some View {
        ConnectionCanvas {
            Text("Bring in your Grocy lists").font(.stocked(.title2))
            Text("Read your server, compare the rows, then add up to 50 selected items at a time. Existing items and past imports are kept for manual comparison. Nothing is written back to Grocy.")
                .foregroundStyle(session.themeSecondaryText)
            ConnectionSetupStatus(kind: .grocy, endpoint: credentials?.endpoint, onSetup: { showSetup = true },
                                  onDisconnect: { confirmDisconnect = true })
            if credentials != nil {
                Button("Read Grocy now") { read() }.buttonStyle(.borderedProminent).disabled(busy)
                if let loadedAt { Text("Read \(loadedAt.formatted(date: .abbreviated, time: .shortened))").font(.stocked(.footnote)) }
            }
            if busy { ProgressView(); Button("Stop") { stop() }.frame(minHeight: 44) }
            if !message.isEmpty { Text(message).accessibilityAddTraits(.updatesFrequently) }
            ForEach(Array(choices.prefix(visible))) { choice in row(choice) }
            if choices.count > visible { Button("Show more items") { visible = min(choices.count, visible + 40) }.frame(minHeight: 44) }
            if !choices.isEmpty {
                Button("Review adding \(selectedCount) items") { confirmImport = true }
                    .buttonStyle(.borderedProminent).disabled(busy || selectedCount == 0 || selectedCount > 50)
                Text("Amounts such as kilograms or litres are not container counts. Confirm the number of packages yourself. Earliest due dates are shown for comparison and are not assigned to every package.")
                    .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
            }
        }
        .navigationTitle("Grocy").navigationBarTitleDisplayMode(.inline)
        .task { loadCredentials() }
        .onDisappear { stop() }
        .onChange(of: session.guestStore.inventoryRevision) { _, _ in refreshReasons() }
        .onChange(of: session.guestStore.groceryRevision) { _, _ in refreshReasons() }
        .sheet(isPresented: $showSetup) { ConnectionSetupEditor(kind: .grocy) { stop(); choices = []; loadCredentials() }.environment(session) }
        .confirmationDialog("Add these items to Stocked?", isPresented: $confirmImport, titleVisibility: .visible) {
            Button("Add selected items") { apply() }
            Button("Keep reviewing", role: .cancel) { }
        } message: { Text("Reviewed counts and storage choices enter your kitchen and follow your normal household sharing settings. Existing rows are never increased or replaced by this import.") }
        .confirmationDialog("Disconnect Grocy on this device?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { disconnect() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("The saved API key is removed. Imported food and duplicate-import history stay, so reconnecting cannot accidentally add the same stock again.") }
    }

    private func row(_ value: GrocyReviewChoice) -> some View {
        ToolboxCard {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(get: { choices.first(where: { $0.id == value.id })?.selected ?? false }, set: { selected in
                    guard !selected || selectedCount < 50 else { message = "Select up to 50 items per review."; return }
                    update(value.id) { $0.selected = selected }
                })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(value.row.name).font(.stocked(.headline))
                        Text("\(value.row.kind == .inventory ? "Inventory" : "Shopping") · Grocy: \(value.row.remoteAmount) \(value.row.unit)")
                            .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                    }
                }.disabled(busy || reasons[value.id] != nil)
                if let reason = reasons[value.id] { Text(reason).font(.stocked(.footnote)) }
                else {
                    Stepper(value: Binding(get: { choices.first(where: { $0.id == value.id })?.containers ?? 1 }, set: { count in
                        update(value.id) { $0.containers = count; $0.countConfirmed = true }
                    }), in: 1...999) { Text("\(value.containers) containers in Stocked") }.disabled(busy)
                    if value.row.suggestedContainers == nil {
                        Toggle("I checked this container count", isOn: Binding(get: { choices.first(where: { $0.id == value.id })?.countConfirmed ?? false }, set: { checked in update(value.id) { $0.countConfirmed = checked } })).disabled(busy)
                    }
                    if value.row.kind == .inventory {
                        Picker("Store in", selection: Binding(get: { choices.first(where: { $0.id == value.id })?.storage ?? .pantry }, set: { storage in update(value.id) { $0.storage = storage } })) {
                            ForEach(StorageCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.menu).disabled(busy)
                    }
                }
                if !value.row.note.isEmpty { Text(value.row.note).font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText) }
            }
        }
    }
    private func update(_ id: String, _ change: (inout GrocyReviewChoice) -> Void) {
        guard let index = choices.firstIndex(where: { $0.id == id }) else { return }; change(&choices[index])
    }
    private func loadCredentials() {
        do { credentials = try KitchenConnectionVault.load(.grocy) } catch { message = error.localizedDescription }
    }
    private func refreshReasons() {
        guard let credentials else { return }
        reasons = GrocyKitchenImport.reasons(for: choices.map(\.row), endpoint: credentials.endpoint, store: session.guestStore)
        for index in choices.indices where reasons[choices[index].id] != nil { choices[index].selected = false }
    }
    private func read() {
        guard let credentials else { return }
        if let problem = savedConnectionProblem(credentials, kind: .grocy) { self.credentials = nil; message = problem; return }
        stop()
        let token = UUID(), resetRevision = KitchenConnectionReset.revision
        generation = token; busy = true; message = "Reading four lists from your Grocy server…"
        let transport = KitchenGuardedConnectionTransport.saved(credentials, kind: .grocy)
        work = Task { @MainActor in
            defer { if generation == token { busy = false } }
            do {
                let rows = try await GrocyConnectionClient.read(credentials, transport: transport)
                try Task.checkCancellation(); guard generation == token, resetRevision == KitchenConnectionReset.revision else { return }
                choices = rows.map(GrocyReviewChoice.init); loadedAt = Date(); visible = 40; refreshReasons()
                message = rows.isEmpty ? "Grocy returned no stock or shopping items." : "Read \(rows.count) items. Select the additions you want."
            } catch { if generation == token { message = connectionMessage(error) } }
        }
    }
    private func apply() {
        guard let credentials, let loadedAt, Date().timeIntervalSince(loadedAt) < 600 else { message = "Refresh Grocy before importing this older preview."; return }
        if let problem = savedConnectionProblem(credentials, kind: .grocy) { self.credentials = nil; message = problem; return }
        let selected = choices.filter(\.selected)
        guard (1...50).contains(selected.count), selected.allSatisfy(\.countConfirmed) else { message = "Confirm every selected container count before importing."; return }
        let scope = GrocyKitchenImport.scope, token = UUID(), resetRevision = KitchenConnectionReset.revision
        generation = token; busy = true
        work = Task { @MainActor in
            var added = 0, kept = 0
            defer { if generation == token { busy = false; refreshReasons() } }
            do {
                for choice in selected {
                    try Task.checkCancellation(); guard generation == token, resetRevision == KitchenConnectionReset.revision else { return }
                    do { try GrocyKitchenImport.apply(choice, endpoint: credentials.endpoint, expectedScope: scope, store: session.guestStore); added += 1 }
                    catch KitchenConnectionFailure.changed { kept += 1 }
                    message = "Added \(added). Kept \(kept) duplicate or changed rows."
                    await Task.yield()
                }
                message = "Added \(added) items to Stocked. \(kept) existing or changed items were kept for manual review."
            } catch { if generation == token { message = "Added \(added) before stopping. \(connectionMessage(error))" } }
        }
    }
    private func stop() { generation = UUID(); work?.cancel(); work = nil; busy = false }
    private func disconnect() {
        stop()
        do { try KitchenConnectionVault.remove(.grocy); credentials = nil; choices = []; reasons = [:]; loadedAt = nil; message = "Disconnected on this device." }
        catch { message = error.localizedDescription }
    }
}

private struct CalDAVConnectionView: View {
    @Environment(AppSession.self) private var session
    @State private var credentials: KitchenConnectionCredentials?
    @State private var calendars: [CalDAVCalendar] = []
    @State private var calendarID = ""
    @State private var mode = 0
    @State private var firstDay = Date()
    @State private var windowDays = 30
    @State private var candidates: [CalDAVMeal] = []
    @State private var chosen = Set<String>()
    @State private var reviews: [CalDAVReviewRow] = []
    @State private var selectedWrites = Set<String>()
    @State private var reviewedSignature = ""
    @State private var message = ""
    @State private var busy = false
    @State private var showSetup = false
    @State private var confirmPublish = false
    @State private var confirmDisconnect = false
    @State private var work: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var visible = 40
    private var signature: String {
        "\(session.guestStore.planRevision)|\(PlanAheadStore.shared.revision)|\(HouseholdSync.shared.joinCode ?? "local")|\(mode)|\(firstDay.timeIntervalSince1970)|\(windowDays)|\(calendarID)|\(KitchenConnectionReset.revision)"
    }

    var body: some View {
        ConnectionCanvas {
            Text("Meals on your calendar").font(.stocked(.title2))
            Text("Connect an existing CalDAV calendar home. Publishing sends only meal names, dates and servings. Calendar edits never change your kitchen; this is a reviewed copy.")
                .foregroundStyle(session.themeSecondaryText)
            ConnectionSetupStatus(kind: .caldav, endpoint: credentials?.endpoint, onSetup: { showSetup = true }, onDisconnect: { confirmDisconnect = true })
            if credentials != nil {
                Button("Find my calendars") { discover() }.buttonStyle(.bordered).disabled(busy)
            }
            if !calendars.isEmpty {
                ToolboxCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Destination calendar", selection: $calendarID) { ForEach(calendars) { Text($0.title).tag($0.id) } }.pickerStyle(.menu)
                        Picker("Meals to copy", selection: $mode) { Text("Active week").tag(0); Text("Dated plans").tag(1) }.pickerStyle(.menu)
                        DatePicker(mode == 0 ? "Active week starts" : "First date to include", selection: $firstDay, displayedComponents: .date)
                        if mode == 1 {
                            Picker("Include", selection: $windowDays) { Text("14 days").tag(14); Text("30 days").tag(30); Text("90 days").tag(90) }.pickerStyle(.menu)
                        }
                    }.disabled(busy)
                }
                Text(mode == 0 ? "Check the start date: the active week uses relative days. Each published copy keeps the dates shown here."
                     : "Skipped meals and meals already moved into the active week are excluded. Use Active week for those copies.")
                    .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                ForEach(Array(candidates.prefix(visible))) { meal in
                    Toggle(isOn: Binding(get: { chosen.contains(meal.id) }, set: { value in
                        if value && chosen.count >= 50 { message = "Choose up to 50 meals per review."; return }
                        if value { chosen.insert(meal.id) } else { chosen.remove(meal.id) }; reviews = []; selectedWrites = []
                    })) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meal.title).font(.stocked(.headline))
                            Text("\(meal.civilDate) · \(meal.mealType) · \(meal.servings) servings").font(.stocked(.footnote))
                        }
                    }.disabled(busy)
                }
                if candidates.count > visible { Button("Show more meals") { visible = min(candidates.count, visible + 40) }.frame(minHeight: 44) }
                if candidates.isEmpty { Text("No meals in this selection. Add a plan or choose another date range.") }
                Button("Check \(chosen.count) calendar entries") { preflight() }.buttonStyle(.borderedProminent).disabled(busy || chosen.isEmpty)
            }
            if busy { ProgressView(); Button("Stop") { stop() }.frame(minHeight: 44) }
            if !message.isEmpty { Text(message).accessibilityAddTraits(.updatesFrequently) }
            ForEach(reviews) { row in
                ToolboxCard {
                    Toggle(isOn: Binding(get: { selectedWrites.contains(row.id) }, set: { value in
                        if value { selectedWrites.insert(row.id) } else { selectedWrites.remove(row.id) }
                    })) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(row.meal.title).font(.stocked(.headline))
                            Text(actionText(row.action)).font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                        }
                    }.disabled(busy || !row.mayPublish)
                }
            }
            if !reviews.isEmpty {
                Button("Publish \(selectedWrites.count) reviewed meals") { confirmPublish = true }
                    .buttonStyle(.borderedProminent).disabled(busy || selectedWrites.isEmpty)
                Text("Updates are allowed only when an entry created by this device still matches its last confirmed copy. Changed or unrelated events are kept. Nothing is automatically removed from the calendar.")
                    .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
            }
            Text("No CalDAV server? Plan tools can still save a free .ics calendar file.").font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
        }
        .navigationTitle("Calendar connection").navigationBarTitleDisplayMode(.inline)
        .task { loadCredentials(); refreshCandidates() }
        .onDisappear { stop() }
        .onChange(of: signature) { _, _ in reviews = []; selectedWrites = []; refreshCandidates() }
        .sheet(isPresented: $showSetup) { ConnectionSetupEditor(kind: .caldav) { stop(); calendars = []; reviews = []; loadCredentials() }.environment(session) }
        .confirmationDialog("Publish these meals to your calendar?", isPresented: $confirmPublish, titleVisibility: .visible) {
            Button("Publish reviewed meals") { publish() }
            Button("Keep reviewing", role: .cancel) { }
        } message: { Text("The selected calendar server receives the displayed names, dates and servings. Only checked new entries or unchanged Stocked copies will be written.") }
        .confirmationDialog("Disconnect this calendar on this device?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { disconnect() }; Button("Cancel", role: .cancel) { }
        } message: { Text("The device's saved credentials are removed. Previously published calendar events stay on your server.") }
    }

    private func loadCredentials() {
        do { credentials = try KitchenConnectionVault.load(.caldav) } catch { message = error.localizedDescription }
    }
    private func refreshCandidates() {
        do {
            candidates = try mode == 0 ? KitchenCalendarCandidates.active(session.guestStore.plannedMeals, firstDay: firstDay, timeZoneID: TimeZone.current.identifier)
                : KitchenCalendarCandidates.dated(PlanAheadStore.shared.scheduledMeals, firstDay: firstDay, days: windowDays, timeZoneID: TimeZone.current.identifier)
            chosen.formIntersection(Set(candidates.map(\.id)))
        } catch { candidates = []; message = connectionMessage(error) }
    }
    private func discover() {
        guard let credentials else { return }
        if let problem = savedConnectionProblem(credentials, kind: .caldav) { self.credentials = nil; message = problem; return }
        stop()
        let token = UUID(), resetRevision = KitchenConnectionReset.revision
        generation = token; busy = true; message = "Looking for calendars…"
        let transport = KitchenGuardedConnectionTransport.saved(credentials, kind: .caldav)
        work = Task { @MainActor in
            defer { if generation == token { busy = false } }
            do {
                let found = try await CalDAVConnectionClient.calendars(credentials, transport: transport)
                try Task.checkCancellation(); guard generation == token, resetRevision == KitchenConnectionReset.revision else { return }
                calendars = found; calendarID = found.first?.id ?? ""; refreshCandidates()
                message = "Found \(found.count) calendars. Choose where to send your meal copies."
            } catch { if generation == token { message = connectionMessage(error) } }
        }
    }
    private func preflight() {
        guard let credentials, let calendar = calendars.first(where: { $0.id == calendarID }), HouseholdSync.shared.can(.backupExport) else {
            message = KitchenConnectionFailure.permission.localizedDescription; return
        }
        if let problem = savedConnectionProblem(credentials, kind: .caldav) { self.credentials = nil; message = problem; return }
        let meals = candidates.filter { chosen.contains($0.id) }
        guard (1...50).contains(meals.count) else { return }
        stop(); let token = UUID(), expected = signature; generation = token; busy = true; reviews = []; selectedWrites = []
        let receipts = KitchenConnectionLedger.receipts()
        let transport = KitchenGuardedConnectionTransport.saved(credentials, kind: .caldav)
        work = Task { @MainActor in
            defer { if generation == token { busy = false } }
            do {
                var checked: [CalDAVReviewRow] = []
                for meal in meals {
                    try Task.checkCancellation()
                    guard generation == token, signature == expected, HouseholdSync.shared.can(.backupExport) else { throw KitchenConnectionFailure.changed }
                    let url = calendar.url.appendingPathComponent(meal.filename)
                    checked.append(try await CalDAVConnectionClient.preflight(meal, calendar: calendar, credentials: credentials,
                                                                            receipt: receipts[KitchenConnectionPolicy.hash(url.absoluteString)], transport: transport))
                    message = "Checked \(checked.count) of \(meals.count) calendar entries."
                }
                try Task.checkCancellation(); guard generation == token, signature == expected else { throw KitchenConnectionFailure.changed }
                reviews = checked; selectedWrites = Set(checked.filter(\.mayPublish).map(\.id)); reviewedSignature = expected
                message = "Review what will be created or updated. Changed and unrecognized events stay as they are."
            } catch { if generation == token { message = connectionMessage(error) } }
        }
    }
    private func publish() {
        guard let credentials, signature == reviewedSignature, HouseholdSync.shared.can(.backupExport) else { message = KitchenConnectionFailure.changed.localizedDescription; return }
        if let problem = savedConnectionProblem(credentials, kind: .caldav) { self.credentials = nil; message = problem; return }
        let rows = reviews.filter { selectedWrites.contains($0.id) && $0.mayPublish }
        guard (1...50).contains(rows.count) else { return }
        stop(); let token = UUID(), expected = signature, resetRevision = KitchenConnectionReset.revision; generation = token; busy = true
        let transport = KitchenGuardedConnectionTransport.saved(credentials, kind: .caldav)
        work = Task { @MainActor in
            var complete = 0
            defer { if generation == token { busy = false; reviews = []; selectedWrites = [] } }
            do {
                for row in rows {
                    try Task.checkCancellation()
                    guard generation == token, signature == expected, HouseholdSync.shared.can(.backupExport) else { throw KitchenConnectionFailure.changed }
                    let receipt = try await CalDAVConnectionClient.publish(row, credentials: credentials, transport: transport)
                    // A reset must not be undone by a request that completed after its local ledgers were cleared.
                    guard resetRevision == KitchenConnectionReset.revision else { return }
                    try KitchenConnectionLedger.remember(receipt, url: row.url); complete += 1
                    guard generation == token else { return }
                    message = "Published \(complete) of \(rows.count) meals."
                }
                message = "Published \(complete) meal copies. Future app changes need another review before publishing."
            } catch { if generation == token { message = "\(complete) confirmed copies published. The last request may have reached the server; refresh the preview before retrying. \(connectionMessage(error))" } }
        }
    }
    private func stop() { generation = UUID(); work?.cancel(); work = nil; busy = false }
    private func disconnect() {
        stop()
        do { try KitchenConnectionVault.remove(.caldav); credentials = nil; calendars = []; reviews = []; message = "Disconnected on this device." }
        catch { message = error.localizedDescription }
    }
    private func actionText(_ action: CalDAVReviewRow.Action) -> String {
        switch action {
        case .create: "Create a new private all-day event."
        case .update: "Update this device's unchanged Stocked copy."
        case .unchanged: "Already matches. No write needed."
        case .conflict: "Keep this event. It was changed elsewhere, was created elsewhere, or cannot be safely identified."
        }
    }
}

private struct ConnectionSetupStatus: View {
    let kind: KitchenConnectionKind
    let endpoint: String?
    let onSetup: () -> Void
    let onDisconnect: () -> Void
    var body: some View {
        ToolboxCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(endpoint == nil ? "Not connected on this device" : "Credentials saved on this device", systemImage: "lock.shield")
                if let endpoint { Text(endpoint).font(.stocked(.footnote)).textSelection(.enabled) }
                Button(endpoint == nil ? "Set up connection" : "Edit connection", action: onSetup).frame(minHeight: 44)
                if endpoint != nil { Button("Disconnect", role: .destructive, action: onDisconnect).frame(minHeight: 44) }
            }
        }
    }
}

private struct ConnectionSetupEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let kind: KitchenConnectionKind
    let onSaved: () -> Void
    @State private var endpoint = ""
    @State private var username = ""
    @State private var secret = ""
    @State private var hasSavedSecret = false
    @State private var message = ""
    var body: some View {
        NavigationStack {
            ConnectionCanvas {
                Text(kind == .grocy ? "Enter your Grocy web or /api address and an API key from Grocy settings."
                     : "Enter your calendar home URL (or full calendar URL), username and an app-specific password from your existing CalDAV service.")
                    .foregroundStyle(session.themeSecondaryText)
                ToolboxCard {
                    VStack(alignment: .leading, spacing: 16) {
                        TextField(kind == .grocy ? "https://your-server/grocy/api" : "https://your-server/calendars/you/", text: $endpoint)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).accessibilityLabel("HTTPS server address")
                        if kind == .caldav { TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled() }
                        SecureField(hasSavedSecret ? "Leave blank to keep this device's saved secret" : (kind == .grocy ? "Grocy API key" : "App password"), text: $secret)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                Text("Only this device's Keychain stores these credentials. They are not sent to Stocked's server, shared with your household, written to logs or included in app backups. Use HTTPS with a trusted certificate. Stocked refuses redirects rather than sending credentials to another address.")
                    .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                if kind == .caldav {
                    Text("This connection supports username/app-password authentication. Browser-only or OAuth-only services can use Plan tools' .ics export instead.")
                        .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                }
                if !message.isEmpty { Text(message).accessibilityAddTraits(.updatesFrequently) }
            }
            .navigationTitle(kind == .grocy ? "Connect Grocy" : "Connect CalDAV").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .task {
                do { if let saved = try KitchenConnectionVault.load(kind) { endpoint = saved.endpoint; username = saved.username; hasSavedSecret = true } }
                catch { message = error.localizedDescription }
            }
        }.tint(session.accentColor)
    }
    private func save() {
        do {
            let old = try KitchenConnectionVault.load(kind)
            var url = try KitchenConnectionPolicy.endpoint(endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
            if kind == .grocy && url.lastPathComponent != "api" { url.appendPathComponent("api") }
            // A changed server requires deliberate credential entry: never forward an old secret.
            let keeping = secret.isEmpty && old?.endpoint == url.absoluteString && old?.username == username
            let password = keeping ? old?.secret ?? "" : secret
            let value = KitchenConnectionCredentials(endpoint: url.absoluteString, username: username, secret: password)
            if kind == .caldav && username.isEmpty { throw KitchenConnectionFailure.credentials }
            try KitchenConnectionVault.save(value, kind: kind)
            secret = ""; onSaved(); dismiss()
        } catch { message = error.localizedDescription }
    }
}

private struct ConnectionCanvas<Content: View>: View {
    @Environment(AppSession.self) private var session
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) { content() }
                .padding(20).frame(maxWidth: 700, alignment: .leading).frame(maxWidth: .infinity)
                .font(.stocked(.body)).foregroundStyle(session.themeTextColor)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .toolbarBackground(session.themeBgColor, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
    }
}

private func connectionMessage(_ error: Error) -> String {
    if error is CancellationError { return KitchenConnectionFailure.cancelled.localizedDescription }
    return (error as? KitchenConnectionFailure)?.localizedDescription ?? KitchenConnectionFailure.response.localizedDescription
}

/// A screen may survive logout/reset in another app flow. Never let its cached
/// password start new work after the saved connection has been removed or changed.
private func savedConnectionProblem(_ cached: KitchenConnectionCredentials, kind: KitchenConnectionKind) -> String? {
    do {
        guard let saved = try KitchenConnectionVault.load(kind), saved.endpoint == cached.endpoint,
              saved.username == cached.username, saved.secret == cached.secret else {
            return "This device's connection was removed or changed. Reopen connection setup before continuing."
        }
        return nil
    } catch {
        return "The saved connection could not be checked. Unlock this device and reopen connection setup."
    }
}

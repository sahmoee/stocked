// KitchenTransferView.swift
// Full-screen kitchen transfer hub: Export, Import, Backup, Transfer (QR/Link/File/iCloud)
import SwiftUI
import Combine
import CloudKit
import UniformTypeIdentifiers

struct KitchenTransferView: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    @State private var manager = KitchenTransferManager()

    @State private var activeSheet:   ActiveSheet?
    @State private var showImporter   = false
    @State private var importMerge    = false
    @State private var showImportMode = false
    @State private var shareItems:    [Any] = []
    @State private var showQR         = false
    @State private var showTransfer       = false
    @State private var showDeviceExporter = false
    @State private var deviceBackupURL:   URL? = nil

    // Recipe removal by CSV. This gets its own importer rather than sharing the one
    // below, because that one hands the file to the manager's content sniffer, which
    // would read a recipe CSV as a pantry list and import it.
    @State private var showRemovalImporter = false
    @State private var removalPlan: RecipeCSVPlan? = nil

    enum ActiveSheet: Identifiable {
        case qr, transfer, importMode, share, removalPreview
        var id: Int {
            switch self {
            case .qr: return 0; case .transfer: return 1
            case .importMode: return 2; case .share: return 3
            case .removalPreview: return 4
            }
        }
    }

    private var store: GuestDataStore { session.guestStore }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                Capsule().fill(session.themeTextColor.opacity(0.18))
                    .frame(width: 40, height: 4)
                    .padding(.top, 10).padding(.bottom, 8)
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(session.themeTextColor)
                    }.buttonStyle(.plain)
                    Spacer()
                    Text("Stocked.")
                        .font(.system(size: 26, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Spacer()
                    Color.clear.frame(width: 24)
                }
                .padding(.horizontal, 20)
                Text("Kitchen Transfer")
                    .font(.system(size: 18, weight: .regular, design: .serif))
                    .foregroundStyle(session.themeTextColor.opacity(0.6))
                    .padding(.top, 4).padding(.bottom, 16)

                VStack(spacing: 20) {
                    kitchenSummaryCard
                    exportSection
                    importSection
                    backupSection
                    transferSection

                    // Status / error feedback
                    if !manager.statusMessage.isEmpty {
                        statusBanner(manager.statusMessage, isError: false)
                    }
                    if !manager.errorMessage.isEmpty {
                        statusBanner(manager.errorMessage, isError: true)
                    }

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .presentationDragIndicator(.hidden)
        // File exporter
        .fileExporter(
            isPresented: $showDeviceExporter,
            document: StockedDocument(url: manager.exportedFileURL),
            contentType: .data,
            defaultFilename: "Stocked_Backup"
        ) { result in
            switch result {
            case .success: manager.statusMessage = "Saved to Files ✓"
            case .failure(let e): manager.errorMessage = "Save failed: \(e.localizedDescription)"
            }
            showDeviceExporter = false
        }
        .fileExporter(
            isPresented: Binding(
                get: { manager.exportedFileURL != nil && !showDeviceExporter },
                set: { if !$0 { manager.exportedFileURL = nil } }
            ),
            document: StockedDocument(url: manager.exportedFileURL),
            contentType: .stockedKitchen,
            defaultFilename: "My-Kitchen"
        ) { result in
            switch result {
            case .success: manager.statusMessage = "Kitchen saved to Files!"
            case .failure(let e): manager.errorMessage = e.localizedDescription
            }
        }
        // File importer
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.stockedKitchen, .json, .commaSeparatedText, .plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    _ = manager.importFromURL(url, into: store, merge: importMerge)
                }
            case .failure(let e):
                manager.errorMessage = e.localizedDescription
            }
        }
        // Recipe-removal importer. Separate from the one above on purpose: this file is
        // read as a removal list, never as something to import.
        .fileImporter(
            isPresented: $showRemovalImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                loadRemovalCSV(from: url)
            case .failure(let e):
                manager.errorMessage = e.localizedDescription
            }
        }
        // All transfer-related sheets go through ONE .sheet(item:) — stacking a second
        // .sheet(isPresented:) for sharing alongside this one fires unreliably.
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .qr:
                QRTransferSheet(manager: manager, store: store)
                    .environment(session)
            case .transfer:
                TransferOptionsSheet(manager: manager, store: store) { items in
                    shareItems = items
                    // Close this sheet, then present the share sheet.
                    activeSheet = nil
                    Task {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        activeSheet = .share
                    }
                }
                .environment(session)
            case .importMode:
                ImportModeSheet(
                    onImportFile:  { importMerge = false; showImporter = true },
                    onMergeFile:   { importMerge = true;  showImporter = true },
                    onICloud:      { manager.restoreFromiCloud(into: store, merge: false) },
                    onMergeICloud: { manager.restoreFromiCloud(into: store, merge: true)  }
                )
            case .share:
                if !shareItems.isEmpty {
                    ShareSheet(items: shareItems)
                }
            case .removalPreview:
                if let plan = removalPlan {
                    RecipeCSVRemovalSheet(plan: plan) { userIDs, savedIDs in
                        applyRemoval(userIDs: userIDs, savedIDs: savedIDs)
                    }
                    .environment(session)
                }
            }
        }
        .onAppear { manager.session = session }
    }

    // MARK: - CSV recipe removal

    /// Reads the picked file and builds a plan. Nothing is deleted here — the plan is
    /// only a description of what *could* be, and the user still has to say yes.
    private func loadRemovalCSV(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            manager.errorMessage = "Couldn't open that file."
            return
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        guard !text.isEmpty else {
            manager.errorMessage = "That file looks empty."
            return
        }

        manager.errorMessage = ""
        manager.statusMessage = ""
        removalPlan = RecipeCSV.plan(from: text, store: store)
        activeSheet = .removalPreview
    }

    /// Called by the confirmation sheet once the user has picked. The sheet dismisses
    /// itself; we wait a beat before offering the backup so the share sheet doesn't
    /// collide with a sheet that is still on its way out.
    private func applyRemoval(userIDs: Set<UUID>, savedIDs: Set<UUID>) {
        let result = RecipeCSV.remove(userRecipeIDs: userIDs,
                                      savedRecipeIDs: savedIDs,
                                      store: store)
        removalPlan = nil
        activeSheet = nil

        guard result.removed > 0 else {
            manager.statusMessage = "Nothing was removed."
            return
        }
        manager.statusMessage = result.removed == 1
            ? "1 recipe removed ✓"
            : "\(result.removed) recipes removed ✓"

        if let backup = result.backupURL {
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                shareItems = [backup]
                activeSheet = .share
            }
        }
    }

    // MARK: - Kitchen Summary Card
    private var kitchenSummaryCard: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.displayName.isEmpty ? "My Kitchen" : "\(store.displayName)'s Kitchen")
                        .font(.system(size: 16, weight: .bold, design: .serif))
                        .foregroundStyle(Color.stockedWhite)
                    Text("Last backup: \(manager.lastBackupDate)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.stockedWhite.opacity(0.55))
                }
                Spacer()
                Image(systemName: "refrigerator.fill")
                    .font(.system(size: 28)).foregroundStyle(Color.stockedGold)
            }

            HStack(spacing: 0) {
                summaryPill("\(store.inventoryItems.count)", "Items")
                summaryPill("\(store.groceryItems.count)", "Grocery")
                summaryPill("\(store.pastMeals.count)", "Meals")
                summaryPill("\(store.stockPercent)%", "Stocked")
            }
        }
        .padding(20)
        .background(Color.stockedCharcoal)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func summaryPill(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 18, weight: .bold, design: .serif)).foregroundStyle(Color.stockedGold)
            Text(label).font(.system(size: 11)).foregroundStyle(Color.stockedWhite.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Export Section
    private var exportSection: some View {
        actionSection(title: "Export Kitchen", icon: "square.and.arrow.up.fill") {
            actionRow(
                icon: "doc.fill",
                iconColor: Color.stockedGold,
                title: "Export .stocked File",
                subtitle: "Native Stocked. format — re-import with full fidelity"
            ) {
                manager.exportToFile(store: store) { url in
                    if let url { shareItems = [url]; activeSheet = .share }
                }
            }

            Divider().padding(.leading, 52)

            actionRow(
                icon: "doc.text.fill",
                iconColor: Color.stockedInfo,
                title: "Export .json File",
                subtitle: "Open standard — import into any app or spreadsheet"
            ) {
                manager.exportToJSON(store: store) { url in
                    if let url { shareItems = [url]; activeSheet = .share }
                }
            }

            Divider().padding(.leading, 52)

            actionRow(
                icon: "tablecells.fill",
                iconColor: Color.stockedSuccess,
                title: "Export CSV (Spreadsheet)",
                subtitle: "Pantry + grocery as a spreadsheet — re-importable"
            ) {
                manager.exportToCSV(store: store) { url in
                    if let url { shareItems = [url]; activeSheet = .share }
                }
            }

            Divider().padding(.leading, 52)

            actionRow(
                icon: "list.bullet.rectangle.fill",
                iconColor: Color.stockedCharcoal,
                title: "Export Text List",
                subtitle: "Plain-text pantry + grocery list — re-importable"
            ) {
                manager.exportToText(store: store) { url in
                    if let url { shareItems = [url]; activeSheet = .share }
                }
            }

            Divider().padding(.leading, 52)

            actionRow(
                icon: "doc.richtext.fill",
                iconColor: Color.stockedError,
                title: "Export PDF (Printable)",
                subtitle: "A printable snapshot of your kitchen"
            ) {
                manager.exportToPDF(store: store) { url in
                    if let url { shareItems = [url]; activeSheet = .share }
                }
            }

            Divider().padding(.leading, 52)

            actionRow(
                icon: "tablecells.badge.ellipsis",
                iconColor: Color.stockedGold,
                title: "Export Recipes CSV",
                subtitle: "Every recipe as a spreadsheet — edit it to remove them in bulk"
            ) {
                if let url = RecipeCSV.writeExportFile(store: store) {
                    shareItems = [url]; activeSheet = .share
                } else {
                    manager.errorMessage = "Couldn't build the recipe spreadsheet."
                }
            }
        }
    }

    // MARK: - Import Section
    private var importSection: some View {
        actionSection(title: "Import Kitchen", icon: "square.and.arrow.down.fill") {
            actionRow(
                icon: "doc.badge.plus",
                iconColor: Color.stockedSuccess,
                title: "Import File",
                subtitle: "Load a .stocked or .json kitchen file"
            ) {
                activeSheet = .importMode
            }

            Divider().padding(.leading, 52)

            actionRow(
                icon: "trash.slash",
                iconColor: Color.stockedError,
                title: "Remove Recipes from CSV…",
                subtitle: "Export the spreadsheet, mark what to drop, bring it back"
            ) {
                manager.statusMessage = ""
                manager.errorMessage = ""
                showRemovalImporter = true
            }
        }
    }

    // MARK: - Backup Section
    private var backupSection: some View {
        actionSection(title: "Backup Kitchen", icon: "externaldrive.fill") {
            actionRow(
                icon: "icloud.fill",
                iconColor: Color.stockedInfo,
                title: "Backup to iCloud",
                subtitle: manager.isBacking ? "Backing up…" : "Stored privately in your iCloud"
            ) {
                manager.backupToiCloud(store: store)
            }
            .disabled(manager.isBacking)

            Divider().padding(.leading, 52)

            actionRow(
                icon: "clock.arrow.circlepath",
                iconColor: Color.stockedGold,
                title: "Restore from iCloud",
                subtitle: "Last saved: \(manager.lastBackupDate)"
            ) {
                manager.restoreFromiCloud(into: store)
            }
        }
    }

    // MARK: - Transfer Section
    private var transferSection: some View {
        actionSection(title: "Transfer Kitchen", icon: "arrow.left.arrow.right") {
            // QR Code
            actionRow(
                icon: "qrcode",
                iconColor: Color.stockedCharcoal,
                title: "QR Code",
                subtitle: "Show a QR code — another device scans to import"
            ) {
                manager.generateQRCode(for: store)
                activeSheet = .qr
            }

            Divider().padding(.leading, 52)

            // Share Link
            actionRow(
                icon: "link",
                iconColor: Color.stockedInfo,
                title: "Share Link",
                subtitle: "Generate a stocked:// deep link to send via Messages, Mail, etc."
            ) {
                if let url = manager.generateShareLink(for: store) {
                    shareItems  = [url]
                    activeSheet = .share
                }
            }

            Divider().padding(.leading, 52)

            // Export File (Share)
            actionRow(
                icon: "square.and.arrow.up",
                iconColor: Color.stockedGold,
                title: "Export File",
                subtitle: "Share a .stocked file via AirDrop, Messages, or Mail"
            ) {
                manager.exportToFile(store: store) { url in
                    if let url {
                        shareItems  = [url]
                        activeSheet = .share
                    }
                }
            }

            Divider().padding(.leading, 52)

            // iCloud
            actionRow(
                icon: "icloud.and.arrow.up.fill",
                iconColor: Color.stockedInfo,
                title: "iCloud",
                subtitle: "Backup now and restore on any signed-in device"
            ) {
                activeSheet = .transfer
            }
        }
    }

    // MARK: - Reusable layout pieces
    private func actionSection<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(session.themeTextColor.opacity(0.45))
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(session.themeTextColor.opacity(0.45))
                    .tracking(1)
            }
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                content()
            }
            .background(session.isDarkMode ? Color.white.opacity(0.08) : Color.stockedWhite.opacity(0.28))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private func actionRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(iconColor)
                        .frame(width: 38, height: 38)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(session.themeTextColor.opacity(0.3))
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    private func statusBanner(_ message: String, isError: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .red : Color.stockedGreen)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(isError ? .red : Color.stockedGreen)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background((isError ? Color.red : Color.stockedGreen).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }
}

// MARK: - QR Transfer Sheet
struct QRTransferSheet: View {
    @Environment(AppSession.self) var session
    var manager: KitchenTransferManager
    let store: GuestDataStore
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                // Handle
                Capsule().fill(Color.stockedCharcoal.opacity(0.18)).frame(width: 40, height: 4)
                    .padding(.top, 12).padding(.bottom, 24)

                Text("QR Code Transfer")
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor).padding(.bottom, 8)

                Text("Have another device running Stocked\nscan this code to import your kitchen.")
                    .font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.6))
                    .multilineTextAlignment(.center).padding(.bottom, 28)

                if let qrImage = manager.qrCodeImage {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable().scaledToFit()
                        .frame(width: 260, height: 260)
                        .padding(20)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                        .padding(.bottom, 20)

                    // Kitchen summary under QR
                    HStack(spacing: 20) {
                        Label("\(store.inventoryItems.count) items", systemImage: "tray.fill")
                        Label("\(store.stockPercent)% stocked", systemImage: "chart.bar.fill")
                    }
                    .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.6))
                    .padding(.bottom, 20)

                    // Save QR image button
                    Button {
                        UIImageWriteToSavedPhotosAlbum(qrImage, nil, nil, nil)
                        manager.statusMessage = "QR code saved to Photos!"
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "photo.badge.arrow.down.fill")
                            Text("Save to Photos")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color.stockedCharcoal).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                    }
                    .padding(.horizontal, 40)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
                            .fill(Color.stockedCharcoal.opacity(0.12))
                            .frame(width: 260, height: 260)
                        if manager.statusMessage.contains("Generating") {
                            VStack(spacing: 14) {
                                ProgressView().tint(Color.stockedCharcoal).scaleEffect(1.4)
                                Text("Generating…").font(.system(size: 14))
                                    .foregroundStyle(session.themeTextColor.opacity(0.5))
                            }
                        }
                    }
                    .padding(.bottom, 20)
                    .onAppear { manager.generateQRCode(for: store) }
                }

                if !manager.statusMessage.isEmpty && !manager.statusMessage.contains("Generating") {
                    Text(manager.statusMessage)
                        .font(.system(size: 13)).foregroundStyle(Color.stockedGreen)
                        .padding(.top, 12)
                }
                if !manager.errorMessage.isEmpty {
                    Text(manager.errorMessage)
                        .font(.system(size: 13)).foregroundStyle(.red)
                        .padding(.top, 8)
                }

                Spacer()
            }
            .padding(.horizontal, 28)
        }
        .presentationDetents([.large])
    }
}

// MARK: - Transfer Options Sheet (iCloud detail)
struct TransferOptionsSheet: View {
    @Environment(AppSession.self) var session
    var manager: KitchenTransferManager
    let store: GuestDataStore
    let onShareItems: ([Any]) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                Capsule().fill(Color.stockedCharcoal.opacity(0.18)).frame(width: 40, height: 4)
                    .padding(.top, 12).padding(.bottom, 24)

                Text("iCloud Kitchen Sync")
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor).padding(.bottom, 8)

                Text("Your kitchen data is stored privately\nin your personal iCloud.")
                    .font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.6))
                    .multilineTextAlignment(.center).padding(.bottom, 28)

                VStack(spacing: 14) {
                    iCloudActionButton(
                        icon: "icloud.and.arrow.up.fill",
                        title: "Backup to iCloud",
                        subtitle: "Last backup: \(manager.lastBackupDate)",
                        color: Color.stockedInfo,
                        isLoading: manager.isBacking
                    ) {
                        manager.backupToiCloud(store: store)
                    }

                    iCloudActionButton(
                        icon: "icloud.and.arrow.down.fill",
                        title: "Restore from iCloud",
                        subtitle: "Replaces current kitchen with backup",
                        color: Color.stockedGold,
                        isLoading: false
                    ) {
                        manager.restoreFromiCloud(into: store, merge: false)
                        dismiss()
                    }

                    iCloudActionButton(
                        icon: "arrow.triangle.merge",
                        title: "Merge with iCloud",
                        subtitle: "Adds backup items to current kitchen",
                        color: Color.stockedSuccess,
                        isLoading: false
                    ) {
                        manager.restoreFromiCloud(into: store, merge: true)
                        dismiss()
                    }
                }

                if !manager.statusMessage.isEmpty {
                    Text(manager.statusMessage)
                        .font(.system(size: 13)).foregroundStyle(Color.stockedGreen).padding(.top, 16)
                }
                if !manager.errorMessage.isEmpty {
                    Text(manager.errorMessage)
                        .font(.system(size: 13)).foregroundStyle(.red).padding(.top, 8)
                }

                Spacer()
            }
            .padding(.horizontal, 28)
        }
        .presentationDetents([.medium, .large])
    }

    private func iCloudActionButton(icon: String, title: String, subtitle: String,
                                    color: Color, isLoading: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd).fill(color).frame(width: 48, height: 48)
                    if isLoading {
                        ProgressView().tint(.white).scaleEffect(0.9)
                    } else {
                        Image(systemName: icon).font(.system(size: 20)).foregroundStyle(.white)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
                }
                Spacer()
            }
            .padding(16)
            .background(session.isDarkMode ? Color.white.opacity(0.08) : Color.stockedWhite.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

// MARK: - Import Mode Sheet
struct ImportModeSheet: View {
    @Environment(AppSession.self) var session
    let onImportFile:  () -> Void
    let onMergeFile:   () -> Void
    let onICloud:      () -> Void
    let onMergeICloud: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                Capsule().fill(Color.stockedCharcoal.opacity(0.18)).frame(width: 40, height: 4)
                    .padding(.top, 12).padding(.bottom, 24)

                Text("Import Kitchen")
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor).padding(.bottom, 8)

                Text("How would you like to import?")
                    .font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.6))
                    .padding(.bottom, 28)

                VStack(spacing: 12) {
                    importModeButton(icon: "doc.fill", title: "Import File (Replace)",
                                     subtitle: "Load a .stocked file — replaces current kitchen",
                                     color: Color.stockedGold) {
                        dismiss()
                        Task {
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            onImportFile()
                        }
                    }
                    importModeButton(icon: "doc.badge.plus", title: "Merge File",
                                     subtitle: "Adds new items from file without removing existing ones",
                                     color: Color.stockedSuccess) {
                        dismiss()
                        Task {
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            onMergeFile()
                        }
                    }
                    importModeButton(icon: "icloud.and.arrow.down.fill", title: "Restore from iCloud",
                                     subtitle: "Replace kitchen with your latest iCloud backup",
                                     color: Color.stockedInfo) {
                        dismiss(); onICloud()
                    }
                    importModeButton(icon: "arrow.triangle.merge", title: "Merge from iCloud",
                                     subtitle: "Add iCloud backup items to current kitchen",
                                     color: Color.stockedCharcoal) {
                        dismiss(); onMergeICloud()
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 28)
        }
        .presentationDetents([.large])
    }

    private func importModeButton(icon: String, title: String, subtitle: String,
                                   color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd).fill(color).frame(width: 42, height: 42)
                    Image(systemName: icon).font(.system(size: 17)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(session.themeTextColor)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12))
                    .foregroundStyle(session.themeTextColor.opacity(0.3))
            }
            .padding(14).background(session.isDarkMode ? Color.white.opacity(0.08) : Color.stockedWhite.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FileDocument for .fileExporter
struct StockedDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.stockedKitchen, .json] }
    var data: Data

    init(url: URL?) {
        self.data = (try? Data(contentsOf: url ?? URL(fileURLWithPath: ""))) ?? Data()
    }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Custom UTType for .stocked files
extension UTType {
    nonisolated static var stockedKitchen: UTType {
        UTType(exportedAs: "com.stocked.kitchen", conformingTo: .json)
    }
}

#Preview {
    KitchenTransferView()
        .environment(AppSession())
}

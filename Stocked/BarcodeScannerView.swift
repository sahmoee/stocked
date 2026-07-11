// BarcodeScannerView.swift — Safe barcode scanning. Requests camera permission before showing scanner.
import SwiftUI
import Combine
import AVFoundation
import VisionKit
import Vision

// MARK: - BarcodeScannerView
// One enum → one .sheet(item:) (two stacked .sheet modifiers fire unreliably).
enum BarcodeSheet: Identifiable {
    case confirm, bulkSummary
    var id: Int { self == .confirm ? 0 : 1 }
}

struct BarcodeScannerView: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    // When shown inside MainTabView's overlaySheet, \.dismiss is a no-op; the overlay
    // injects \.stockedDismiss instead. When shown as a real .sheet (Add Item), the
    // reverse is true — so prefer stockedDismiss and fall back to dismiss. (#250)
    @Environment(\.stockedDismiss) var stockedDismiss
    private func close() { if let stockedDismiss { stockedDismiss() } else { dismiss() } }

    var onResult: (String, String) -> Void

    @State private var cameraPermission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var manualBarcode = ""
    @State private var lastScanned   = ""
    @State private var resolvedName  = ""
    @State private var resolvedProduct: OpenFoodProduct? = nil
    @State private var isLooking     = false
    @State private var scanError     = ""
    @State private var activeSheet: BarcodeSheet? = nil
    @State private var zone          = "Fridge"
    @State private var level: Double = 1.0

    // Bulk scan
    @State private var showScanModeAlert  = true    // ask on first open
    @State private var isBulkMode         = false
    @State private var bulkScanned: [String] = []   // names added so far

    let zones = ["Fridge","Freezer","Pantry","Staples"]

    private var scannerSupported: Bool {
        guard #available(iOS 16.0, *) else { return false }
        return DataScannerViewController.isSupported
    }
    private var canShowLive: Bool {
        cameraPermission == .authorized && scannerSupported
    }

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                // Header
                HStack {
                    Button { close() } label: {
                        Image(systemName: "xmark").font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(session.themeTextColor)
                    }
                    Spacer()
                    Text("Scan Barcode")
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Spacer()
                    Color.clear.frame(width: 28)
                }
                .padding(.horizontal, 24).padding(.top, 52).padding(.bottom, 20)

                switch cameraPermission {
                case .authorized:
                    if scannerSupported { livePanel } else { simulatorPanel }
                case .notDetermined:
                    permissionPanel
                case .denied, .restricted:
                    deniedPanel
                @unknown default:
                    simulatorPanel
                }

                divRow
                manualSection
                if !scanError.isEmpty {
                    Text(scanError).font(.system(size: 13)).foregroundStyle(.red).padding(.top, 8)
                }
                if isLooking {
                    HStack(spacing: 8) {
                        ProgressView().tint(Color.stockedCharcoal)
                        Text("Looking up product…").font(.system(size: 13)).foregroundStyle(session.themeTextColor)
                    }.padding(.top, 12)
                }
                // No trailing Spacer: the live camera panel uses maxHeight: .infinity and
                // consumes the slack itself (same approach as the receipt scanner), so the
                // preview is full-size rather than a small box with empty space below.
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .confirm:
                BarcodeConfirmSheet(
                    productName: resolvedName, barcode: lastScanned,
                    product: resolvedProduct,
                    zone: $zone, level: $level, zones: zones
                ) { name, z, lv, sizeStr, expiry, qty, container in
                    var item = LocalInventoryItem(name: name, level: lv, zone: z)
                    item.expirationDate = expiry                    // #12
                    item.brand = resolvedProduct?.brand             // brand from OFF
                    item.quantity = max(1, qty)
                    if !container.isEmpty, container != "item" { item.containerType = container }
                    // #11 — parse a pack size like "500 g" / "12 ct" into amount + unit.
                    if let sizeStr, let parsed = Self.parsePackSize(sizeStr) {
                        item.sizeAmount = parsed.0
                        item.sizeUnit   = parsed.1
                    }
                    session.guestStore.addInventoryItem(item)
                    // Crowd DB — opt-in anonymized report (fire and forget).
                    let ru = item.sizeUnit ?? "", rct = item.containerType, rq = Double(item.quantity)
                    Task { await CrowdDB.report(items: [(name: name, category: z, unit: ru, container: rct, quantity: rq)]) }
                    if isBulkMode {
                        bulkScanned.append(name)
                        activeSheet = nil     // keep scanner open for next item
                        lastScanned = ""      // allow same barcode again
                    } else {
                        onResult(name, lastScanned)
                        close()
                    }
                }
                .environment(session)
            case .bulkSummary:
                BulkScanSummaryView(items: bulkScanned) {
                    onResult(bulkScanned.first ?? "", "")
                    close()
                }
                .environment(session)
            }
        }
        .alert("Scan Mode", isPresented: $showScanModeAlert) {
            Button("Single Item") { isBulkMode = false }
            Button("Bulk Scan")   { isBulkMode = true  }
        } message: {
            Text("Are you scanning one item, or multiple items in a row?\nBulk mode keeps the scanner open after each scan.")
        }
        .overlay(alignment: .bottom) {
            if isBulkMode && !bulkScanned.isEmpty {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(bulkScanned.count) item\(bulkScanned.count == 1 ? "" : "s") scanned")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(Color.stockedWhite)
                        Text(bulkScanned.last ?? "")
                            .font(.system(size: 11)).foregroundStyle(Color.stockedWhite.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("Done") { activeSheet = .bulkSummary }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.stockedGold)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(Color.stockedCharcoal)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20).padding(.bottom, 40)
            }
        }
    }

    // MARK: Live scanner panel
    private var livePanel: some View {
        Group {
            if #available(iOS 16.0, *) {
                // Fill the available space like the receipt scanner (which uses
                // maxHeight: .infinity) so the live camera is full-size, not a small
                // 280pt box. The hint sits as an overlay at the bottom.
                SafeBarcodeScannerView { code in
                    guard code != lastScanned else { return }
                    lastScanned = code
                    resolveBarcode(code)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(alignment: .bottom) {
                    Text("Point camera at any barcode or QR code")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(.bottom, 16)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
    }

    // Permission request panel
    private var permissionPanel: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Color.stockedCharcoal).frame(height: 200)
                VStack(spacing: 14) {
                    Image(systemName: "camera.fill").font(.system(size: 44)).foregroundStyle(Color.stockedGold)
                    Text("Camera Access Needed")
                        .font(.system(size: 16, weight: .semibold, design: .serif)).foregroundStyle(Color.stockedWhite)
                    Text("To scan barcodes, allow camera access.")
                        .font(.system(size: 13)).foregroundStyle(Color.stockedWhite.opacity(0.6))
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                }
            }
            .padding(.horizontal, 20)
            Button {
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    Task { @MainActor in
                        cameraPermission = granted ? .authorized : .denied
                    }
                }
            } label: {
                Text("Allow Camera Access")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color.stockedCharcoal).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
            }
            .padding(.horizontal, 24)
        }
    }

    // Denied panel
    private var deniedPanel: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Color.stockedCharcoal).frame(height: 160)
                VStack(spacing: 10) {
                    Image(systemName: "camera.fill").font(.system(size: 36)).foregroundStyle(.red.opacity(0.7))
                    Text("Camera Access Denied")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.stockedWhite)
                    Text("Enable in Settings → Privacy → Camera")
                        .font(.system(size: 12)).foregroundStyle(Color.stockedWhite.opacity(0.6))
                }
            }
            .padding(.horizontal, 20)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.stockedGold)
            }
        }
    }

    // Simulator fallback
    private var simulatorPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(Color.stockedCharcoal).frame(height: 200)
            VStack(spacing: 12) {
                Image(systemName: "barcode.viewfinder").font(.system(size: 46)).foregroundStyle(Color.stockedGold)
                Text("Camera unavailable").font(.system(size: 14, design: .serif)).foregroundStyle(Color.stockedWhite.opacity(0.7))
            }
        }
        .padding(.horizontal, 20)
    }

    private var divRow: some View {
        HStack {
            Rectangle().fill(Color.stockedCharcoal.opacity(0.12)).frame(height: 1)
            Text("or enter manually").font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.4)).fixedSize()
            Rectangle().fill(Color.stockedCharcoal.opacity(0.12)).frame(height: 1)
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var manualSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "barcode").foregroundStyle(session.themeTextColor.opacity(0.35))
                TextField("Enter barcode number", text: $manualBarcode)
                    .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal).keyboardType(.numberPad)
            }
            .padding(12).background(Color.stockedWhite.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)).padding(.horizontal, 24)

            Button {
                guard !manualBarcode.isEmpty else { return }
                resolveBarcode(manualBarcode)
            } label: {
                Text("Look Up")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(manualBarcode.isEmpty ? Color.stockedCharcoal.opacity(0.4) : Color.stockedCharcoal)
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
            }
            .disabled(manualBarcode.isEmpty).padding(.horizontal, 24)
        }
    }

    // MARK: Product resolution — powered by Open Food Facts
    // Formats OFF product names: title-cases ALL CAPS, prepends brand
    private func formatProductTitle(_ rawName: String, brand: String) -> String {
        var name = rawName.trimmingCharacters(in: .whitespaces)
        // Detect all-caps (>60% uppercase alpha chars)
        let alphas = name.filter { $0.isLetter }
        let uppers = alphas.filter { $0.isUppercase }
        if alphas.count > 2 && Double(uppers.count) / Double(alphas.count) > 0.6 {
            name = name.lowercased()
                .components(separatedBy: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
        // Strip parenthetical weight/count suffixes e.g. "(NET WT 12 OZ)"
        if let range = name.range(of: #" ?\([^)]*\d[^)]*\)"#, options: .regularExpression) {
            name = String(name[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        // Prepend brand if not already in name
        if !brand.isEmpty {
            let primary = (brand.components(separatedBy: ",").first ?? brand)
                .trimmingCharacters(in: .whitespaces)
            let brandTitled = primary.lowercased()
                .components(separatedBy: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
            if !name.lowercased().contains(primary.lowercased()) {
                name = "\(brandTitled) \(name)"
            }
        }
        return name
    }

    // 5-second per-source timeout — prevents a slow source blocking the whole chain
    private func withTimeout<T: Sendable>(_ seconds: Double, work: @escaping @Sendable () async throws -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result ?? nil
        }
    }

    private func resolveBarcode(_ code: String) {
        isLooking = true; scanError = ""
        Task { @MainActor in
            // #9 — check the local cache first (instant + offline).
            if let cached = BarcodeCache.shared.lookup(code) {
                resolvedName    = cached
                resolvedProduct = nil
                zone = ReceiptDatabase.shared.guessZone(for: cached)
                isLooking = false; activeSheet = .confirm; return
            }
            // Waterfall — each source capped at 5 seconds
            let product = await withTimeout(5) { await OpenFoodFactsClient.shared.lookup(barcode: code) }
            if let p = product, !p.name.isEmpty {
                resolvedName    = formatProductTitle(p.name, brand: p.brand)
                // If this household previously corrected this product's name, honor that.
                resolvedName    = UserCorrections.shared.apply(.productName, to: resolvedName)
                resolvedProduct = p
                zone = ReceiptDatabase.shared.guessZone(for: resolvedName)  // smart default
                BarcodeCache.shared.save(code, name: resolvedName)         // #9 cache
                isLooking = false; activeSheet = .confirm; return
            }
            // Fallback 2 — UPC Item DB (5s cap)
            if let upcName = await withTimeout(5, work: { await self.lookupUPCItemDB(code) }) {
                resolvedName = upcName; resolvedProduct = nil
                zone = ReceiptDatabase.shared.guessZone(for: upcName)       // smart default
                BarcodeCache.shared.save(code, name: upcName)              // #9 cache
                isLooking = false; activeSheet = .confirm; return
            }
            // #10 — AI fallback: ask the Worker to identify the product from the barcode.
            if let aiName = await withTimeout(8, work: { await self.lookupViaAI(code) }) {
                resolvedName = aiName; resolvedProduct = nil
                zone = ReceiptDatabase.shared.guessZone(for: aiName)
                BarcodeCache.shared.save(code, name: aiName)
                isLooking = false; activeSheet = .confirm; return
            }
            // Fallback — manual entry
            fallback(code)
        }
    }

    /// #10 — last-resort product guess from a barcode via the Worker (Claude).
    private func lookupViaAI(_ code: String) async -> String? {
        guard ConnectivityMonitor.isOnlineFlag else { return nil }   // #19 skip network when offline
        let s = BuildConfig.receiptWorkerURL
        guard !s.contains("REPLACE-WITH-YOUR-WORKER"),
              let url = URL(string: s),
              let body = try? JSONSerialization.data(withJSONObject: ["barcode": code]) else { return nil }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        BuildConfig.authorizeWorkerRequest(&req)   // X-Stocked-Key shared secret
        req.httpBody = body; req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else { return nil }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Guard against the model saying it doesn't know.
        if name.isEmpty || name.count > 60 || name.lowercased().contains("unknown")
            || name.lowercased().contains("cannot") || name.lowercased().contains("don't") { return nil }
        return name
    }

    private func lookupUPCItemDB(_ upc: String) async -> String? {
        guard let url = URL(string: "https://api.upcitemdb.com/prod/trial/lookup?upc=\(upc)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]],
              let first = items.first,
              let title = first["title"] as? String, !title.isEmpty
        else { return nil }
        return title
    }
    private func fallback(_ code: String) {
        isLooking = false
        resolvedProduct = nil
        resolvedName = code.isEmpty ? "Unknown Item" : "Item #\(code)"
        activeSheet = .confirm
    }

    /// #11 — parse an Open Food Facts pack size like "500 g", "1.5 L", "12 ct",
    /// "6 x 330 ml" into (amount, unit). Returns nil if it can't find a number+unit.
    static func parsePackSize(_ raw: String) -> (Double, String)? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        // Handle "6 x 330 ml" → 6 * 330 = 1980 ml
        let multi = s.replacingOccurrences(of: "×", with: "x")
        if let xRange = multi.range(of: "x") {
            let lhs = multi[..<xRange.lowerBound].trimmingCharacters(in: .whitespaces)
            let rhs = multi[xRange.upperBound...].trimmingCharacters(in: .whitespaces)
            if let count = Double(lhs), let (amt, unit) = parseSingleSize(rhs) {
                return (count * amt, unit)
            }
        }
        return parseSingleSize(s)
    }

    private static func parseSingleSize(_ s: String) -> (Double, String)? {
        var num = ""
        var idx = s.startIndex
        while idx < s.endIndex, s[idx].isNumber || s[idx] == "." {
            num.append(s[idx]); idx = s.index(after: idx)
        }
        guard let amount = Double(num) else { return nil }
        let unit = s[idx...].trimmingCharacters(in: .whitespaces)
        let known = ["g","kg","mg","ml","l","oz","lb","ct","count","pk","pack","fl oz","floz"]
        let cleaned = unit.isEmpty ? "ct" : unit
        let match = known.first { cleaned.hasPrefix($0) } ?? cleaned
        return (amount, match)
    }
}

// MARK: - Confirm Sheet
struct BarcodeConfirmSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    @State var productName: String
    let barcode: String
    var product: OpenFoodProduct? = nil
    @Binding var zone:  String
    @Binding var level: Double
    let zones: [String]
    // name, zone, level, packSize, expiry, quantity, container
    let onAdd: (String, String, Double, String?, Date?, Int, String) -> Void
    @State private var scannedExpiry: Date? = nil   // #12
    @State private var showExpiryScanner = false
    // #9 quantity + container carried through the scan (natural-language editable).
    @State private var scanQuantity: Int = 1
    @State private var scanContainer: String = ""
    @State private var deducted = false

    // #9 barcode re-scan to deduct: the matching item already in the pantry, if any.
    private var existingItem: LocalInventoryItem? {
        let n = productName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !n.isEmpty else { return nil }
        return session.guestStore.inventoryItems.first {
            let e = $0.name.lowercased()
            return e == n || e.contains(n) || n.contains(e)
        }
    }

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                Capsule().fill(Color.stockedCharcoal.opacity(0.2)).frame(width: 40, height: 4).padding(.top, 12).padding(.bottom, 22)
                Text("Found Item").font(.system(size: 22, weight: .bold, design: .serif)).foregroundStyle(session.themeTextColor).padding(.bottom, 4)
                if !barcode.isEmpty {
                    Text(barcode).font(.system(size: 10, design: .monospaced)).foregroundStyle(session.themeTextColor.opacity(0.35)).padding(.bottom, 8)
                }
                // Brand + enrichment data from Open Food Facts
                if let p = product {
                    VStack(spacing: 6) {
                        if !p.brand.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "building.2").font(.system(size: 11)).foregroundStyle(Color.stockedGold)
                                Text(p.brand).font(.system(size: 12, weight: .semibold)).foregroundStyle(session.themeTextColor.opacity(0.7))
                                Spacer()
                                if let qty = p.quantity {
                                    Text(qty).font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.4))
                                }
                            }
                        }
                        if !p.allergens.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                    Text("Allergen Warning")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                                Text(p.allergens.map { $0.replacingOccurrences(of: "en:", with: "").capitalized }.prefix(6).joined(separator: ", "))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(Color.orange)
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        }
                        if let grade = p.nutriScore {
                            HStack(spacing: 6) {
                                Text("Nutri-Score").font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.5))
                                Text(grade)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color.stockedWhite)
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .background(nutriScoreColor(grade))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 14)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Product Name").font(.system(size: 11, weight: .semibold)).foregroundStyle(session.themeTextColor.opacity(0.45))
                    FoodPredictiveTextField(placeholder: "Name", text: $productName)
                        .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                        .font(.system(size: 15))
                        .padding(12).background(Color.stockedWhite.opacity(0.45)).clipShape(RoundedRectangle(cornerRadius: 11))
                }.padding(.horizontal, 24).padding(.bottom, 20)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Storage Zone").font(.system(size: 11, weight: .semibold)).foregroundStyle(session.themeTextColor.opacity(0.45))
                    Picker("Zone", selection: $zone) { ForEach(zones, id: \.self) { Text($0) } }.pickerStyle(.segmented)
                }.padding(.horizontal, 24).padding(.bottom, 20)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Starting Amount").font(.system(size: 11, weight: .semibold)).foregroundStyle(session.themeTextColor.opacity(0.45))
                        Spacer()
                        Text("\(Int(level*100))%").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.stockedGold)
                    }
                    Slider(value: $level, in: 0.1...1.0, step: 0.1).tint(Color.stockedCharcoal)
                }.padding(.horizontal, 24).padding(.bottom, 14)
                    .padding(.bottom, 10)

                // Quantity — type it naturally ("6 cans of 8 oz") or leave as 1.
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Quantity").font(.system(size: 11, weight: .semibold)).foregroundStyle(session.themeTextColor.opacity(0.45))
                        Spacer()
                        Stepper("", value: $scanQuantity, in: 1...999).labelsHidden()
                        Text("\(scanQuantity)\(scanContainer.isEmpty ? "" : " \(scanContainer)")")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(Color.stockedGold)
                    }
                    NaturalQuantityField(placeholder: "e.g. 6 cans of 8 oz") { parsed in
                        scanQuantity = max(1, Int(parsed.count.rounded()))
                        if parsed.container != "item" { scanContainer = parsed.container }
                    }
                }.padding(.horizontal, 24).padding(.bottom, 14)

                // #9 — re-scan to deduct: this product is already in the pantry; one tap
                // marks one used (drops quantity, removing when the last one is used).
                if let existing = existingItem {
                    Button {
                        guard !deducted else { return }
                        if let i = session.guestStore.inventoryItems.firstIndex(where: { $0.id == existing.id }) {
                            if session.guestStore.inventoryItems[i].quantity > 1 {
                                session.guestStore.inventoryItems[i].quantity -= 1
                            } else {
                                session.guestStore.inventoryItems[i].level = 0
                            }
                            deducted = true
                            HapticManager.success()
                            ToastCenter.shared.success("Used 1 \(existing.name)")
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "minus.circle.fill")
                            Text("Already have \(existing.quantity) — mark 1 used")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.stockedGold)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.stockedGold.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24).padding(.bottom, 12)
                }

                // #12 — scan the printed best-by / expiry date.
                Button { showExpiryScanner = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar.badge.clock")
                        Text(scannedExpiry == nil
                             ? "Scan expiry date (optional)"
                             : "Expires \(Self.shortDate.string(from: scannedExpiry!))")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(scannedExpiry == nil ? session.themeTextColor.opacity(0.6) : Color.stockedGold)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24).padding(.bottom, 16)

                Button {
                    let n = productName.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }
                    // If the user edited the name the source suggested, remember the correction so
                    // the same product resolves to their name next time.
                    if let original = product?.name, !original.isEmpty,
                       n.caseInsensitiveCompare(original) != .orderedSame {
                        UserCorrections.shared.record(.productName, original: original, corrected: n)
                        AppAnalytics.shared.log(.dataCorrected)
                    }
                    // #11 — carry the OFF pack size (e.g. "500 g") through as the size string.
                    onAdd(n, zone, level, product?.quantity, scannedExpiry, scanQuantity, scanContainer)
                } label: {
                    Text("Add to \(zone)").font(.system(size: 16, weight: .semibold, design: .serif)).foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 15).background(Color.stockedCharcoal).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                }.padding(.horizontal, 24)
                Spacer()
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.hidden)
        .sheet(isPresented: $showExpiryScanner) {
            ExpiryDateScanner { date in
                scannedExpiry = date
                showExpiryScanner = false
            }
        }
    }
    static let shortDate: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; return f
    }()
    private func nutriScoreColor(_ grade: String) -> Color {
        switch grade.uppercased() {
        case "A": return Color.stockedSuccess
        case "B": return Color.stockedWarning
        case "C": return Color.stockedWarning
        case "D": return Color.stockedWarning
        default:   return Color.red
        }
    }
}

// MARK: - Safe Live Barcode Scanner (iOS 16+)
// Wrapped in a separate struct so @available only applies here, avoiding crashes on older iOS.
@available(iOS 16.0, *)
struct SafeBarcodeScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        // Start scanning safely
        Task {
            try? await Task.sleep(nanoseconds: 100000000)
            try? vc.startScanning()
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    // Stop scanning when view disappears — prevents camera staying open + memory leak
    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
        uiViewController.delegate = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var lastCode = ""; private var lastTime = Date.distantPast
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard let item = addedItems.first,
                  case .barcode(let bc) = item,
                  let value = bc.payloadStringValue, !value.isEmpty else { return }
            let now = Date()
            guard value != lastCode || now.timeIntervalSince(lastTime) > 2 else { return }
            lastCode = value; lastTime = now
            Task { @MainActor in self.onCode(value) }
        }
    }
}


// MARK: - Bulk Scan Summary
struct BulkScanSummaryView: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    let items: [String]
    let onDone: () -> Void

    var body: some View {
        StockedSheet(title: "Scan Complete") {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                VStack(spacing: 0) {
                    Text("\(items.count) items added to pantry")
                        .font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                        .padding(.top, 8).padding(.bottom, 16)

                    List {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, name in
                            HStack(spacing: 12) {
                                Text("\(i + 1)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.stockedGold)
                                    .frame(width: 24)
                                Text(name)
                                    .font(.system(size: 15, design: .serif))
                                    .foregroundStyle(session.themeTextColor)
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.stockedGold)
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)

                    Button {
                        onDone()
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(.system(size: 16, weight: .semibold, design: .serif))
                            .foregroundStyle(Color.stockedWhite)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(Color.stockedCharcoal).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                    }
                    .padding(.horizontal, 24).padding(.bottom, 32)
                }
            }
            .navigationTitle("Bulk Scan Complete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { onDone(); dismiss() }
                        .foregroundStyle(Color.stockedGold)
                }
            }
        }
    }
}

#Preview { BarcodeScannerView { _, _ in }.environment(AppSession()) }

// MARK: - Expiry Date Scanner (#12)
// Live-text scanner that reads a printed best-by / expiry date and parses it.
struct ExpiryDateScanner: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    var onDate: (Date) -> Void
    @State private var status = "Point at the printed date"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if #available(iOS 16.0, *) {
                LiveTextScannerPanel(onCapture: { text in
                    if let d = Self.parseDate(from: text) {
                        onDate(d)
                    } else {
                        status = "Couldn't read a date — try again"
                    }
                })
                .ignoresSafeArea()
            } else {
                Text("Date scanning needs iOS 16+").foregroundStyle(.white)
            }
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28)).foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                }.padding()
                Spacer()
                Text(status)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.55))
                    .clipShape(Capsule())
                Button {
                    NotificationCenter.default.post(name: .captureReceiptShutter, object: nil)
                } label: {
                    Text("Capture Date")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 28).padding(.vertical, 14)
                        .background(.white).clipShape(Capsule())
                }.padding(.bottom, 36)
            }
        }
    }

    /// Parse common printed date formats from OCR text. Tries several patterns and
    /// picks the first plausible future-ish date.
    static func parseDate(from text: String) -> Date? {
        let cal = Calendar.current
        let now = Date()
        // Use a data detector first (handles many natural formats).
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = detector.matches(in: text, options: [], range: range)
            let dates = matches.compactMap { $0.date }
            // Prefer a date within a sane window (not far past, not absurdly far future).
            if let best = dates.first(where: { $0 > cal.date(byAdding: .day, value: -2, to: now)! &&
                                               $0 < cal.date(byAdding: .year, value: 6, to: now)! }) {
                return best
            }
            if let any = dates.first { return any }
        }
        // Explicit numeric patterns: MM/DD/YY, MM-DD-YYYY, DD.MM.YYYY, YYYY-MM-DD
        let patterns = ["MM/dd/yyyy","MM/dd/yy","MM-dd-yyyy","dd.MM.yyyy","yyyy-MM-dd","MMM dd yyyy","dd MMM yyyy"]
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        // Pull date-like tokens out of the OCR text.
        let tokens = text.components(separatedBy: CharacterSet(charactersIn: " \n\t"))
        for token in tokens {
            let t = token.trimmingCharacters(in: .punctuationCharacters).trimmingCharacters(in: .whitespaces)
            guard t.count >= 5 else { continue }
            for p in patterns {
                df.dateFormat = p
                if let d = df.date(from: t) { return d }
            }
        }
        return nil
    }
}

// MARK: - Barcode lookup cache (#9)
final class BarcodeCache {
    static let shared = BarcodeCache()
    private let key = "barcodeCache_v1"
    private var map: [String: String]
    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            map = decoded
        } else { map = [:] }
    }
    func lookup(_ code: String) -> String? {
        let k = code.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return nil }
        return map[k]
    }
    func save(_ code: String, name: String) {
        let k = code.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty, !name.isEmpty else { return }
        map[k] = name
        // Cap to most-recent ~2000 entries to bound storage.
        if map.count > 2000 { map.removeAll() ; map[k] = name }
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

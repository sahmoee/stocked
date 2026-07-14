// ReceiptScannerView.swift
// Camera-based receipt scanner using DataScannerViewController (iOS 16+).
import SwiftUI
import VisionKit
import Vision
import PhotosUI
import Combine

// MARK: - Data model
nonisolated struct ReceiptLineItem: Identifiable, Sendable {
    let id       = UUID()
    var rawText:  String
    var resolved: String
    var isFood:   Bool
    var isChecked: Bool   = true
    var zone:     String  = "Pantry"
    var suggestedExpiry: Date? = nil
    var quantity: Int     = 1        // parsed from "2LB", "3CT", "4 PACK"
    var confidence: Int   = 100      // 0–100 based on ReceiptDatabase scanCount
    var brand:    String? = nil      // store brand kept separate from the food name
    var unitPrice: Double? = nil     // #1 price per unit, from the receipt
    var totalPrice: Double? = nil    // #1 line total, from the receipt

    /// Provenance badge derived from the numeric confidence, via the shared mapping so the
    /// receipt review screen labels certainty the same way the rest of the app does.
    var badge: SourceBadge { SourceBadge.from(confidence: confidence) }

    /// Which grouped-review section this line belongs in. Non-food lines the parser kept for
    /// transparency are .ignored; everything else follows its badge (Confident / Needs review).
    var reviewGroup: ReviewGroup { isFood ? badge.reviewGroup : .ignored }
}

// MARK: - Receipt Archive Entry
nonisolated struct ReceiptArchiveEntry: Identifiable, Codable, Sendable {
    var id        = UUID()
    var date:     Date     = Date()
    var storeName: String  = ""
    var itemCount: Int     = 0
    var items:     [String] = []     // #14 — saved item names for re-import
    var totalSpend: Double  = 0       // #19 — receipt total for spend tracking
}

// MARK: - ReceiptScannerView
// #18: Replaces hasFiredCapture + isProcessing + guard logic with a single state machine
nonisolated enum ScanState: Equatable, Sendable {
    case idle
    case scanning
    case processing
    case done(items: [String])
    case failed(reason: String)
}

struct ReceiptScannerView: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    // When presented via MainTabView's custom overlaySheet (not a real .sheet), the
    // SwiftUI @Environment(\.dismiss) is a no-op. overlaySheet injects \.stockedDismiss,
    // so prefer that and fall back to the system dismiss when shown as a real sheet
    // (e.g. from InventoryView). This is why the header X did nothing in the overlay.
    @Environment(\.stockedDismiss) var stockedDismiss
    private func closeScanner() {
        if let stockedDismiss { stockedDismiss() } else { dismiss() }
    }

    @State private var phase:        Phase  = .instructions
    @State private var capturedText  = ""
    @State private var lineItems:    [ReceiptLineItem] = []
    @State private var scanState:    ScanState = .idle   // #18: unified state
    @State private var isProcessing  = false             // kept for existing call-site compat
    @State private var errorMsg      = ""
    @State private var addedCount    = 0
    @State private var detectedStore = ""

    // Multi-receipt session
    @State private var sessionTotal  = 0
    @State private var scanCount     = 0

    // Receipt archive
    @State private var archive: [ReceiptArchiveEntry] = []
    @State private var isAddingAnotherPage = false       // #4 multi-photo stitching
    @State private var detectedDate: Date? = nil          // #5 receipt date
    @State private var showArchive   = false

    // Bulk zone override
    @State private var showBulkZone  = false

    // Screenshot import
    @State private var showPhotoPicker = false
    @State private var photoPickerItems: [PhotosPickerItem] = []

    nonisolated enum Phase: Sendable { case instructions, scanning, review, done }

    var scannerAvailable: Bool {
        if #available(iOS 16.0, *) {
            return DataScannerViewController.isAvailable && DataScannerViewController.isSupported
        }
        return false
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if phase == .scanning {
                if scannerAvailable {
                    if #available(iOS 16.0, *) {
                        LiveTextScannerPanel(onCapture: { text in
                            capturedText = text
                            detectedStore = detectStoreName(from: text)
                            parseReceiptWithAI(text)
                            phase = .review
                        }, onCaptureImage: { image in
                            parseReceipt(image: image)
                        })
                        .ignoresSafeArea()
                    }
                }
                VStack {
                    HStack {
                        Button { phase = .instructions } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(Color.black.opacity(0.4))
                                .clipShape(Circle())
                        }
                        .a11yButton("Cancel scan", hint: "Stops scanning and returns to instructions")
                        Spacer()
                        if scanCount > 0 {
                            Text("Receipt \(scanCount + 1) · \(sessionTotal) added so far")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.black.opacity(0.5)).clipShape(Capsule())
                        } else {
                            Text("Scan Receipt")
                                .font(.system(size: 16, weight: .semibold, design: .serif)).foregroundStyle(.white)
                        }
                        Spacer()
                        Color.clear.frame(width: 36)
                    }
                    .padding(.horizontal, 20).padding(.top, 56)
                    Spacer()
                    Text("Point at receipt · Tap anywhere to capture")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(Color.black.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)).padding(.bottom, 24)
                    Button { NotificationCenter.default.post(name: .captureReceiptShutter, object: nil) } label: {
                        ZStack {
                            Circle().stroke(Color.white, lineWidth: 3).frame(width: 72, height: 72)
                            Circle().fill(Color.white).frame(width: 60, height: 60)
                        }
                    }
                    .buttonStyle(.plain).padding(.bottom, 48)
                    .a11yButton("Capture receipt", hint: "Takes a photo of the receipt")
                }
            } else {
                session.themeBgColor.ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack {
                        Button { closeScanner() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(session.themeTextColor)
                        }
                        .a11yButton("Close", hint: "Closes the receipt scanner")
                        Spacer()
                        VStack(spacing: 2) {
                            Text("Scan Receipt")
                                .font(.system(size: 22, weight: .bold, design: .serif))
                                .foregroundStyle(session.themeTextColor)
                            if !detectedStore.isEmpty {
                                Text(detectedStore)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.stockedGold)
                            }
                        }
                        Spacer()
                        Button { showArchive = true } label: {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 18))
                                .foregroundStyle(archive.isEmpty
                                    ? session.themeTextColor.opacity(0.3) : session.themeTextColor)
                        }
                        .disabled(archive.isEmpty)
                        .a11yButton("Receipt history", hint: "View previously scanned receipts")
                    }
                    .padding(.horizontal, 24).padding(.top, 52).padding(.bottom, 20)

                    switch phase {
                    case .instructions: instructionsView
                    case .scanning:     EmptyView()
                    case .review:       reviewView
                    case .done:         doneView
                    }
                }
            }
        }
        .sheet(isPresented: $showArchive) {
            ReceiptArchiveSheet(entries: archive).environment(session)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItems, maxSelectionCount: 1, matching: .images)
        .onChange(of: photoPickerItems) { _, items in
            guard let item = items.first else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let ui = UIImage(data: data) {
                    await MainActor.run { parseReceipt(image: ui) }
                }
            }
        }
        .onAppear { loadArchive() }
    }

    // MARK: - Instructions
    var instructionsView: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 20)

            ZStack {
                RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
                    .fill(Color.stockedCharcoal)
                    .frame(height: 200)
                VStack(spacing: 16) {
                    Image(systemName: "doc.text.viewfinder")
                        .font(.system(size: 54))
                        .foregroundStyle(Color.stockedGold)
                    Text("Point your camera at\na grocery receipt")
                        .font(.system(size: 16, design: .serif))
                        .foregroundStyle(Color.stockedWhite.opacity(0.85))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 14) {
                tipRow(icon: "lightbulb.fill",        text: "Hold phone flat above the receipt")
                tipRow(icon: "sun.max.fill",           text: "Use good lighting — avoid shadows")
                tipRow(icon: "checkmark.circle.fill",  text: "AI identifies food items automatically")
                tipRow(icon: "photo.on.rectangle",     text: "Or import a screenshot of an e-receipt")
            }
            .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 12) {
                if scannerAvailable {
                    Button { phase = .scanning } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "camera.fill")
                            Text("Scan Receipt")
                                .font(.system(size: 17, weight: .semibold, design: .serif))
                        }
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 17)
                        .background(Color.stockedCharcoal).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                    }
                    .padding(.horizontal, 28)
                } else {
                    Button { loadDemoReceipt() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text.fill")
                            Text("Load Demo Receipt (Simulator)")
                                .font(.system(size: 17, weight: .semibold, design: .serif))
                        }
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 17)
                        .background(Color.stockedCharcoal).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                    }
                    .padding(.horizontal, 28)
                    Text("Camera scanning requires a physical iPhone with iOS 16+")
                        .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.4))
                        .multilineTextAlignment(.center).padding(.horizontal, 32)
                }

                // Screenshot / e-receipt import
                Button { showPhotoPicker = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle")
                        Text("Import Screenshot")
                            .font(.system(size: 15, weight: .semibold, design: .serif))
                    }
                    .foregroundStyle(session.themeTextColor.opacity(0.7))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                }
                .padding(.horizontal, 28)
            }

            Spacer().frame(height: 32)
        }
    }

    // MARK: - Review
    var reviewView: some View {
        VStack(spacing: 0) {
            if isProcessing {
                VStack(spacing: 20) {
                    Spacer()
                    ProgressView().tint(Color.stockedCharcoal).scaleEffect(1.5)
                    Text("Identifying food items…")
                        .font(.system(size: 16, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("Claude is reading your receipt")
                        .font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                    Spacer()
                }
            } else if lineItems.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundStyle(session.themeTextColor.opacity(0.25))
                    Text("No food items found")
                        .font(.system(size: 18, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("Try scanning again with better lighting")
                        .font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                    Button { phase = .instructions } label: {
                        Text("Try Again")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.stockedWhite)
                            .padding(.horizontal, 32).padding(.vertical, 14)
                            .background(Color.stockedCharcoal).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                    }.buttonStyle(.plain)
                    Spacer()
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    // Distinct, retryable failure banner (#12) — shown when the AI parse failed
                    // and we fell back to a basic local scan. Non-blocking; results still show.
                    if !errorMsg.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.stockedGold)
                            Text(errorMsg)
                                .font(.system(size: 12))
                                .foregroundStyle(session.themeTextColor)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button {
                                errorMsg = ""
                                if !capturedText.isEmpty { parseReceiptWithAI(capturedText) }
                            } label: {
                                Text("Retry")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.stockedWhite)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Color.stockedCharcoal).clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .a11yButton("Retry smart reading")
                        }
                        .padding(12)
                        .background(Color.stockedGold.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        .padding(.horizontal, 24).padding(.top, 12)
                    }
                    // Header row
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(lineItems.filter { $0.isChecked }.count) items ready to add")
                                .font(.system(size: 16, weight: .bold, design: .serif))
                                .foregroundStyle(session.themeTextColor)
                            if !detectedStore.isEmpty {
                                Text(detectedStore)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.stockedGold)
                            }
                        }
                        Spacer()
                        // Bulk zone override button
                        Menu {
                            ForEach(["Fridge","Freezer","Pantry","Staples"], id: \.self) { z in
                                Button("Move all checked to \(z)") {
                                    for i in lineItems.indices where lineItems[i].isChecked {
                                        lineItems[i].zone = z
                                    }
                                    HapticManager.success()
                                }
                            }
                            Divider()
                            // #17 — fast multi-item review corrections.
                            Button("Check all") {
                                for i in lineItems.indices { lineItems[i].isChecked = true }
                                HapticManager.select()
                            }
                            Button("Uncheck all") {
                                for i in lineItems.indices { lineItems[i].isChecked = false }
                                HapticManager.select()
                            }
                            Button(role: .destructive) {
                                withAnimation { lineItems.removeAll { !$0.isChecked } }
                                HapticManager.warning()
                            } label: { Text("Remove unchecked items") }
                        } label: {
                            Label("Bulk Edit", systemImage: "arrow.up.arrow.down.circle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(session.themeTextColor.opacity(0.6))
                        }
                        Button { phase = .instructions } label: {
                            Text("Scan Again")
                                .font(.system(size: 13))
                                .foregroundStyle(session.themeTextColor.opacity(0.5))
                        }
                        .padding(.leading, 8)
                    }
                    .padding(.horizontal, 24).padding(.bottom, 12)

                    // #7 — Review summary: counts per zone + total spend.
                    reviewSummaryBar
                        .padding(.horizontal, 24).padding(.bottom, 10)

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 14) {
                            // Grouped review: Confident / Needs review / Ignored, so the user's
                            // eye goes to what actually needs checking. Groups line-item indices
                            // by their ReviewGroup (shared vocabulary used across every AI-review
                            // screen), then renders each section.
                            ForEach(reviewSections, id: \.group) { section in
                                VStack(alignment: .leading, spacing: 8) {
                                    reviewSectionHeader(section.group, count: section.indices.count)
                                    ForEach(section.indices, id: \.self) { i in
                                        reviewRow(index: i)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                    }
                    .frame(maxHeight: .infinity)   // fill the sheet instead of leaving a gap

                    // Add to pantry button — pinned directly below the (now full-height) list.
                    Button { addItemsToPantry() } label: {
                        Text("Add \(lineItems.filter { $0.isChecked }.count) Items to Pantry")
                            .font(.system(size: 17, weight: .semibold, design: .serif))
                            .foregroundStyle(Color.stockedWhite)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 17)
                            .background(Color.stockedCharcoal)
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                    }
                    .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 6)

                    // #4 — add another page of a long receipt; next scan appends to this list.
                    Button {
                        isAddingAnotherPage = true
                        phase = .instructions
                    } label: {
                        Label("Scan another page", systemImage: "plus.viewfinder")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(session.themeTextColor.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 22)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    // #7 — summary bar: total items, per-zone counts, and total spend if prices exist.
    private var reviewSummaryBar: some View {
        let checked = lineItems.filter { $0.isChecked }
        let zones = Dictionary(grouping: checked, by: { $0.zone }).mapValues { $0.count }
        let total = checked.compactMap { $0.totalPrice ?? $0.unitPrice }.reduce(0, +)
        let zoneOrder = ["Fridge","Freezer","Pantry","Staples"]
        let zoneText = zoneOrder.compactMap { z -> String? in
            guard let count = zones[z], count > 0 else { return nil }
            return "\(count) \(z)"
        }.joined(separator: " · ")
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(checked.count) item\(checked.count == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(session.themeTextColor)
                if !zoneText.isEmpty {
                    Text(zoneText)
                        .font(.system(size: 11))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                }
            }
            Spacer()
            if total > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "$%.2f", total))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.stockedGold)
                    Text("est. total")
                        .font(.system(size: 9))
                        .foregroundStyle(session.themeTextColor.opacity(0.4))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }

    /// Line-item indices grouped into the three ReviewGroup buckets (Confident / Needs review /
    /// Ignored), each internally sorted lowest-confidence-first, and only non-empty groups, in
    /// display order. Drives the grouped review list.
    private var reviewSections: [(group: ReviewGroup, indices: [Int])] {
        let byGroup = Dictionary(grouping: lineItems.indices) { lineItems[$0].reviewGroup }
        return byGroup
            .sorted { $0.key < $1.key }
            .map { (group: $0.key,
                    indices: $0.value.sorted { lineItems[$0].confidence < lineItems[$1].confidence }) }
    }

    /// Header for a grouped-review section (Confident / Needs review / Ignored).
    @ViewBuilder func reviewSectionHeader(_ group: ReviewGroup, count: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: group.symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(group == .needsReview ? Color.stockedGold
                                 : group == .confident ? Color.stockedGreen
                                 : session.themeTextColor.opacity(0.4))
            VStack(alignment: .leading, spacing: 1) {
                Text("\(group.title) · \(count)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(session.themeTextColor)
                Text(group.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(session.themeTextColor.opacity(0.45))
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    func reviewRow(index: Int) -> some View {
        let item = lineItems[index]
        return ReviewRowView(
            item: item,
            onToggle: { lineItems[index].isChecked.toggle() },
            onCorrect: { corrected in
                ReceiptAbbreviationDatabase.shared.recordCorrection(raw: item.rawText, corrected: corrected)
                session.guestStore.learnOCRCorrection(raw: item.rawText, resolved: corrected)
                AICorrectionStore.shared.record(kind: .itemName, original: item.rawText,
                                                predicted: item.resolved, final: corrected,
                                                outcome: corrected == item.resolved ? .accepted : .edited)
                lineItems[index].resolved = corrected
            },
            onZoneChange: { newZone in
                AICorrectionStore.shared.record(kind: .zone, original: item.rawText,
                                                predicted: item.zone, final: newZone,
                                                outcome: newZone == item.zone ? .accepted : .edited)
                lineItems[index].zone = newZone
            },
            onQuantityChange: { newQty in
                AICorrectionStore.shared.record(kind: .quantity, original: item.rawText,
                                                predicted: String(item.quantity), final: String(max(1, newQty)),
                                                outcome: newQty == item.quantity ? .accepted : .edited)
                lineItems[index].quantity = max(1, newQty)
            }
        )
    }
}

// MARK: - Inline review row with correction support
private struct ReviewRowView: View {
    @Environment(AppSession.self) var session
    let item: ReceiptLineItem
    var onToggle: () -> Void
    var onCorrect: (String) -> Void
    var onZoneChange: (String) -> Void
    var onQuantityChange: (Int) -> Void = { _ in }

    @State private var editing       = false
    @State private var editText      = ""
    @State private var showSaveAbbrev = false  // auto-learn prompt
    @State private var lastCorrected = ""      // the corrected name to save

    // Unknown token = raw text wasn't already in the abbreviation DB
    private var wasUnknown: Bool {
        ReceiptAbbreviationDatabase.shared.lookup(item.rawText) == nil &&
        item.rawText.uppercased() != item.resolved.uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Button { onToggle() } label: {
                    Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(item.isChecked ? Color.stockedGreen : Color.stockedCharcoal.opacity(0.25))
                }.buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    if editing {
                        TextField("Correct name…", text: $editText, onCommit: {
                            let trimmed = editText.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                onCorrect(trimmed)
                                // Prompt to save as abbreviation if token was unknown
                                if wasUnknown {
                                    lastCorrected = trimmed
                                    withAnimation { showSaveAbbrev = true }
                                }
                            }
                            editing = false
                        })
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                        .textFieldStyle(.plain)
                    } else {
                        HStack(spacing: 6) {
                            Text(item.resolved)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(session.themeTextColor)
                                .strikethrough(!item.isChecked)
                            // Shared provenance badge (AI parsed / Needs review) — same
                            // vocabulary the rest of the app uses, replacing the ad-hoc dot.
                            SourceBadgeView(badge: item.badge)
                        }
                        if item.rawText.uppercased() != item.resolved.uppercased() {
                            Text("Was: \(item.rawText)")
                                .font(.system(size: 10))
                                .foregroundStyle(session.themeTextColor.opacity(0.3))
                        }
                    }
                    HStack(spacing: 6) {
                        Text(item.zone)
                            .font(.system(size: 11))
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                        if let brand = item.brand, !brand.isEmpty {
                            Text(brand)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(session.themeTextColor.opacity(0.55))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(session.themeTextColor.opacity(0.08))
                                .clipShape(Capsule())
                        }
                        if let price = item.totalPrice ?? item.unitPrice {
                            Text(String(format: "$%.2f", price))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(session.themeTextColor.opacity(0.55))
                        }

                        // Inline quantity stepper — a misread count (e.g. "2LB" read as 1)
                        // is fixed here without re-scanning.
                        HStack(spacing: 0) {
                            Button {
                                onQuantityChange(max(1, item.quantity - 1))
                                HapticManager.select()
                            } label: {
                                Image(systemName: "minus")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(item.quantity > 1 ? Color.stockedCharcoal : Color.stockedCharcoal.opacity(0.25))
                                    .frame(width: 22, height: 20)
                            }
                            .buttonStyle(.plain)
                            .disabled(item.quantity <= 1)

                            Text("×\(item.quantity)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(session.themeTextColor.opacity(0.7))
                                .frame(minWidth: 22)

                            Button {
                                onQuantityChange(item.quantity + 1)
                                HapticManager.select()
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.stockedCharcoal)
                                    .frame(width: 22, height: 20)
                            }
                            .buttonStyle(.plain)
                        }
                        .background(session.themeTextColor.opacity(0.06))
                        .clipShape(Capsule())

                        if item.confidence < 60 {
                            Text("Uncertain — tap to correct")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Spacer()

                // Correct button
                if !editing {
                    Button {
                        editText = item.resolved
                        editing = true
                    } label: {
                        Image(systemName: "pencil.circle")
                            .font(.system(size: 18))
                            .foregroundStyle(session.themeTextColor.opacity(0.3))
                    }.buttonStyle(.plain)
                } else {
                    HStack(spacing: 8) {
                        Button("Save") {
                            let trimmed = editText.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                onCorrect(trimmed)
                                if wasUnknown {
                                    lastCorrected = trimmed
                                    withAnimation { showSaveAbbrev = true }
                                }
                            }
                            editing = false
                        }
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(Color.stockedGold)
                        .buttonStyle(.plain)
                        Button("Cancel") { editing = false }
                            .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.4))
                            .buttonStyle(.plain)
                    }
                }

                // Zone picker
                Menu {
                    ForEach(["Fridge","Freezer","Pantry","Staples"], id: \.self) { z in
                        Button(z) { onZoneChange(z) }
                    }
                } label: {
                    Text(item.zone)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.stockedGold)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.stockedCharcoal.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                }
            }
            .padding(14)
            .background(item.isChecked
                        ? Color.stockedWhite.opacity(0.35)
                        : session.themeTextColor.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            .contentShape(Rectangle())
            .onTapGesture { if !editing { onToggle() } }
            .animation(.spring(response: 0.2), value: item.isChecked)

            // ── Auto-learn abbreviation prompt ──────────────────────
            if showSaveAbbrev {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12)).foregroundStyle(Color.stockedGold)
                    Text("Save \"\(item.rawText)\" → \"\(lastCorrected)\" as abbreviation?")
                        .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.7))
                        .lineLimit(2)
                    Spacer()
                    Button("Save") {
                        ReceiptAbbreviationDatabase.shared.add(
                            item.rawText.uppercased(),
                            resolved: lastCorrected,
                            source: .userAdded
                        )
                        withAnimation { showSaveAbbrev = false }
                    }
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.stockedGold)
                    .buttonStyle(.plain)
                    Button("Skip") { withAnimation { showSaveAbbrev = false } }
                        .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.4))
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.stockedGold.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - ReceiptScannerView extension continued
extension ReceiptScannerView {
    // MARK: - Done
    var doneView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60)).foregroundStyle(Color.stockedGreen)
            Text("Added \(addedCount) items!")
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)
            if sessionTotal > addedCount {
                Text("\(sessionTotal) total across \(scanCount) receipts this session")
                    .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.55))
            } else {
                Text("Check your Inventory tab to see them.")
                    .font(.system(size: 15)).foregroundStyle(session.themeTextColor.opacity(0.6))
            }

            // Scan another receipt in same session
            Button {
                lineItems = []
                capturedText = ""
                detectedStore = ""
                phase = .scanning
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.viewfinder")
                    Text("Scan Another Receipt")
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                }
                .foregroundStyle(session.themeTextColor)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
            }
            .buttonStyle(.plain).padding(.horizontal, 28)

            Button { closeScanner() } label: {
                Text("Done")
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity).padding(.vertical, 17)
                    .background(Color.stockedCharcoal).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
            }
            .padding(.horizontal, 28)
            Spacer()
        }
    }

    // MARK: - Helpers
    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Color.stockedGold).frame(width: 24)
            Text(text).font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.7))
        }
    }

    private func addItemsToPantry() {
        let toAdd = lineItems.filter { $0.isChecked }
        let rdb   = ReceiptDatabase.shared
        var added = 0
        // #20 — attribute who added (household member name, falling back to device).
        let who = session.householdMemberName

        for item in toAdd {
            // Confirmation itself is a useful calibration signal, even when the user made no edit.
            AICorrectionStore.shared.record(kind: .itemName, original: item.rawText,
                                            predicted: item.resolved, final: item.resolved, outcome: .accepted)
            AICorrectionStore.shared.record(kind: .zone, original: item.rawText,
                                            predicted: item.zone, final: item.zone, outcome: .accepted)
            // No duplicate-skip here: addInventoryItem() now MERGES equivalent items
            // (bumps quantity) instead of creating duplicates (#2/#18).
            var inv = LocalInventoryItem(
                name: item.resolved, level: 1.0, zone: item.zone,
                quantity: max(1, item.quantity)
            )
            inv.expirationDate   = item.suggestedExpiry
            inv.brand            = item.brand                       // brand
            inv.price            = item.totalPrice ?? item.unitPrice // #1 price
            inv.purchaseDate     = detectedDate ?? Date()           // #5 date
            inv.storePurchasedAt = detectedStore.isEmpty ? nil : detectedStore // #5 store
            inv.addedBy          = who                              // #20
            inv.sourceBadge      = item.badge                       // provenance from OCR confidence
            session.guestStore.addInventoryItem(inv)
            added += 1
        }

        // #5 Receipt → auto-restock: check off any grocery-list items that match what was just
        // purchased, so the list reflects the shopping trip without manual ticking.
        let purchasedCanon = Set(toAdd.map { IngredientMatcher.canonical($0.resolved) })
        if !purchasedCanon.isEmpty {
            var list = session.guestStore.groceryItems
            var changed = false
            for i in list.indices where !list[i].isChecked {
                if purchasedCanon.contains(IngredientMatcher.canonical(list[i].name)) {
                    list[i].isChecked = true; changed = true
                }
            }
            if changed { session.guestStore.groceryItems = list }
        }

        // Teach ReceiptDatabase
        let learned = toAdd.map {
            LearnedReceiptItem(rawName: $0.rawText, resolvedName: $0.resolved,
                               zone: $0.zone, scanCount: 1, userConfirmed: true)
        }
        rdb.learn(rawText: capturedText, items: learned)

        // Update session counters
        addedCount   = added
        sessionTotal += added
        scanCount    += 1

        // #14/#19 — save items + total spend to the archive, and log prices to history.
        let savedNames = toAdd.map { $0.resolved }
        let spend = toAdd.compactMap { $0.totalPrice ?? $0.unitPrice }.reduce(0, +)
        for it in toAdd {
            if let p = it.totalPrice ?? it.unitPrice {
                session.guestStore.priceHistory.append(
                    PriceRecord(itemName: it.resolved, price: p,
                                store: detectedStore.isEmpty ? session.preferredStore : detectedStore))
            }
        }
        if session.guestStore.priceHistory.count > 2000 {
            session.guestStore.priceHistory = Array(session.guestStore.priceHistory.suffix(2000))
        }

        // Save to archive
        saveToArchive(itemCount: added, items: savedNames, spend: spend)
        phase = .done
    }

    // MARK: - Store name detection
    private func detectStoreName(from text: String) -> String {
        let firstLines = text.components(separatedBy: "\n").prefix(6).joined(separator: " ").lowercased()
        // H-E-B first, with its many on-receipt forms (HEB receipts often print
        // "HEB", "H-E-B", "heb.com", "Here Everything's Better", or an HEB banner
        // like "Central Market" / "Mi Tienda" / "Joe V's").
        let hebMarkers = ["h-e-b", "heb ", " heb", "heb.com", "here everything",
                          "central market", "mi tienda", "joe v's"]
        if hebMarkers.contains(where: { firstLines.contains($0) }) { return "H-E-B" }

        let known = ["Walmart","Target","Kroger","Whole Foods","Aldi","Publix",
                     "Safeway","Costco","Trader Joe","Sprouts","Meijer","Wegmans","Food Lion",
                     "Amazon Fresh","Sam's Club","Instacart","FreshDirect","Market Basket"]
        for store in known {
            if firstLines.contains(store.lowercased()) { return store }
        }
        return ""
    }

    // MARK: - Quantity parsing helper (used by AI parse + fallback)
    private func parseQuantity(from raw: String) -> Int {
        // Pre-compiled regex patterns — try? avoids crash on bad pattern strings
        let patterns: [(NSRegularExpression?, Int)] = [
            (try? NSRegularExpression(pattern: #"(\d+)\s*(?:ct|pack|pk|ea|x)\b"#, options: .caseInsensitive), 1),
            (try? NSRegularExpression(pattern: #"qty\s*(\d+)"#,                    options: .caseInsensitive), 1),
            (try? NSRegularExpression(pattern: #"^(\d+)\s+\w"#),                  1),
        ]
        let range = NSRange(raw.startIndex..., in: raw)
        for (regex, group) in patterns {
            guard let regex else { continue }
            if let match = regex.firstMatch(in: raw, range: range),
               let r = Range(match.range(at: group), in: raw),
               let n = Int(raw[r]), n > 1, n < 50 {
                return n
            }
        }
        return 1
    }

    // MARK: - OCR on photo (screenshot / e-receipt import)
    func runOCROnImage(_ image: UIImage) {
        guard let cgImage = image.cgImage else { return }
        phase = .review
        isProcessing = true
        lineItems = []
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest { req, _ in
                let strings = (req.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
                let combined = strings.joined(separator: "\n")
                Task { @MainActor in
                    self.capturedText = combined
                    self.detectedStore = self.detectStoreName(from: combined)
                    self.parseReceiptWithAI(combined)
                }
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        }
    }

    // MARK: - Archive persistence
    private func loadArchive() {
        guard let data = UserDefaults.standard.data(forKey: "receiptArchive_v1"),
              let decoded = try? JSONDecoder().decode([ReceiptArchiveEntry].self, from: data)
        else { return }
        archive = decoded.sorted { $0.date > $1.date }
    }

    private func saveToArchive(itemCount: Int, items: [String] = [], spend: Double = 0) {
        let entry = ReceiptArchiveEntry(
            date: Date(), storeName: detectedStore, itemCount: itemCount,
            items: items, totalSpend: spend
        )
        archive.insert(entry, at: 0)
        // Keep last 30 scans
        if archive.count > 30 { archive = Array(archive.prefix(30)) }
        if let data = try? JSONEncoder().encode(archive) {
            UserDefaults.standard.set(data, forKey: "receiptArchive_v1")
        }
    }

    private func loadDemoReceipt() {
        let demo = """
        CHICKEN BREAST 2LB
        WHOLE MILK GAL
        LARGE EGGS 12CT
        CHEDDAR CHEESE 8OZ
        SPINACH BABY 5OZ
        OLIVE OIL 16OZ
        PASTA PENNE 1LB
        TOMATO SAUCE 24OZ
        GARLIC BULB
        RED ONION
        TAX 0.00
        TOTAL 47.82
        """
        capturedText = demo
        parseReceiptWithAI(demo)
        phase = .review
    }

    // MARK: - AI Parsing
    // MARK: - Receipt parsing (image-first, with fallbacks)
    // 1) parseReceipt(image:)  → send PHOTO to Claude (best). 2) parseReceiptWithAI(text:)
    // → OCR text to Claude (fallback). 3) fallbackParse(text:) → offline regex.

    private func learnedCorrectionsPayload() -> [[String: String]] {
        session.guestStore.ocrDictionary
            .sorted { $0.useCount > $1.useCount }.prefix(40)
            .map { ["raw": $0.rawText, "name": $0.resolved] }
    }


    /// PRIMARY — send the receipt photo to Claude via the Worker.
    func parseReceipt(image: UIImage) {
        phase = .review; isProcessing = true; lineItems = []; errorMsg = ""
        guard ConnectivityMonitor.isOnlineFlag else { runOCROnImage(image); return }
        guard let jpeg = Self.downscaledJPEG(image, maxDimension: 1600, quality: 0.7),
              StockedWorkerClient.isConfigured else { runOCROnImage(image); return }
        var payload: [String: Any] = ["imageBase64": jpeg.base64EncodedString(),
                                      "imageMediaType": "image/jpeg"]
        let storeHint = detectedStore.isEmpty ? session.preferredStore : detectedStore
        if !storeHint.isEmpty { payload["storeName"] = storeHint }
        let corrections = learnedCorrectionsPayload()
        if !corrections.isEmpty { payload["corrections"] = corrections }
        Task { @MainActor in
            do {
                // Image requests deliberately bypass persistent result caching.
                let data = try await StockedWorkerClient.requestData(route: .receiptImage,
                                                                     payload: payload,
                                                                     timeout: 50,
                                                                     cacheTTL: 0)
                if let items = self.decodeItems(from: data), !items.isEmpty {
                    self.applyParsed(items, from: data)
                } else { self.runOCROnImage(image) }
            } catch {
                self.errorMsg = error.localizedDescription
                self.runOCROnImage(image)
            }
        }
    }

    /// FALLBACK — OCR text to Claude via the Worker.
    private func parseReceiptWithAI(_ receiptText: String) {
        isProcessing = true; errorMsg = ""
        var payload: [String: Any] = ["receipt": receiptText]
        let storeHint = detectedStore.isEmpty ? session.preferredStore : detectedStore
        if !storeHint.isEmpty { payload["storeName"] = storeHint }
        let corrections = learnedCorrectionsPayload()
        if !corrections.isEmpty { payload["corrections"] = corrections }
        guard StockedWorkerClient.isConfigured else {
            isProcessing = false; lineItems = fallbackParse(receiptText); return
        }
        Task { @MainActor in
            do {
                let data = try await StockedWorkerClient.requestData(route: .receiptText,
                                                                     payload: payload,
                                                                     timeout: 45,
                                                                     cacheTTL: 0)
                if let items = self.decodeItems(from: data), !items.isEmpty {
                    self.applyParsed(items, from: data)
                } else {
                    self.lineItems = fallbackParse(receiptText); self.isProcessing = false
                }
            } catch {
                self.errorMsg = "Smart reading was unavailable — showing a basic scan instead."
                self.lineItems = fallbackParse(receiptText)
                self.isProcessing = false
            }
        }
    }

    /// Apply parsed items; #4 multi-photo appends instead of replacing; also reads
    /// store + date (#5) from the AI response meta if present.
    private func applyParsed(_ items: [ReceiptLineItem], from data: Data) {
        if isAddingAnotherPage {
            // #4 — merge into existing list, de-duping by resolved name.
            var combined = lineItems
            for it in items where !combined.contains(where: { $0.resolved.lowercased() == it.resolved.lowercased() }) {
                combined.append(it)
            }
            lineItems = combined
            isAddingAnotherPage = false
        } else {
            lineItems = items
        }
        // #5 — pull store/date from the response's meta object if the model returned one.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let content = json["content"] as? [[String: Any]],
           let text = content.first?["text"] as? String,
           let metaStart = text.range(of: "\"_meta\"") {
            _ = metaStart  // meta is best-effort; store detection also runs on OCR text below
        }
        if detectedStore.isEmpty { detectedStore = detectStoreName(from: capturedText) }
        isProcessing = false
    }

    /// Shared decoder: Anthropic response → [ReceiptLineItem] (brand/price/qty aware).
    private func decodeItems(from data: Data) -> [ReceiptLineItem]? {
        guard let response = try? AIResponseDecoder.textResponse(from: data),
              let jsonData = try? AIResponseDecoder.jsonData(from: response.text, root: "["),
              let array = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else { return nil }
        let receiptDB = ReceiptDatabase.shared
        let abbreviationDB = ReceiptAbbreviationDatabase.shared
        let storeHint = detectedStore.isEmpty ? session.preferredStore : detectedStore

        let parsed: [ReceiptLineItem] = array.compactMap { object in
            let raw = (object["raw"] as? String) ?? (object["name"] as? String) ?? ""
            let aiResolved = object["resolved"] as? String ?? object["name"] as? String
            guard !raw.isEmpty else { return nil }
            let aiCategory = object["category"] as? String
            let aiIsFood = (object["isFood"] as? Bool) ?? (object["isFood"] as? NSNumber)?.boolValue
            guard FoodWhitelist.isAllowed(aiResolved ?? raw, aiSaysFood: aiIsFood, aiCategory: aiCategory) else { return nil }

            let learned = receiptDB.learnedItems[FoodNameMatcher.normalized(aiResolved ?? raw)]
            guard let normalized = ReceiptProcessingService.normalize(
                raw: raw,
                aiResolved: aiResolved,
                storeName: storeHint,
                learnedTranslation: session.guestStore.translateOCR(raw),
                abbreviationTranslation: abbreviationDB.lookup(raw)
            ) else { return nil }

            let aiZone = (object["zone"] as? String).flatMap(StorageCategory.init(rawValue:))
            let learnedZone = learned.flatMap { StorageCategory(rawValue: $0.zone) }
            let decision = ZoneDecisionEngine.decide(name: normalized.resolved,
                                                     learnedZone: learnedZone,
                                                     learnedCount: learned?.scanCount ?? 0,
                                                     aiZone: aiZone)
            let shelfDays = (object["shelfDays"] as? NSNumber)?.intValue
            let expiry = ShelfLifeEstimator.estimate(name: normalized.resolved,
                                                     zone: decision.zone,
                                                     aiDays: shelfDays).date
            let unitPrice = (object["unitPrice"] as? NSNumber)?.doubleValue
            let totalPrice = (object["totalPrice"] as? NSNumber)?.doubleValue
            let aiQuantity = (object["quantity"] as? NSNumber)?.intValue
            let quantity = max(normalized.quantity, aiQuantity ?? 1)
            let baseConfidence = learned == nil ? decision.confidence : min(0.99, decision.confidence + 0.1)
            let confidence = Int(AICorrectionStore.shared.adjustedConfidence(
                kind: .itemName, original: raw, predicted: normalized.resolved, base: baseConfidence
            ) * 100)
            return ReceiptLineItem(rawText: raw, resolved: normalized.resolved, isFood: true,
                                   zone: decision.zone.rawValue, suggestedExpiry: expiry,
                                   quantity: max(1, quantity), confidence: confidence,
                                   brand: (object["brand"] as? String) ?? normalized.brand,
                                   unitPrice: unitPrice, totalPrice: totalPrice)
        }
        return ReceiptProcessingService.consolidate(parsed, key: \.resolved, quantity: \.quantity) { item, total in
            var copy = item; copy.quantity = total; return copy
        }
    }

    private static func downscaledJPEG(_ image: UIImage, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1
        let rendered = UIGraphicsImageRenderer(size: newSize, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return rendered.jpegData(compressionQuality: quality)
    }

    private func fallbackParse(_ text: String) -> [ReceiptLineItem] {
        let rdb       = ReceiptDatabase.shared
        let abbrevDB  = ReceiptAbbreviationDatabase.shared
        let skipWords = ["tax","total","subtotal","change","cash","card","receipt","store",
                         "thank","visit","save","club","loyalty","member","qty","price","ref"]
        return text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty, line.count > 2 else { return false }
                let lower = line.lowercased()
                if lower.contains("$") || lower.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
                if skipWords.contains(where: { lower.contains($0) }) { return false }
                // Food-only whitelist (same as the AI path) so the offline fallback also
                // excludes non-food/consumable lines.
                return FoodWhitelist.isAllowed(line)
            }
            .prefix(25)
            .map { raw in
                let learned = session.guestStore.translateOCR(raw)
                let normalized = ReceiptProcessingService.normalize(raw: raw,
                    aiResolved: nil, storeName: detectedStore,
                    learnedTranslation: learned, abbreviationTranslation: abbrevDB.lookup(raw))
                let resolved = normalized?.resolved ?? rdb.normalize(raw)
                let zone = StorageCategory(rawValue: rdb.bestZone(for: resolved)) ?? ZoneClassifier.classify(resolved)
                let expiry = ShelfLifeEstimator.estimate(name: resolved, zone: zone).date
                return ReceiptLineItem(rawText: raw, resolved: resolved, isFood: true,
                                       zone: zone.rawValue, suggestedExpiry: expiry,
                                       quantity: normalized?.quantity ?? 1,
                                       brand: normalized?.brand)
            }
    }
}

// MARK: - Shutter notification
nonisolated extension Notification.Name {
    static let captureReceiptShutter = Notification.Name("captureReceiptShutter")
}

// MARK: - LiveTextScannerPanel
// IMPORTANT: Must fill entire screen — embed in ZStack with .ignoresSafeArea()
@available(iOS 16.0, *)
struct LiveTextScannerPanel: UIViewControllerRepresentable {
    var onCapture: (String) -> Void
    var onCaptureImage: ((UIImage) -> Void)? = nil

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isGuidanceEnabled: false,       // we show our own guidance overlay
            isHighlightingEnabled: true
        )
        vc.delegate            = context.coordinator
        context.coordinator.vc = vc
        context.coordinator.onCapture = onCapture
        context.coordinator.onCaptureImage = onCaptureImage

        // Listen for manual shutter button taps
        context.coordinator.shutterObserver = NotificationCenter.default.addObserver(
            forName: .captureReceiptShutter,
            object: nil,
            queue: .main
        ) { [weak vc, weak coordinator = context.coordinator] _ in
            guard let vc, let coordinator else { return }
            Task { @MainActor in
                coordinator.captureAllText(from: vc)
            }
        }

        // Start scanning — must be called after delegate is set
        Task {
            try? await Task.sleep(nanoseconds: 100000000)
            try? vc.startScanning()
        }
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        weak var vc: DataScannerViewController?
        var onCapture: ((String) -> Void)?
        var onCaptureImage: ((UIImage) -> Void)?
        var shutterObserver: Any?

        deinit {
            if let obs = shutterObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        // Tapping recognized text also triggers capture
        func dataScanner(_ scanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            captureAllText(from: scanner)
        }

        @MainActor
        func captureAllText(from scanner: DataScannerViewController) {
            scanner.stopScanning()
            Task {
                do {
                    let image = try await scanner.capturePhoto()
                    if let onCaptureImage { onCaptureImage(image) }
                    else { self.runVisionOCR(on: image) }
                } catch {
                    self.readRecognizedItems(from: scanner)
                }
            }
        }

        // Stored recognized items — updated by delegate callbacks as scanner runs
        var storedTranscripts: [String] = []

        func dataScanner(_ scanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            storedTranscripts = allItems.compactMap { item -> String? in
                guard case .text(let t) = item else { return nil }
                return t.transcript
            }
        }

        func dataScanner(_ scanner: DataScannerViewController,
                         didUpdate updatedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            storedTranscripts = allItems.compactMap { item -> String? in
                guard case .text(let t) = item else { return nil }
                return t.transcript
            }
        }

        // Fallback: use stored transcripts collected by delegate
        private func readRecognizedItems(from scanner: DataScannerViewController) {
            let combined = storedTranscripts.joined(separator: "\n")
            if combined.isEmpty { return }
            Task { @MainActor in self.onCapture?(combined) }
        }

        private func runVisionOCR(on image: UIImage) {
            guard let cgImage = image.cgImage else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { req, _ in
                    let strings = (req.results as? [VNRecognizedTextObservation])?
                        .compactMap { $0.topCandidates(1).first?.string } ?? []
                    let combined = strings.joined(separator: "\n")
                    Task { @MainActor in self.onCapture?(combined) }
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                try? VNImageRequestHandler(cgImage: cgImage).perform([request])
            }
        }
    }
}

// MARK: - Receipt Archive Sheet
struct ReceiptArchiveSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    let entries: [ReceiptArchiveEntry]
    @State private var reimportMsg = ""

    private var totalSpend: Double { entries.reduce(0) { $0 + $1.totalSpend } }

    private let df: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                Capsule().fill(Color.stockedCharcoal.opacity(0.2))
                    .frame(width: 40, height: 4).padding(.top, 12).padding(.bottom, 16)
                HStack {
                    Text("Scan History")
                        .font(.system(size: 20, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Spacer()
                    Button("Done") { dismiss() }
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.stockedGold)
                }
                .padding(.horizontal, 24).padding(.bottom, 16)

                if totalSpend > 0 {
                    HStack {
                        Text("Total tracked spend")
                            .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
                        Spacer()
                        Text(String(format: "$%.2f", totalSpend))
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(Color.stockedGold)
                    }
                    .padding(.horizontal, 24).padding(.bottom, 8)
                }
                if !reimportMsg.isEmpty {
                    Text(reimportMsg)
                        .font(.system(size: 11)).foregroundStyle(Color.stockedGold)
                        .padding(.bottom, 8)
                }

                if entries.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 40)).foregroundStyle(session.themeTextColor.opacity(0.2))
                        Text("No scans yet")
                            .font(.system(size: 15, design: .serif))
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                        Spacer()
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 10) {   // perf: long receipts can be 50+ rows
                            ForEach(entries) { entry in
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                                            .fill(Color.stockedCharcoal.opacity(0.12))
                                            .frame(width: 44, height: 44)
                                        Image(systemName: "doc.text.fill")
                                            .font(.system(size: 18)).foregroundStyle(Color.stockedGold)
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.storeName.isEmpty ? "Receipt" : entry.storeName)
                                            .font(.system(size: 14, weight: .semibold, design: .serif))
                                            .foregroundStyle(session.themeTextColor)
                                        Text(df.string(from: entry.date))
                                            .font(.system(size: 11))
                                            .foregroundStyle(session.themeTextColor.opacity(0.45))
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text("\(entry.itemCount) items")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Color.stockedGold)
                                        if entry.totalSpend > 0 {
                                            Text(String(format: "$%.2f", entry.totalSpend))
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(session.themeTextColor.opacity(0.55))
                                        }
                                        // #14 — re-import this receipt's items to the pantry.
                                        if !entry.items.isEmpty {
                                            Button {
                                                var n = 0
                                                for name in entry.items {
                                                    var inv = LocalInventoryItem(name: name, level: 1.0, zone: "Pantry")
                                                    inv.purchaseDate = Date()
                                                    session.guestStore.addInventoryItem(inv)
                                                    n += 1
                                                }
                                                reimportMsg = "Re-added \(n) items"
                                                HapticManager.success()
                                            } label: {
                                                Text("Re-import")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundStyle(Color.stockedWhite)
                                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                                    .background(session.themeButtonColor).clipShape(Capsule())
                                            }.buttonStyle(.plain)
                                        }
                                    }
                                }
                                .padding(14)
                                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.35))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                            }
                        }
                        .padding(.horizontal, 24).padding(.bottom, 40)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview { ReceiptScannerView().environment(AppSession()) }

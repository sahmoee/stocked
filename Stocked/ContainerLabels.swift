// ContainerLabels.swift — Feature 15: the mystery container problem, solved.
//
// Everyone has an unlabelled tub in the freezer. Masking tape and a Sharpie work until the writing
// smudges or you forget what "chili 3/12" meant. A printed QR label ties a physical container to a
// real record — contents, portions, date frozen, and the recipe it came from — that stays accurate
// even after the ink fades.
//
// QR rather than NFC as the first slice: it prints on any label sheet, costs nothing, works from
// any camera, and needs no entitlement. `ContainerCode.payload` is the seam for NFC later — the
// same string can be written to a tag without changing the data model.

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

// MARK: - Model

nonisolated struct ContainerLabel: Codable, Identifiable, Hashable, Sendable, HouseholdSyncable {
    // ── Household sync (launch readiness 1.4) ────────────────────────────────
    // Defaulted so entries saved before sync existed still decode. Same epoch-ms
    // last-write-wins convention as LocalInventoryItem.
    var updatedAt: Double = 0
    var lastWriterID: String = ""

    var id: UUID = UUID()
    var contents: String
    var portions: Int = 1
    var filledOn: Date = Date()
    var storage: String = "Freezer"
    var note: String = ""
    var recipeTitle: String = ""

    /// Short human code printed under the QR, so a smudged label is still readable.
    var shortCode: String { String(id.uuidString.prefix(6)).uppercased() }

    var useByDate: Date {
        let days = storage == "Freezer" ? 180 : 5
        return Calendar.current.date(byAdding: .day, value: days, to: filledOn) ?? filledOn
    }
    var daysLeft: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: useByDate).day ?? 0
    }
    var isPastDate: Bool { useByDate < Date() }

    /// What gets encoded. G2 (QA gap): use an HTTPS universal link instead of the bare
    /// `stocked://` custom scheme. Scanned with the app installed it deep-links into Stocked;
    /// scanned WITHOUT the app it opens the web page (which can offer the App Store) rather
    /// than doing nothing. The app's associated-domains entitlement claims the `/l/` path.
    var payload: String { "https://sowensstudios.com/l/\(id.uuidString)" }

    /// Fallback text shown if the app isn't installed — encoded as a second line for plain readers.
    var humanSummary: String {
        var parts = [contents]
        if portions > 1 { parts.append("\(portions) portions") }
        parts.append(filledOn.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }
}

// MARK: - QR generation

nonisolated enum ContainerCode {
    /// One shared context — building a CIContext per call is expensive and shows up as jank when
    /// rendering a sheet of labels.
    ///
    /// `nonisolated(unsafe)` is correct here rather than a workaround: CIContext is documented as
    /// thread-safe for concurrent rendering, it's immutable after creation, and we never mutate it.
    /// The compiler can't see that guarantee because CIContext predates Sendable.
    private static let context = CIContext()

    static func qr(for text: String, scale: CGFloat = 10) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // "M" tolerates ~15% damage — right for a label that will get frost and freezer burn on it.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Store

@MainActor
@Observable
final class ContainerLabelStore {
    static let shared = ContainerLabelStore()
    /// Improvement #6 — file-backed, debounced, and migrated automatically from the old
    /// UserDefaults blob on first load. See FeatureStore.swift for why.
    private let store = FeatureStore<ContainerLabel>(key: FeatureStoreKeys.containerLabels)
    /// Re-entrancy guard for the sync stamping pass (see the didSet). Not observed.
    @ObservationIgnored private var _stamping = false

    var labels: [ContainerLabel] = [] { didSet {
        store.save(labels)
        // CRASH FIX (build 65): assign the stamped array once, guarded, so the
        // follow-up didSet is a no-op instead of recursing forever (see FeatureSync).
        guard !_stamping else { return }
        _stamping = true
        let _stamped = FeatureSync.shared.stampMutation(FeatureSync.Keys.containerLabels, old: oldValue, current: labels)
        if _stamped != labels { labels = _stamped }
        _stamping = false
    } }

    private init() {
        _stamping = true
        labels = store.load()
        _stamping = false
    }

    /// Push any pending write to disk immediately (call before backgrounding).
    func flush() { store.flush() }

    /// Oldest first — that's the one to eat.
    var byAge: [ContainerLabel] { labels.sorted { $0.filledOn < $1.filledOn } }

    func add(_ l: ContainerLabel) { labels.append(l) }
    /// #5 — undoable: a label deleted by mistake means an unidentifiable container again.
    func remove(_ l: ContainerLabel) {
        labels.removeAll { $0.id == l.id }
        ToastCenter.shared.undo("Deleted label for \(l.contents)") { [weak self] in
            self?.labels.append(l)
        }
    }

    /// Resolve a scanned payload back to a label.
    func label(forPayload payload: String) -> ContainerLabel? {
        guard let idString = payload.split(separator: "/").last,
              let uuid = UUID(uuidString: String(idString)) else { return nil }
        return labels.first { $0.id == uuid }
    }
}

// MARK: - UI

struct ContainerLabelsView: View {
    @Environment(AppSession.self) private var session
    private let store = ContainerLabelStore.shared
    @State private var showAdd = false

    var body: some View {
        Group {
            if store.labels.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "qrcode").font(.system(size: 34))
                        .foregroundStyle(session.themeTextColor.opacity(0.25))
                    Text("No labels yet").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                    Text("Make a label for a container, stick it on, and scanning it later tells you exactly what's inside and when it went in — no more mystery tubs.")
                        .font(.system(size: 13)).multilineTextAlignment(.center)
                        .foregroundStyle(session.themeTextColor.opacity(0.55)).padding(.horizontal, 36)
                    Button { showAdd = true } label: {
                        Text("Make a label").font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(session.accentColor).foregroundStyle(.white).clipShape(Capsule())
                    }.buttonStyle(.plain).padding(.top, 4)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(store.byAge) { label in
                            NavigationLink { ContainerLabelDetailView(label: label) } label: {
                                HStack(spacing: 12) {
                                    if let img = ContainerCode.qr(for: label.payload, scale: 4) {
                                        Image(uiImage: img)
                                            .interpolation(.none).resizable()
                                            .frame(width: 42, height: 42)
                                            .background(Color.white)
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(label.contents).font(.system(size: 14, weight: .semibold))
                                        Text("\(label.storage) · \(label.filledOn.formatted(date: .abbreviated, time: .omitted))")
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(label.isPastDate ? "past date" : "\(label.daysLeft)d")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(label.isPastDate ? .red : .secondary)
                                }
                            }
                        }
                        .onDelete { idx in idx.map { store.byAge[$0] }.forEach { store.remove($0) } }
                    } footer: {
                        Text("Print on any label sheet, or screenshot and print. The six-character code under each QR is a readable backup if the print smudges.")
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .stockedScreen()
        .navigationTitle("Container Labels")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showAdd = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $showAdd) { AddContainerLabelSheet() }
    }
}

struct ContainerLabelDetailView: View {
    @Environment(AppSession.self) private var session
    let label: ContainerLabel

    private var qrImage: UIImage? { ContainerCode.qr(for: label.payload, scale: 12) }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // The printable label itself — deliberately white-on-black-text so it prints legibly
                // regardless of the app's theme.
                VStack(spacing: 8) {
                    if let img = qrImage {
                        Image(uiImage: img)
                            .interpolation(.none).resizable()
                            .frame(width: 180, height: 180)
                    }
                    Text(label.contents)
                        .font(.system(size: 17, weight: .bold)).foregroundStyle(.black)
                        .multilineTextAlignment(.center)
                    Text(label.humanSummary)
                        .font(.system(size: 12)).foregroundStyle(.black.opacity(0.7))
                        .multilineTextAlignment(.center)
                    Text("Use by \(label.useByDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.black.opacity(0.8))
                    Text(label.shortCode)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black.opacity(0.5))
                }
                .padding(18)
                .frame(maxWidth: .infinity)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.15)))
                .padding(.horizontal, 24)

                if let img = qrImage {
                    ShareLink(item: Image(uiImage: img),
                              preview: SharePreview(label.contents, image: Image(uiImage: img))) {
                        Label("Share or print", systemImage: "printer")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(session.accentColor).foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 13))
                    }
                    .padding(.horizontal, 24)
                }

                VStack(alignment: .leading, spacing: 6) {
                    detailRow("Portions", "\(label.portions)")
                    detailRow("Stored in", label.storage)
                    detailRow("Filled", label.filledOn.formatted(date: .abbreviated, time: .omitted))
                    if !label.recipeTitle.isEmpty { detailRow("Recipe", label.recipeTitle) }
                    if !label.note.isEmpty { detailRow("Note", label.note) }
                }
                .padding(.horizontal, 28).padding(.top, 4)

                Text("Scanning this with any camera opens it in Stocked. The printed code and date stay readable even if the QR is damaged.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40).padding(.top, 6)
            }
            .padding(.vertical, 18)
        }
        .stockedScreen()
        .navigationTitle("Label")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detailRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(size: 13, weight: .medium)).foregroundStyle(session.themeTextColor)
        }
    }
}

private struct AddContainerLabelSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSession.self) private var session
    private let store = ContainerLabelStore.shared

    @State private var contents = ""
    @State private var portions = 2
    @State private var storage = "Freezer"
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("What's in the container?", text: $contents)
                Stepper("\(portions) portion\(portions == 1 ? "" : "s")", value: $portions, in: 1...20)
                Picker("Storage", selection: $storage) {
                    Text("Freezer").tag("Freezer"); Text("Fridge").tag("Fridge"); Text("Pantry").tag("Pantry")
                }.pickerStyle(.segmented)
                TextField("Note (optional)", text: $note)

                let cooked = session.guestStore.plannedMeals.filter(\.isCooked)
                if !cooked.isEmpty && contents.isEmpty {
                    Section("From something you cooked") {
                        ForEach(cooked.prefix(8), id: \.id) { m in
                            Button(m.title) { contents = m.title }
                        }
                    }
                }
            }
            .navigationTitle("New label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") {
                        store.add(ContainerLabel(contents: contents.trimmingCharacters(in: .whitespaces),
                                                 portions: portions, storage: storage, note: note))
                        HapticManager.success()
                        dismiss()
                    }
                    .font(.body.bold())
                    .disabled(contents.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

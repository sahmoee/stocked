// InventoryItemSheets.swift — extracted from InventoryView.swift (#8/#9 file split).
// Self-contained sheet/popup components: EditItemSheet, AddItemSheet, IngredientBrowserSheet,
// ExpiryDateRow, ItemDetailPopup, ItemPhotoPicker, IngredientPairingsSheet.
// These are independent SwiftUI View types (no reference to InventoryView privates), so they
// move out cleanly to shrink the 2,667-line InventoryView.swift.
import SwiftUI
import Combine
import PhotosUI
import os

struct EditItemSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    var item: LocalInventoryItem
    @State private var level:       Double
    @State private var zone:        String
    @State private var hasExpiry:   Bool
    @State private var expiryDate:  Date
    @State private var qty:         Int
    @State private var unit:        String
    @State private var hasCount:    Bool
    @State private var countValue:  Int
    @State private var imageData:   Data?
    @State private var par:         Int
    @State private var category:    String
    @State private var subZone:     String
    @State private var showPhotoPicker = false
    @State private var editedName:    String
    @State private var isEditingName: Bool = false
    @FocusState private var nameFieldFocused: Bool

    let zones = ["Fridge","Freezer","Pantry","Staples"]
    let commonUnits = ["items","g","kg","ml","L","oz","lb","bag","box","pack","can","jar","bottle","bunch","dozen"]

    init(item: LocalInventoryItem) {
        self.item = item
        _level     = State(initialValue: item.level)
        _zone      = State(initialValue: item.zone)
        _hasExpiry  = State(initialValue: item.expirationDate != nil)
        _expiryDate = State(initialValue: item.expirationDate ?? Date().addingTimeInterval(7*86400))
        _qty        = State(initialValue: max(1, item.quantity))
        _unit       = State(initialValue: item.containerType.isEmpty ? "item" : item.containerType)
        _hasCount   = State(initialValue: false)
        _countValue = State(initialValue: 1)
        _imageData  = State(initialValue: item.imageData)
        _par        = State(initialValue: item.parQuantity ?? 0)
        _category   = State(initialValue: item.customCategory ?? "")
        _subZone    = State(initialValue: item.subZone ?? "")
        _editedName = State(initialValue: item.name.displayNormalized)
    }

    private var subZonePlaceholder: String {
        switch zone {
        case "Fridge":  return "e.g. Door, Top shelf, Crisper"
        case "Freezer": return "e.g. Top drawer, Door bin"
        case "Pantry":  return "e.g. Top shelf, Spice rack"
        default:         return "e.g. Cabinet, Counter"
        }
    }

    private func commitName() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            editedName = item.name.displayNormalized
        } else {
            editedName = trimmed
        }
        withAnimation(.easeInOut(duration: 0.15)) { isEditingName = false }
        nameFieldFocused = false
        HapticManager.select()
    }

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Capsule().fill(Color.stockedCharcoal.opacity(0.2))
                        .frame(width: 40, height: 4).padding(.top, 12).padding(.bottom, 16)

                    // Item name — tap the pencil to rename in place.
                    if isEditingName {
                        HStack(spacing: 8) {
                            TextField("Item name", text: $editedName, axis: .vertical)
                                .font(.system(size: 22, weight: .bold, design: .serif))
                                .foregroundStyle(session.themeTextColor)
                                .tint(Color.stockedGold)
                                .focused($nameFieldFocused)
                                .submitLabel(.done)
                                .onSubmit { commitName() }
                            Button { commitName() } label: {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(Color.stockedGold)
                            }.buttonStyle(.plain)
                            .a11yButton("Save name")
                        }
                        .padding(.horizontal, 28).padding(.bottom, 16)
                        .onAppear { nameFieldFocused = true }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(editedName)
                                .font(.system(size: 22, weight: .bold, design: .serif)).dynamicTypeSize(.xSmall ... .accessibility2)
                                .foregroundStyle(session.themeTextColor)
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) { isEditingName = true }
                            } label: {
                                Image(systemName: "square.and.pencil")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.stockedGold)
                            }.buttonStyle(.plain)
                            .a11yButton("Edit name", hint: "Rename this item")
                        }
                        .padding(.horizontal, 28).padding(.bottom, 16)
                    }

                    // Brand & price from the grocery catalog — hidden until data loads.
                    BrandPriceView(itemName: editedName, compact: false)
                        .padding(.horizontal, 28).padding(.bottom, 14)

                    if item.brand != nil || item.nutrition != nil || !(item.productLabels ?? []).isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    if let brand = item.brand, !brand.isEmpty {
                                        Text(brand)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(session.themeTextColor)
                                    }
                                    if let source = item.nutritionSource, !source.isEmpty {
                                        Text("Nutrition from \(source)")
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(session.themeSecondaryText)
                                    }
                                }
                                Spacer()
                                if let barcode = item.barcode, !barcode.isEmpty {
                                    Text(barcode)
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(session.themeSecondaryText)
                                }
                            }

                            if let facts = item.nutrition {
                                HStack(spacing: 8) {
                                    productMetric("Calories", "\(facts.calories)")
                                    productMetric("Protein", "\(facts.protein.formatted(.number.precision(.fractionLength(0...1))))g")
                                    productMetric("Carbs", "\(facts.totalCarbs.formatted(.number.precision(.fractionLength(0...1))))g")
                                    productMetric("Fat", "\(facts.totalFat.formatted(.number.precision(.fractionLength(0...1))))g")
                                }
                            }

                            if let labels = item.productLabels, !labels.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(labels.prefix(8), id: \.self) { label in
                                            Text(label)
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(session.themeTextColor.opacity(0.72))
                                                .padding(.horizontal, 8).padding(.vertical, 4)
                                                .background(Capsule().fill(Color.stockedGold.opacity(0.12)))
                                        }
                                    }
                                    .stockedScrollTargetLayout()
                                }
                                .stockedHorizontalSnap()
                            }
                        }
                        .padding(12)
                        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.34))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        .padding(.horizontal, 28).padding(.bottom, 16)
                    }

                    // ── Photo row ────────────────────────────────────────
                    photoRow
                    Picker("Zone", selection: $zone) {
                        ForEach(zones, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.segmented).padding(.horizontal, 28).padding(.bottom, 20)

                    // ── Quantity row: (N) (unit) of (N optional) ────
                    quantityRow

                    // ── Amount slider (fill level) ───────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Fill Level")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(session.themeTextColor.opacity(0.5))
                            Spacer()
                            Text("\(Int(level*100))%")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.stockedGold)
                        }
                        Slider(value: $level, in: 0.05...1.0, step: 0.05).tint(Color.stockedGold)
                    }.padding(.horizontal, 28).padding(.bottom, 20)

                    // ── Par level (auto-reorder) ─────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Keep at least")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(session.themeTextColor.opacity(0.5))
                            Spacer()
                            Text(par > 0 ? "\(par) in stock" : "Off")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(par > 0 ? Color.stockedGold : session.themeTextColor.opacity(0.4))
                        }
                        HStack(spacing: 16) {
                            Button { if par > 0 { withAnimation(.spring(response: 0.2)) { par -= 1 } } } label: {
                                Image(systemName: "minus.circle.fill").font(.system(size: 26))
                                    .foregroundStyle(par > 0 ? Color.stockedGold : session.themeTextColor.opacity(0.25))
                            }.buttonStyle(.plain).disabled(par == 0)
                            Text(par > 0 ? "\(par)" : "—")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(session.themeTextColor)
                                .frame(minWidth: 28)
                            Button { withAnimation(.spring(response: 0.2)) { par += 1 } } label: {
                                Image(systemName: "plus.circle.fill").font(.system(size: 26))
                                    .foregroundStyle(Color.stockedGold)
                            }.buttonStyle(.plain)
                            Spacer()
                            Text(par > 0 ? "Auto-added to your list when you drop below \(par)." : "Set a minimum to auto-reorder this item.")
                                .font(.system(size: 11))
                                .foregroundStyle(session.themeTextColor.opacity(0.45))
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.horizontal, 28).padding(.bottom, 20)

                    // ── Organize: category + spot (surfaces customCategory / subZone) ──
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Category")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(session.themeTextColor.opacity(0.5))
                            TextField("e.g. Snacks, Baking, Drinks", text: $category)
                                .font(.system(size: 15))
                                .foregroundStyle(session.themeTextColor)
                                .tint(Color.stockedGold)
                                .padding(.horizontal, 14).padding(.vertical, 11)
                                .background(Color.stockedWhite.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Spot in \(zone)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(session.themeTextColor.opacity(0.5))
                            TextField(subZonePlaceholder, text: $subZone)
                                .font(.system(size: 15))
                                .foregroundStyle(session.themeTextColor)
                                .tint(Color.stockedGold)
                                .padding(.horizontal, 14).padding(.vertical, 11)
                                .background(Color.stockedWhite.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 20)

                    // ── Expiry ───────────────────────────────────────
                    ExpiryDateRow(hasExpiry: $hasExpiry, expiryDate: $expiryDate)
                        .padding(.horizontal, 28).padding(.bottom, 24)

                    // ── Actions ──────────────────────────────────────
                    actionButtons
                }
            }
        }
        .presentationDetents([.large]).presentationDragIndicator(.hidden)
    }

    @ViewBuilder private var photoRow: some View {
        Button { showPhotoPicker = true } label: {
            ZStack {
                if let data = imageData, let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable().scaledToFill()
                        .frame(height: 140)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                } else {
                    RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                        .fill(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.35))
                        .frame(height: 80)
                    VStack(spacing: 6) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(session.themeTextColor.opacity(0.35))
                        Text("Add Photo")
                            .font(.system(size: 12))
                            .foregroundStyle(session.themeTextColor.opacity(0.35))
                    }
                }
                if imageData != nil {
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                withAnimation { imageData = nil }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white)
                                    .shadow(radius: 3)
                            }
                            .buttonStyle(.plain)
                            .padding(8)
                        }
                        Spacer()
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 28).padding(.bottom, 20)
        .sheet(isPresented: $showPhotoPicker) {
            ItemPhotoPicker(imageData: $imageData)
        }
    }

    private func productMetric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(session.themeTextColor)
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(session.themeSecondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.stockedGold.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
    }

    @ViewBuilder private var quantityRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("QUANTITY")
                .font(.system(size: 10, weight: .bold)).tracking(1)
                .foregroundStyle(session.themeTextColor.opacity(0.4))
                .padding(.horizontal, 28)

            HStack(spacing: 12) {
                // First number — stepper
                HStack(spacing: 0) {
                    Button { qty = max(1, qty - 1) } label: {
                        Image(systemName: "minus").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(session.themeTextColor).frame(width: 36, height: 36).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Text("\(qty)")
                        .font(.system(size: 18, weight: .bold, design: .serif))
                        .foregroundStyle(Color.stockedGold).frame(minWidth: 32)
                    Button { qty += 1 } label: {
                        Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(session.themeTextColor).frame(width: 36, height: 36).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))

                // Unit picker
                Menu {
                    ForEach(commonUnits, id: \.self) { u in Button(u) { unit = u } }
                } label: {
                    HStack(spacing: 4) {
                        Text(unit).font(.system(size: 14, weight: .semibold)).foregroundStyle(session.themeTextColor)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(session.themeTextColor.opacity(0.4))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                }

                // "of" connector
                Text("of").font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.4))

                // Second number (optional)
                if hasCount {
                    HStack(spacing: 0) {
                        Button { countValue = max(1, countValue - 1) } label: {
                            Image(systemName: "minus").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(session.themeTextColor).frame(width: 30, height: 36).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Text("\(countValue)")
                            .font(.system(size: 18, weight: .bold, design: .serif))
                            .foregroundStyle(Color.stockedGold).frame(minWidth: 28)
                        Button { countValue += 1 } label: {
                            Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(session.themeTextColor).frame(width: 30, height: 36).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                    Button {
                        withAnimation(.spring(response: 0.25)) { hasCount = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(session.themeTextColor.opacity(0.25))
                    }.buttonStyle(.plain)
                } else {
                    Button {
                        withAnimation(.spring(response: 0.25)) { hasCount = true; countValue = 1 }
                    } label: {
                        Text("None")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 28)

            // Preview label
            let preview = hasCount
                ? "\(qty) \(unit) of \(countValue)"
                : "\(qty) \(unit)"
            Text(preview + " of \(item.name)")
                .font(.system(size: 12, design: .serif))
                .foregroundStyle(session.themeTextColor.opacity(0.5))
                .padding(.horizontal, 28)
        }
        .padding(.bottom, 20)
    }

    @ViewBuilder private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                commitName()   // fold in any in-progress rename
                let finalName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let i = session.guestStore.inventoryItems.firstIndex(where: { $0.id == item.id }) {
                    if !finalName.isEmpty { session.guestStore.inventoryItems[i].name = finalName }
                    session.guestStore.inventoryItems[i].level          = level
                    session.guestStore.inventoryItems[i].storageCategory = StorageCategory(rawValue: zone) ?? .pantry
                    session.guestStore.inventoryItems[i].expirationDate = hasExpiry ? expiryDate : nil
                    session.guestStore.inventoryItems[i].quantity       = qty
                    session.guestStore.inventoryItems[i].containerType  = unit
                    session.guestStore.inventoryItems[i].imageData      = imageData
                    session.guestStore.inventoryItems[i].parQuantity    = par > 0 ? par : nil
                    let cat  = category.trimmingCharacters(in: .whitespacesAndNewlines)
                    let spot = subZone.trimmingCharacters(in: .whitespacesAndNewlines)
                    session.guestStore.inventoryItems[i].customCategory = cat.isEmpty ? nil : cat
                    session.guestStore.inventoryItems[i].subZone        = spot.isEmpty ? nil : spot
                    if hasCount {
                        session.guestStore.inventoryItems[i].quantityUsed = Double(countValue)
                    }
                }
                dismiss()
            } label: {
                Text("Save Changes")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(session.themeButtonColor).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
            }.buttonStyle(.plain).padding(.horizontal, 28)

            Button(role: .destructive) {
                session.guestStore.removeInventoryItem(id: item.id)
                dismiss()
            } label: {
                Text("Remove Item")
                    .font(.system(size: 14)).foregroundStyle(.red)
            }
        }.padding(.bottom, 32)
    }
}

// MARK: - Add Item Sheet — 3-step flow
struct AddItemSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss

    var defaultZone: String = "Fridge"

    // ── Step state ─────────────────────────────────────────────────
    @State private var step: Int = 1

    // Step 1
    @State private var itemName:       String = ""
    @State private var nameTouched:    Bool   = false   // inline validation (#9)
    @State private var zone:           String
    @State private var quantity:       Int    = 1
    @State private var containerType:  String = ""
    // Combined size + current-amount control (e.g. "6 of 12 eggs"). totalUnits is how many the
    // full container holds; currentUnits is how many are left → drives the stored fill level.
    @State private var hasAmount:      Bool   = false
    @State private var totalUnits:     Double = 12
    @State private var currentUnits:   Double = 12

    // Step 2
    @State private var showSizeDetails: Bool   = false
    @State private var sizeAmount:      String = ""
    @State private var sizeUnit:        String = ""

    // Step 3
    @State private var hasExpiry:  Bool = false
    @State private var expiryDate: Date = Date().addingTimeInterval(7 * 86400)

    // Browse
    // Single .sheet(item:) — stacked .sheet(isPresented:) made these need a second tap.
    private enum AddItemSheet: Int, Identifiable {
        case browse, scanBarcode
        var id: Int { rawValue }
    }
    @State private var activeAddSheet: AddItemSheet? = nil
    // Duplicate detection
    @State private var duplicateItem: LocalInventoryItem? = nil
    @State private var showDuplicateAlert = false
    // UPC fallback — name provided by user after failed barcode scan
    var upcFallbackName: String? = nil

    let zones = ["Fridge", "Freezer", "Pantry", "Staples"]

    init(defaultZone: String = "Fridge") {
        self.defaultZone = defaultZone
        _zone = State(initialValue: defaultZone)
    }

    // MARK: Body
    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            if !HouseholdSync.shared.myCanAdd {
                // Household permission gate: this member's access level can't add items. The owner
                // sets levels in the member profile. Owner and solo users always pass this.
                VStack(spacing: 14) {
                    Capsule().fill(Color.stockedCharcoal.opacity(0.2))
                        .frame(width: 40, height: 4).padding(.top, 12)
                    Spacer(minLength: 40)
                    Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(session.themeTextColor.opacity(0.4))
                    Text("View only").font(.system(size: 20, weight: .bold, design: .serif)).foregroundStyle(session.themeTextColor)
                    Text("Your household access level doesn't allow adding items. Ask the household owner if you need to add things.")
                        .font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.6))
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                    Button { dismiss() } label: {
                        Text("Close").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.stockedWhite)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color.stockedGold, in: RoundedRectangle(cornerRadius: 10))
                    }.padding(.horizontal, 40).padding(.top, 8)
                    Spacer()
                }
            } else {
            VStack(spacing: 0) {

                // ── Handle ──────────────────────────────────────────────
                Capsule().fill(Color.stockedCharcoal.opacity(0.2))
                    .frame(width: 40, height: 4).padding(.top, 12).padding(.bottom, 4)

                // ── Header ──────────────────────────────────────────────
                HStack {
                    Text("Add Item")
                        .font(.system(size: 22, weight: .bold, design: .serif)).dynamicTypeSize(.xSmall ... .accessibility2)
                        .foregroundStyle(session.themeTextColor)
                    Spacer()
                    Button { activeAddSheet = .scanBarcode } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "barcode.viewfinder").font(.system(size: 12, weight: .semibold))
                            Text("Scan")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
                        .clipShape(Capsule())
                    }.buttonStyle(.plain)
                    Button { activeAddSheet = .browse } label: {
                        Text("Browse")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.stockedWhite)
                            .padding(.horizontal, 14).padding(.vertical, 11)
                            .background(Color.stockedCharcoal)
                            .clipShape(Capsule())
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 24).padding(.vertical, 12)

                // ── Step indicator ──────────────────────────────────────
                HStack(spacing: 8) {
                    ForEach(1...3, id: \.self) { s in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(s <= step ? Color.stockedGold : Color.stockedCharcoal.opacity(0.2))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Text("\(s)").font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(s <= step ? Color.stockedCharcoal : Color.stockedCharcoal.opacity(0.4))
                                )
                            if s < 3 {
                                Rectangle().fill(Color.stockedCharcoal.opacity(s < step ? 0.5 : 0.15))
                                    .frame(height: 1).frame(maxWidth: 40)
                            }
                        }
                    }
                    Spacer()
                    Text(stepLabel).font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.45))
                }
                .padding(.horizontal, 24).padding(.bottom, 16)

                Divider()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        switch step {
                        case 1:  stepOneContent
                        case 2:  stepTwoContent
                        default: stepThreeContent
                        }
                    }
                    .padding(.top, 20).padding(.bottom, 40)
                }
            }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .dismissKeyboardOnTap()
        .keyboardDoneToolbar()
        .sheet(item: $activeAddSheet) { sheet in
            switch sheet {
            case .browse:
                IngredientBrowserSheet(defaultZone: zone).environment(session)
            case .scanBarcode:
                // #250 — BarcodeScannerView adds the scanned item to inventory itself, then
                // calls onResult and dismisses. Once it returns having added something, close
                // the Add Item sheet too so the user lands back on their pantry.
                BarcodeScannerView { name, _ in
                    activeAddSheet = nil
                    if !name.isEmpty { dismiss() }
                }
                .environment(session)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
    }

    private var stepLabel: String {
        switch step {
        case 1: return "Required fields"
        case 2: return "Size details (optional)"
        default: return "Expiration (optional)"
        }
    }

    // MARK: - Step 1: Basic Info
    private var stepOneContent: some View {
        VStack(spacing: 20) {
            // Item name
            VStack(alignment: .leading, spacing: 10) {
                Text("ITEM NAME")
                    .font(.system(size: 10, weight: .bold)).tracking(1)
                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                VStack(alignment: .leading, spacing: 0) {
                    FoodPredictiveTextField(
                        placeholder: "Item name",
                        text: $itemName,
                        onCommit: {},
                        onSelect: { selected in
                            // Auto-classify zone when user picks a suggestion
                            let suggested = ZoneClassifier.classify(selected).rawValue
                            withAnimation(.spring(response: 0.25)) { zone = suggested }
                        }
                    )
                    .font(.system(size: 16)).foregroundStyle(session.themeTextColor)
                    .onChange(of: itemName) { _, name in
                        if !name.isEmpty { nameTouched = true }
                        guard name.count >= 2 else { return }
                        // The zone follows what you're adding (so a seasoning lands on
                        // Staples) rather than sticking to the last/viewed area. The user
                        // can still tap a different zone to override.
                        let suggested = ZoneClassifier.classify(name).rawValue
                        if zone != suggested {
                            withAnimation(.spring(response: 0.25)) { zone = suggested }
                        }
                    }
                }
                .padding(14)
                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                .overlay(
                    RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                        .stroke(showNameError ? Color.stockedGold : Color.clear, lineWidth: 1.5)
                )
                // Inline validation message — appears only once the user has typed then cleared
                // it, explaining why Continue is disabled instead of a dead button (#9).
                if showNameError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(Color.stockedGold)
                        Text("Give the item a name to continue")
                            .font(.system(size: 12)).foregroundStyle(Color.stockedGold)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .accessibilityElement(children: .combine)
                }
            }.padding(.horizontal, 24)
            .animation(.easeInOut(duration: 0.2), value: showNameError)

            // Zone tabs
            VStack(alignment: .leading, spacing: 8) {
                Text("STORED IN")
                    .font(.system(size: 10, weight: .bold)).tracking(1)
                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                HStack(spacing: 0) {
                    ForEach(zones, id: \.self) { z in
                        Button {
                            withAnimation(.spring(response: 0.25)) { zone = z }
                        } label: {
                            Text(z)
                                .font(.system(size: 13, weight: zone == z ? .bold : .medium, design: .serif))
                                .foregroundStyle(zone == z ? Color.stockedWhite : session.themeTextColor.opacity(0.6))
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(zone == z ? session.themeButtonColor : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            }.padding(.horizontal, 24)

            // Quantity
            VStack(alignment: .leading, spacing: 8) {
                Text("QUANTITY")
                    .font(.system(size: 10, weight: .bold)).tracking(1)
                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                // Natural-language amount: "6 cans of 8 oz", "half a bag of chips" — fills
                // the name (if empty), quantity, container, and per-container size below.
                NaturalQuantityField { parsed in
                    if itemName.trimmingCharacters(in: .whitespaces).isEmpty, !parsed.item.isEmpty {
                        itemName = parsed.item.capitalized
                    }
                    quantity = max(1, Int(parsed.count.rounded()))
                    if parsed.container != "item" { containerType = parsed.container }
                    if let amt = parsed.amountEach {
                        showSizeDetails = true
                        sizeAmount = ParsedAmount.trim(amt)
                        sizeUnit   = parsed.unitEach ?? sizeUnit
                    }
                }
                HStack(spacing: 0) {
                    Button { if quantity > 1 { withAnimation(.spring(response: 0.2)) { quantity -= 1 } } } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(session.themeTextColor)
                            .frame(width: 52, height: 46).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Text("\(quantity)")
                        .font(.system(size: 22, weight: .bold, design: .serif)).dynamicTypeSize(.xSmall ... .accessibility2)
                        .foregroundStyle(Color.stockedGold).frame(minWidth: 50)
                    Button { withAnimation(.spring(response: 0.2)) { quantity += 1 } } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(session.themeTextColor)
                            .frame(width: 52, height: 46).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            }.padding(.horizontal, 24)
            .task(id: itemName) {
                // Smart quantity/container defaults — only when the user hasn't set them.
                // Own history first (typical purchase of this exact item), crowd second.
                let name = itemName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, quantity == 1, containerType.isEmpty else { return }
                try? await Task.sleep(nanoseconds: 600_000_000)   // settle while typing
                guard !Task.isCancelled else { return }
                let mine = session.guestStore.inventoryItems.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                if let last = mine.last {
                    if quantity == 1 { quantity = max(1, last.quantity) }
                    if containerType.isEmpty, last.containerType != "item" { containerType = last.containerType }
                    return
                }
                if let s = await CrowdDB.suggest(name: name), s.count >= 3 {
                    if quantity == 1, let q = s.avgQuantity { quantity = max(1, Int(q.rounded())) }
                    if containerType.isEmpty, let c = s.topContainer, c != "item" { containerType = c }
                }
            }

            // Container type
            VStack(alignment: .leading, spacing: 8) {
                Text("CONTAINER TYPE")
                    .font(.system(size: 10, weight: .bold)).tracking(1)
                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                Menu {
                    ForEach(ContainerType.all, id: \.self) { c in
                        Button(c) { containerType = c }
                    }
                } label: {
                    HStack {
                        Text(containerType.isEmpty ? "Select container type" : containerType)
                            .font(.system(size: 15)).dynamicTypeSize(.xSmall ... .xxxLarge)
                            .foregroundStyle(containerType.isEmpty ? session.themeTextColor.opacity(0.35) : session.themeTextColor)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12))
                            .foregroundStyle(session.themeTextColor.opacity(0.35))
                    }
                    .padding(14)
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                }
            }.padding(.horizontal, 24)

            // Current amount — combined size + how-much-you-have slider ("6 of 12 eggs").
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("CURRENT AMOUNT")
                        .font(.system(size: 10, weight: .bold)).tracking(1)
                        .foregroundStyle(session.themeTextColor.opacity(0.4))
                    Spacer()
                    Toggle("", isOn: $hasAmount.animation(.spring(response: 0.25))).labelsHidden()
                        .tint(Color.stockedGold)
                }
                if hasAmount {
                    // Total size (how many a full one holds)
                    HStack(spacing: 10) {
                        Text("Holds")
                            .font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.7))
                        Button { if totalUnits > 1 { totalUnits -= 1; currentUnits = min(currentUnits, totalUnits) } } label: {
                            Image(systemName: "minus.circle").font(.system(size: 18)).foregroundStyle(session.themeTextColor.opacity(0.6))
                        }.buttonStyle(.plain)
                        Text("\(Int(totalUnits))")
                            .font(.system(size: 18, weight: .bold, design: .serif)).foregroundStyle(Color.stockedGold).frame(minWidth: 34)
                        Button { totalUnits += 1 } label: {
                            Image(systemName: "plus.circle").font(.system(size: 18)).foregroundStyle(session.themeTextColor.opacity(0.6))
                        }.buttonStyle(.plain)
                        Text(containerType.isEmpty ? "total" : "per \(containerType)")
                            .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.5))
                        Spacer()
                    }
                    // Current amount slider, shown as "X of Y"
                    VStack(alignment: .leading, spacing: 4) {
                        Text("You have \(Int(currentUnits)) of \(Int(totalUnits))")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(session.themeTextColor)
                        Slider(value: $currentUnits, in: 0...totalUnits, step: 1).tint(Color.stockedGold)
                    }
                }
            }.padding(.horizontal, 24)

            continueButton(enabled: !itemName.trimmingCharacters(in: .whitespaces).isEmpty) {
                let name = itemName.trimmingCharacters(in: .whitespaces).lowercased()
                // Duplicate check. The old logic used naive substring containment in BOTH
                // directions, so "milk" matched "Eggo Buttermilk Waffles" (buttermilk contains
                // milk) — a false positive. Now we match on canonical equality, or a whole-word
                // match, so a short name only collides with an item that actually shares that
                // word as a word, not as an incidental substring of a longer product name.
                let canonName = IngredientMatcher.canonical(name)
                let newWords = Set(name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
                if let match = session.guestStore.inventoryItems.first(where: {
                    let existing = $0.name.lowercased()
                    if existing == name { return true }
                    if IngredientMatcher.canonical(existing) == canonName { return true }
                    let existingWords = Set(existing.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
                    return !newWords.isEmpty && newWords == existingWords
                }) {
                    duplicateItem = match
                    showDuplicateAlert = true
                } else {
                    withAnimation { step = 2 }
                }
            }
            .alert("Already in Pantry", isPresented: $showDuplicateAlert, presenting: duplicateItem) { match in
                Button("Add Anyway") { withAnimation { step = 2 } }
                Button("Cancel", role: .cancel) {}
            } message: { match in
                Text("\"\(match.name)\" is already in your \(match.zone). Add another or cancel to update that item instead.")
            }
        }
    }

    // MARK: - Step 2: Size Details
    private var stepTwoContent: some View {
        VStack(spacing: 20) {
            // Summary row
            summaryRow

            // Toggle
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Add size details")
                            .font(.system(size: 15, weight: .medium, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Text("optional")
                            .font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.4))
                    }
                    Spacer()
                    Toggle("", isOn: $showSizeDetails.animation(.spring(response: StockedUI.animationMd)))
                        .tint(Color.stockedGold).labelsHidden()
                }
                .padding(16)
                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))

                if showSizeDetails {
                    VStack(spacing: 14) {
                        // Amount per container
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Amount per container")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(session.themeTextColor.opacity(0.55))
                            TextField("e.g. 16, 12, 1.5", text: $sizeAmount)
                                .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                                .font(.system(size: 15)).dynamicTypeSize(.xSmall ... .xxxLarge).foregroundStyle(session.themeTextColor)
                                .keyboardType(.decimalPad)
                                .padding(14)
                                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        }
                        // Measurement unit
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Measurement Unit")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(session.themeTextColor.opacity(0.55))
                            Menu {
                                ForEach(MeasurementUnit.all, id: \.self) { u in
                                    Button(u) { sizeUnit = u }
                                }
                            } label: {
                                HStack {
                                    Text(sizeUnit.isEmpty ? "Select unit" : sizeUnit)
                                        .font(.system(size: 15)).dynamicTypeSize(.xSmall ... .xxxLarge)
                                        .foregroundStyle(sizeUnit.isEmpty ? session.themeTextColor.opacity(0.35) : session.themeTextColor)
                                    Spacer()
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 12))
                                        .foregroundStyle(session.themeTextColor.opacity(0.35))
                                }
                                .padding(14)
                                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }.padding(.horizontal, 24)

            // Live preview
            if !itemName.isEmpty {
                previewBadge
            }

            HStack(spacing: 12) {
                backButton
                continueButton(enabled: true) {
                    withAnimation { step = 3 }
                }
            }.padding(.horizontal, 24)
        }
    }

    // MARK: - Step 3: Extras
    private var stepThreeContent: some View {
        VStack(spacing: 20) {
            summaryRow

            // Expiry
            VStack(alignment: .leading, spacing: 8) {
                Text("EXPIRES ON (optional)")
                    .font(.system(size: 10, weight: .bold)).tracking(1)
                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                ExpiryDateRow(hasExpiry: $hasExpiry, expiryDate: $expiryDate)
                    .padding(14)
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                    .onChange(of: hasExpiry) { _, on in
                        // Smart default: when expiry is switched on, pre-fill a sensible date
                        // based on where the item is stored, so the user confirms vs. types (#10).
                        guard on else { return }
                        let days: TimeInterval
                        switch zone {
                        case "Freezer": days = 90
                        case "Pantry":  days = 180
                        case "Staples": days = 365
                        default:        days = 7      // Fridge
                        }
                        expiryDate = Date().addingTimeInterval(days * 86400)
                    }
            }.padding(.horizontal, 24)

            if !itemName.isEmpty {
                previewBadge
            }

            HStack(spacing: 12) {
                backButton

                // Gold "Add to Zone" button
                Button {
                    let name = itemName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    // Derive the fill level from the current-amount control if used ("6 of 12" → 0.5).
                    let derivedLevel = (hasAmount && totalUnits > 0) ? max(0.0, min(1.0, currentUnits / totalUnits)) : 1.0
                    var item = LocalInventoryItem(
                        name: name, level: derivedLevel, zone: zone,
                        quantity: quantity,
                        containerType: containerType.isEmpty ? "item" : containerType,
                        sizeAmount: hasAmount ? totalUnits : Double(sizeAmount),
                        sizeUnit: sizeUnit.isEmpty ? nil : sizeUnit
                    )
                    item.expirationDate   = hasExpiry ? expiryDate : nil
                    item.storePurchasedAt = session.preferredStore
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    session.guestStore.addInventoryItem(item)
                    UsageMetrics.shared.record(.itemAddedManual)
                    // Crowd DB — opt-in anonymized report of item facts (fire and forget).
                    let rn = name, rc = zone, ru = sizeUnit, rct = item.containerType, rq = Double(quantity)
                    Task { await CrowdDB.report(items: [(name: rn, category: rc, unit: ru, container: rct, quantity: rq)]) }
                    ToastCenter.shared.success("Added \(name) to \(zone)")
                    dismiss()
                } label: {
                    Text("Add to \(zone)")
                        .font(.system(size: 16, weight: .bold, design: .serif))
                        .foregroundStyle(name.isEmpty ? Color.stockedWhite.opacity(0.5) : Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL)
                                .fill(itemName.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? Color.stockedGold.opacity(0.4)
                                    : Color.stockedGold)
                        )
                }
                .disabled(itemName.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.plain)
            }.padding(.horizontal, 24)
        }
    }

    // MARK: - Shared components
    private var summaryRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.stockedGold)
            VStack(alignment: .leading, spacing: 1) {
                Text(itemName.isEmpty ? "Item" : itemName)
                    .font(.system(size: 14, weight: .semibold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Text("\(quantity) \(containerType.isEmpty ? "item" : containerType) · \(zone)")
                    .font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.5))
            }
            Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.3))
    }

    private var previewBadge: some View {
        let preview: String = {
            let amt = Double(sizeAmount)
            let container = containerType.isEmpty ? "item" : containerType
            if showSizeDetails, let a = amt, !sizeAmount.isEmpty, !sizeUnit.isEmpty {
                return "\(quantity) \(container) (\(a.clean) \(sizeUnit) each) of \(itemName)"
            }
            return "\(quantity) \(container) of \(itemName)"
        }()
        return HStack(spacing: 8) {
            Text(preview).font(.system(size: 13, design: .serif))
                .foregroundStyle(session.themeTextColor.opacity(0.6))
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private var backButton: some View {
        Button {
            withAnimation { step -= 1 }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                Text("Back").font(.system(size: 15, weight: .semibold, design: .serif))
            }
            .foregroundStyle(session.themeTextColor)
            .padding(.vertical, 16).padding(.horizontal, 20)
            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
        }.buttonStyle(.plain)
    }

    private func continueButton(enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Continue")
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .foregroundStyle(enabled ? Color.stockedWhite : Color.stockedWhite.opacity(0.4))
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL)
                        .fill(enabled ? Color.stockedCharcoal : Color.stockedCharcoal.opacity(0.4))
                )
        }
        .disabled(!enabled)
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
    }

    // Computed property to avoid closure capture issue
    private var name: String { itemName.trimmingCharacters(in: .whitespaces) }
    // True once the user has interacted with the name field and left it empty (#9).
    private var showNameError: Bool { nameTouched && name.isEmpty }
}

// MARK: - Ingredient Browser Sheet (accessed via Browse button)
struct IngredientBrowserSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss

    var defaultZone: String = "Fridge"
    @State private var searchText      = ""
    @State private var selectedCategory: String? = nil
    @State private var recentlyAdded:  Set<String> = []
    @State private var detailEntry:    IngredientEntry? = nil
    @State private var detailQty:      Int    = 1
    @State private var detailUnit:     String = "items"
    @State private var detailNote:     String = ""
    @State private var detailHasExpiry: Bool  = false
    @State private var detailExpiry:   Date   = Date().addingTimeInterval(7*86400)

    private let kb = StockedKnowledgeBase.shared

    private var filteredItems: [KnowledgeIngredient] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            return kb.ingredients.filter { $0.name.searchMatches(q) }
        }
        if let cat = selectedCategory {
            return kb.ingredients.filter { $0.category == cat }
                .sorted { $0.name < $1.name }
        }
        return kb.ingredients.sorted { $0.name < $1.name }
    }
    private var categories: [String] {
        Array(Set(kb.ingredients.map(\.category))).sorted()
    }

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                Capsule().fill(Color.stockedCharcoal.opacity(0.2)).frame(width: 40, height: 4).padding(.top, 12)
                HStack {
                    Text("Browse Ingredients")
                        .font(.system(size: 22, weight: .bold, design: .serif)).dynamicTypeSize(.xSmall ... .accessibility2).foregroundStyle(session.themeTextColor)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 22))
                            .foregroundStyle(session.themeTextColor.opacity(0.3))
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 16)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(session.themeTextColor.opacity(0.4))
                    FoodPredictiveTextField(placeholder: "Search ingredients…", text: $searchText, onCommit: {})
                        .font(.system(size: 15)).dynamicTypeSize(.xSmall ... .xxxLarge).foregroundStyle(session.themeTextColor)
                }.padding(12).background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                 .padding(.horizontal, 24).padding(.bottom, 12)

                if searchText.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(categories, id: \.self) { cat in
                                Button {
                                    selectedCategory = selectedCategory == cat ? nil : cat
                                } label: {
                                    Text(cat)
                                        .font(.system(size: 12, weight: selectedCategory == cat ? .bold : .medium))
                                        .foregroundStyle(selectedCategory == cat ? Color.stockedWhite : session.themeTextColor.opacity(0.7))
                                        .padding(.horizontal, 12).padding(.vertical, 10)
                                        .background(selectedCategory == cat ? Color.stockedCharcoal : Color.stockedWhite.opacity(0.4))
                                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                                }.buttonStyle(.plain)
                            }
                        }
                        .stockedScrollTargetLayout().padding(.horizontal, 24).padding(.bottom, 12)
                    }
                    .stockedHorizontalSnap()
                }

                List {
                    ForEach(filteredItems) { ki in
                        browserRow(ki.asIngredientEntry)
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
        .sheet(item: $detailEntry) { entry in
            ItemDetailPopup(
                entry: entry, qty: $detailQty, unit: $detailUnit,
                note: $detailNote, hasExpiry: $detailHasExpiry, expiry: $detailExpiry,
                onAdd: { qty, unit, note, hasExp, expDate in
                    let zone = defaultZone
                    var item = LocalInventoryItem(name: entry.name, level: 1.0, zone: zone,
                                                   quantity: qty, containerType: unit)
                    item.expirationDate = hasExp ? expDate : nil
                    item.storePurchasedAt = session.preferredStore
                    if let topBrand = BrandDatabase.brands(for: entry.name).first {
                        item.brand = topBrand.brand; item.nutrition = topBrand.nutrition.toFacts()
                    }
                    session.guestStore.addInventoryItem(item)
                    session.guestStore.recordItemAdded(name: entry.name, zone: zone,
                                                       unit: unit, brand: item.brand ?? "")
                    recentlyAdded.insert(entry.name)
                    Task {
                        try? await Task.sleep(nanoseconds: 1400000000)
                        recentlyAdded.remove(entry.name)
                    }
                    detailEntry = nil
                }
            ).environment(session)
        }
    }

    private func browserRow(_ entry: IngredientEntry) -> some View {
        HStack(spacing: 14) {
            Text(itemIcon(for: entry)).font(.system(size: 26)).frame(width: 36)
            VStack(alignment: .leading, spacing: 10) {
                Text(entry.name).font(.system(size: 15, weight: .semibold)).dynamicTypeSize(.xSmall ... .xxxLarge).foregroundStyle(session.themeTextColor)
                Text(entry.category).font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.45))
            }
            Spacer()
            if recentlyAdded.contains(entry.name) {
                Label("Added!", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(Color.stockedGreen)
            } else {
                Button {
                    detailEntry = entry; detailQty = 1
                    detailUnit = defaultUnit(for: entry); detailNote = ""
                    detailHasExpiry = false
                    detailExpiry = Date().addingTimeInterval(7*86400)
                } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundStyle(Color.stockedGold)
                }.buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
        .listRowBackground(Color.clear)
    }

    private func itemIcon(for entry: IngredientEntry) -> String {
        // reuse same logic
        switch entry.category {
        case "Meats","Poultry": return "🥩"
        case "Seafood": return "🐟"
        case "Dairy": return "🥛"
        case "Produce": return "🥦"
        case "Bakery": return "🍞"
        case "Beverages": return "🧃"
        case "Snacks": return "🍪"
        case "Condiments": return "🫙"
        case "Freezer": return "🧊"
        default: return entry.emoji
        }
    }

    private func defaultUnit(for entry: IngredientEntry) -> String {
        switch entry.category {
        case "Meats","Poultry","Seafood": return "lb"
        case "Produce": return "g"
        case "Beverages": return "bottle"
        case "Dairy": return "carton"
        case "Bakery": return "loaf"
        default: return "item"
        }
    }
}

struct ExpiryDateRow: View {
    @Environment(AppSession.self) var session
    @Binding var hasExpiry:  Bool
    @Binding var expiryDate: Date
    @State private var mode: ExpiryMode = .useBy

    enum ExpiryMode: String, CaseIterable {
        case useBy     = "Use By"
        case expiresOn = "Expires On"
    }

    var body: some View {
        VStack(spacing: 10) {
            // Toggle row
            HStack(spacing: 0) {
                ForEach(ExpiryMode.allCases, id: \.self) { m in
                    Button {
                        withAnimation(.spring(response: 0.25)) {
                            mode = m
                            if !hasExpiry { hasExpiry = false }
                        }
                    } label: {
                        Text(m.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(mode == m ? Color.stockedCharcoal : Color.stockedCharcoal.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(mode == m ? Color.stockedGold : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                    }.buttonStyle(.plain)
                }
            }
            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))

            // Date picker row
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 15)).dynamicTypeSize(.xSmall ... .xxxLarge)
                    .foregroundStyle(Color.stockedGold)
                    .frame(width: 22)
                Text(mode.rawValue)
                    .font(.system(size: 14))
                    .foregroundStyle(session.themeTextColor)
                Spacer()
                if hasExpiry {
                    Button {
                        withAnimation(.spring(response: 0.25)) { hasExpiry = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15)).dynamicTypeSize(.xSmall ... .xxxLarge)
                            .foregroundStyle(session.themeTextColor.opacity(0.25))
                    }.buttonStyle(.plain)
                } else {
                    Text("Optional")
                        .font(.system(size: 11))
                        .foregroundStyle(session.themeTextColor.opacity(0.3))
                }
                DatePicker("", selection: $expiryDate, in: Date()..., displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .tint(Color.stockedGold)
                    .labelsHidden()
                    .onChange(of: expiryDate) { _, _ in hasExpiry = true }
            }
        }
    }
}

// MARK: - Item Detail Popup (shown when tapping + on any ingredient)
struct ItemDetailPopup: View {
    @Environment(AppSession.self) var session
    let entry:       IngredientEntry
    @Binding var qty:          Int
    @Binding var unit:         String      // containerType
    @Binding var note:         String
    @Binding var hasExpiry:    Bool
    @Binding var expiry:       Date
    let onAdd: (Int, String, String, Bool, Date) -> Void
    @Environment(\.dismiss) var dismiss

    // Size details
    @State private var sizeAmountInput: String = ""
    @State private var sizeUnit: String = "oz"
    @State private var showSizeDetails = false

    var previewText: String {
        let amt = Double(sizeAmountInput)
        if showSizeDetails, let a = amt, !sizeAmountInput.isEmpty {
            return "\(qty) \(unit) (\(a.clean) \(sizeUnit) each) of \(entry.name)"
        }
        return "\(qty) \(unit) of \(entry.name)"
    }

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                // Handle
                Capsule().fill(Color.stockedCharcoal.opacity(0.2))
                    .frame(width: 40, height: 4).padding(.top, 12)

                // Header
                HStack {
                    Text(entry.emoji).font(.system(size: 28))
                    VStack(alignment: .leading, spacing: 10) {
                        Text(entry.name)
                            .font(.system(size: 20, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Text(entry.category)
                            .font(.system(size: 12))
                            .foregroundStyle(session.themeTextColor.opacity(0.45))
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(session.themeTextColor.opacity(0.2))
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 20)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {

                        // ── QUANTITY ──────────────────────────────────────────
                        quantitySection

                        Divider().padding(.horizontal, 24)

                        // ── SIZE DETAILS (optional) ───────────────────────────
                        sizeDetailsSection

                        // ── LIVE PREVIEW ──────────────────────────────────────
                        HStack {
                            Image(systemName: "eye")
                                .font(.system(size: 11)).foregroundStyle(Color.stockedGold)
                            Text(previewText)
                                .font(.system(size: 13, design: .serif))
                                .foregroundStyle(session.themeTextColor.opacity(0.6))
                            Spacer()
                        }
                        .padding(.horizontal, 24)
                        .animation(.easeInOut(duration: 0.15), value: previewText)

                        Divider().padding(.horizontal, 24)

                        // ── EXPIRY ────────────────────────────────────────────
                        VStack(alignment: .leading, spacing: 8) {
                            Text("EXPIRY DATE")
                                .font(.system(size: 10, weight: .bold)).tracking(1)
                                .foregroundStyle(session.themeTextColor.opacity(0.4))
                            ExpiryDateRow(hasExpiry: $hasExpiry, expiryDate: $expiry)
                        }.padding(.horizontal, 24)

                        // ── ADD BUTTON ────────────────────────────────────────
                        Button {
                            onAdd(qty, unit, note, hasExpiry, expiry)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "plus.circle.fill")
                                Text(previewText)
                                    .lineLimit(1)
                            }
                            .font(.system(size: 15, weight: .semibold, design: .serif))
                            .foregroundStyle(Color.stockedWhite)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(session.themeButtonColor).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                        }
                        .padding(.horizontal, 24).padding(.bottom, 32)
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .dismissKeyboardOnTap()
        .keyboardDoneToolbar()
    }

    @ViewBuilder private var quantitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("QUANTITY")
                .font(.system(size: 10, weight: .bold)).tracking(1)
                .foregroundStyle(session.themeTextColor.opacity(0.4))

            HStack(spacing: 14) {
                // Stepper
                HStack(spacing: 0) {
                    Button {
                        withAnimation(.spring(response: 0.2)) { qty = max(1, qty - 1) }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(session.themeTextColor)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)

                    Text("\(qty)")
                        .font(.system(size: 22, weight: .bold, design: .serif)).dynamicTypeSize(.xSmall ... .accessibility2)
                        .foregroundStyle(Color.stockedGold).frame(minWidth: 40)

                    Button {
                        withAnimation(.spring(response: 0.2)) { qty += 1 }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(session.themeTextColor)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))

                // Container Type
                Menu {
                    ForEach(ContainerType.all, id: \.self) { c in
                        Button(c) { unit = c }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(unit)
                            .font(.system(size: 15, weight: .semibold)).dynamicTypeSize(.xSmall ... .xxxLarge)
                            .foregroundStyle(session.themeTextColor)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11))
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                }
                Spacer()
            }
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder private var sizeDetailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: StockedUI.animationMd)) { showSizeDetails.toggle() }
            } label: {
                HStack {
                    Text("SIZE DETAILS")
                        .font(.system(size: 10, weight: .bold)).tracking(1)
                        .foregroundStyle(session.themeTextColor.opacity(0.4))
                    Text("optional")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.stockedGold)
                    Spacer()
                    Image(systemName: showSizeDetails ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(session.themeTextColor.opacity(0.3))
                }
            }.buttonStyle(.plain)

            if showSizeDetails {
                HStack(spacing: 12) {
                    // Amount per container
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Amount per \(unit)")
                            .font(.system(size: 11))
                            .foregroundStyle(session.themeTextColor.opacity(0.5))
                        TextField("e.g. 24", text: $sizeAmountInput)
                        .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                            .font(.system(size: 15, weight: .semibold)).dynamicTypeSize(.xSmall ... .xxxLarge)
                            .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                            .keyboardType(.decimalPad)
                            .padding(10)
                            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                    }

                    // Measurement unit
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Unit")
                            .font(.system(size: 11))
                            .foregroundStyle(session.themeTextColor.opacity(0.5))
                        Menu {
                            ForEach(MeasurementUnit.all, id: \.self) { u in
                                Button(u) { sizeUnit = u }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(sizeUnit)
                                    .font(.system(size: 15, weight: .semibold)).dynamicTypeSize(.xSmall ... .xxxLarge)
                                    .foregroundStyle(session.themeTextColor)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10))
                                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                            }
                            .padding(10)
                            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Photo Picker wrapper (PHPicker)
struct ItemPhotoPicker: UIViewControllerRepresentable {
    @Binding var imageData: Data?
    @Environment(\.dismiss) var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ItemPhotoPicker
        init(_ parent: ItemPhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else { return }
            provider.loadObject(ofClass: UIImage.self) { image, _ in
                // Compress here (off-main) so only Sendable `Data` — never the non-Sendable
                // UIImage — crosses into the @MainActor task.
                let data = (image as? UIImage)?.jpegData(compressionQuality: 0.5)
                Task { @MainActor in self.parent.imageData = data }
            }
        }
    }
}

// MARK: - Ingredient Pairings Sheet
struct IngredientPairingsSheet: View {
    @Environment(AppSession.self) var session
    let itemName: String

    // Populated on appear from the prebuilt cooccurrence DB (RecipeStore), with the
    // curated fallback applied inside IngredientCooccurrence. Held in state so the
    // async warm-up can refresh the list once data-derived pairings load.
    @State private var pairList: [(name: String, inStock: Bool)] = []

    private func loadPairings() async {
        // Pull data-derived pairings from SQLite into the session cache first…
        await IngredientCooccurrence.shared.warm(for: itemName)
        // …then read the now-warmed (or curated-fallback) list synchronously.
        var pairs = IngredientCooccurrence.shared.pairings(for: itemName, limit: 10)
        // Crowd DB — blend community pairings in after local data (dedup, cap 12). Read-only
        // and anonymous; works whether or not the user opted into reporting.
        let crowd = await CrowdDB.pairings(name: itemName).map(\.0)
        for c in crowd where !pairs.contains(where: { $0.caseInsensitiveCompare(c) == .orderedSame }) {
            pairs.append(c.capitalized)
            if pairs.count >= 12 { break }
        }
        let pantry = Set(session.guestStore.inventoryItems.map { $0.name.lowercased() })
        pairList = pairs.map { (name: $0, inStock: pantry.contains($0.lowercased())) }
    }

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                Capsule().fill(Color.stockedCharcoal.opacity(0.2))
                    .frame(width: 40, height: 4).padding(.top, 12).padding(.bottom, 16)
                Text("Pairs well with \(itemName)")
                    .font(.system(size: 18, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                    .padding(.bottom, 20)

                if pairList.isEmpty {
                    Text("No pairing data for this item yet.")
                        .font(.system(size: 14))
                        .foregroundStyle(session.themeTextColor.opacity(0.45))
                        .padding(.top, 40)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 10) {
                            ForEach(pairList.sorted { $0.inStock && !$1.inStock }, id: \.name) { pair in
                                HStack(spacing: 14) {
                                    Image(systemName: pair.inStock ? "checkmark.circle.fill" : "circle.dashed")
                                        .font(.system(size: 20))
                                        .foregroundStyle(pair.inStock ? Color.stockedGold : session.themeTextColor.opacity(0.3))
                                    Text(pair.name)
                                        .font(.system(size: 15, design: .serif))
                                        .foregroundStyle(session.themeTextColor)
                                    Spacer()
                                    if pair.inStock {
                                        Text("In stock")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Color.stockedGold)
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
        .task { await loadPairings() }
    }
}

#Preview { InventoryView().environment(AppSession()) }

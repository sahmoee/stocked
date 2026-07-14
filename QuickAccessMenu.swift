// QuickAccessMenu.swift
// QuickAccessMenu has been removed. All settings now live in the Left Drawer (iPhone)
// and iPad Sidebar. Only QuickGrocerySheet and FontPickerSheet remain here.
import SwiftUI

// MARK: - Quick Grocery Sheet
struct QuickGrocerySheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    @State private var newItem = ""

    private var store: GuestDataStore { session.guestStore }
    private var needed: [LocalGroceryItem] { store.groceryItems.filter { !$0.isChecked } }
    private var done:   [LocalGroceryItem] { store.groceryItems.filter {  $0.isChecked } }

    var body: some View {
        StockedSheet(title: "Shopping List") {
            VStack(spacing: 0) {
                HStack {
                    Text("\(needed.count) item\(needed.count == 1 ? "" : "s") needed")
                        .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.45))
                    Spacer()
                }.padding(.horizontal, 24).padding(.vertical, 12)
                HStack(spacing: 10) {
                    TextField("Add item…", text: $newItem)
                    .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal).font(.system(size: 15)).foregroundStyle(session.themeTextColor).onSubmit { addItem() }
                    Button { addItem() } label: {
                        Image(systemName: "plus.circle.fill").font(.system(size: 24))
                            .foregroundStyle(newItem.isEmpty ? Color.stockedCharcoal.opacity(0.3) : Color.stockedGold)
                    }.disabled(newItem.isEmpty)
                }
                .padding(12).background(Color.stockedWhite.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                .padding(.horizontal, 20).padding(.bottom, 12)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        if needed.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 36)).foregroundStyle(Color.stockedGold)
                                Text("All items in stock!").font(.system(size: 15, design: .serif)).foregroundStyle(session.themeTextColor.opacity(0.55))
                            }.frame(maxWidth: .infinity).padding(.top, 40)
                        } else { ForEach(needed) { groceryRow($0) } }
                        if !done.isEmpty {
                            Text("Done (\(done.count))").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(session.themeTextColor.opacity(0.35))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 4)
                            ForEach(done) { groceryRow($0) }
                        }
                    }
                }
            }
        }.presentationDetents([.medium, .large])
    }
    private func addItem() {
        let n = newItem.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }
        store.addGroceryItem(name: n); newItem = ""
    }
    private func groceryRow(_ item: LocalGroceryItem) -> some View {
        HStack(spacing: 12) {
            Button { store.toggleGrocery(id: item.id) } label: {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundStyle(item.isChecked ? Color.stockedGold : Color.stockedCharcoal.opacity(0.4))
            }.buttonStyle(.plain)
            Text(item.name).font(.system(size: 15)).foregroundStyle(item.isChecked ? session.themeTextColor.opacity(0.35) : session.themeTextColor).strikethrough(item.isChecked)
            Spacer()
            Button { store.removeGrocery(id: item.id) } label: { Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.2)) }.buttonStyle(.plain)
        }
        .padding(.horizontal, 24).padding(.vertical, 10).contentShape(Rectangle())
    }
}

// MARK: - Font Picker Sheet
struct FontPickerSheet: View {
    @Environment(AppSession.self) var session
    @Binding var selectedFont: AppFont
    @Environment(\.dismiss) var dismiss

    let fontFamilies: [(category: String, fonts: [(name: String, uiName: String)])] = [
        ("Serif",     [("Georgia","Georgia"),("Times New Roman","TimesNewRomanPSMT"),("Baskerville","Baskerville"),("Didot","Didot")]),
        ("Sans-Serif",[("System Default",""),("Helvetica Neue","HelveticaNeue"),("Gill Sans","GillSans"),("Optima","Optima-Regular")]),
        ("Rounded",   [("System Rounded",""),("Avenir","Avenir-Medium"),("Verdana","Verdana")]),
        ("Monospace", [("Courier","Courier"),("Menlo","Menlo-Regular")]),
    ]

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                Capsule().fill(Color.stockedCharcoal.opacity(0.18)).frame(width: 40, height: 4).padding(.top, 12)
                HStack {
                    Text("Select Font").font(.system(size: 22, weight: .bold, design: .serif)).foregroundStyle(session.themeTextColor)
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 26)).foregroundStyle(session.themeTextColor.opacity(0.25)) }.buttonStyle(.plain)
                }.padding(.horizontal, 24).padding(.vertical, 14)
                HStack(spacing: 8) {
                    ForEach(AppFont.allCases, id: \.self) { f in
                        Button { withAnimation(.spring(response: 0.25)) { selectedFont = f } } label: {
                            Text(f.rawValue).font(.system(size: 13, weight: .semibold, design: f.design))
                                .foregroundStyle(selectedFont == f ? Color.stockedCharcoal : session.themeTextColor)
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(selectedFont == f ? Color.stockedGold : Color.stockedWhite.opacity(0.3))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 20).padding(.bottom, 16)
                Divider().padding(.horizontal, 20)
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(fontFamilies, id: \.category) { group in
                            Text(group.category.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1)
                                .foregroundStyle(session.themeTextColor.opacity(0.35))
                                .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 4)
                            ForEach(group.fonts, id: \.name) { entry in
                                HStack {
                                    Text("Stocked — \(entry.name)")
                                        .font(entry.uiName.isEmpty ? .system(size: 16) : .custom(entry.uiName, size: 16))
                                        .foregroundStyle(session.themeTextColor)
                                    Spacer()
                                    Text(entry.name).font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.4))
                                }
                                .padding(.horizontal, 24).padding(.vertical, 11)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if group.category == "Serif" { selectedFont = .serif }
                                    else if group.category == "Rounded" { selectedFont = .rounded }
                                    else if group.category == "Monospace" { selectedFont = .mono }
                                    else { selectedFont = .system }
                                    dismiss()
                                }
                                Divider().padding(.horizontal, 24)
                            }
                        }
                        Color.clear.frame(height: 40)
                    }
                }
            }
        }.presentationDetents([.large])
    }
}

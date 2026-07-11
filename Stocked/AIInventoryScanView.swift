// AIInventoryScanView.swift
// #FB4 — review UI for the AI Inventory Scan. Shows every proposed tidy-up
// (rename, re-zone, nutrition estimate, expiry estimate) as a toggleable card;
// nothing is applied until "Apply selected". Estimates are labeled as estimates.

import SwiftUI

struct AIInventoryScanView: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    @State var updates: [InventoryScanUpdate]

    private var confirmedCount: Int { updates.filter(\.isConfirmed).count }

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    Capsule().fill(Color.stockedCharcoal.opacity(0.2))
                        .frame(width: 40, height: 4)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10).padding(.bottom, 12)

                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Inventory Scan Results")
                                .font(.system(size: 18, weight: .bold, design: .serif))
                                .foregroundStyle(session.themeTextColor)
                            Text("\(updates.count) suggestion\(updates.count == 1 ? "" : "s") — uncheck anything you don't want. Nutrition and expiry values are AI estimates.")
                                .font(.system(size: 12))
                                .foregroundStyle(session.themeTextColor.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button(updates.allSatisfy(\.isConfirmed) ? "None" : "All") {
                            let target = !updates.allSatisfy(\.isConfirmed)
                            for i in updates.indices { updates[i].isConfirmed = target }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.stockedGold)
                    }
                    .padding(.horizontal, 20).padding(.bottom, 12)

                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 10) {   // perf: scan proposals are unbounded
                            ForEach($updates) { $update in
                                updateCard($update)
                            }
                        }
                        .padding(.horizontal, 18).padding(.bottom, 24)
                    }

                    Button {
                        let applied = session.guestStore.applyScanUpdates(updates)
                        ToastCenter.shared.success(applied == 0 ? "Nothing applied"
                                                   : "Updated \(applied) item\(applied == 1 ? "" : "s")")
                        dismiss()
                    } label: {
                        Text(confirmedCount == 0 ? "Nothing selected"
                             : "Apply \(confirmedCount) change\(confirmedCount == 1 ? "" : "s")")
                            .font(.system(size: 16, weight: .semibold, design: .serif))
                            .foregroundStyle(Color.stockedWhite)
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(confirmedCount == 0 ? Color.stockedCharcoal.opacity(0.35)
                                        : session.themeButtonColor)
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                    }
                    .buttonStyle(.plain)
                    .disabled(confirmedCount == 0)
                    .padding(.horizontal, 18).padding(.bottom, 6)

                    Button { dismiss() } label: {
                        Text("Cancel")
                            .font(.system(size: 14))
                            .foregroundStyle(session.themeTextColor.opacity(0.45))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 14)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.large])
    }

    private func updateCard(_ update: Binding<InventoryScanUpdate>) -> some View {
        let u = update.wrappedValue
        return Button {
            withAnimation(.spring(response: 0.2)) { update.wrappedValue.isConfirmed.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: u.isConfirmed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(u.isConfirmed ? Color.stockedGold : session.themeTextColor.opacity(0.3))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        FoodIconView(name: u.currentName, size: 22, emojiSize: 14)
                        Text(u.currentName.displayNormalized)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(session.themeTextColor)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    ForEach(Array(u.effectLines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 6) {
                            Circle().fill(Color.stockedGold.opacity(0.7))
                                .frame(width: 5, height: 5).padding(.top, 5)
                            Text(line)
                                .font(.system(size: 12.5))
                                .foregroundStyle(session.themeTextColor.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    if !u.reason.isEmpty {
                        Text(u.reason)
                            .font(.system(size: 11.5))
                            .foregroundStyle(session.themeTextColor.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            .opacity(u.isConfirmed ? 1 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        }
        .buttonStyle(.plain)
    }
}

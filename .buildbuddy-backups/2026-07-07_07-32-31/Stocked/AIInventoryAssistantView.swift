// AIInventoryAssistantView.swift
//
// Lets the user change their inventory in plain language: "I used the rest of the broccoli",
// "set the milk to half", "I bought 3 cans of beans", or "clear all my inventory". The request is
// sent to the Worker (the existing intent path), which proposes changes; the user reviews and
// confirms them in the shared ReconcileSheet before anything is applied. Nothing is changed
// without confirmation, and clearing all is restorable via the toast the reconcile flow shows.

import SwiftUI

struct AIInventoryAssistantView: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    @Environment(\.stockedDismiss) var stockedDismiss
    private func close() { if let stockedDismiss { stockedDismiss() } else { dismiss() } }

    @State private var request: String = ""
    @State private var parser = InventoryIntentParser()
    @State private var proposed: [ProposedChange]? = nil
    @State private var showReconcile = false
    @State private var noChanges = false
    @FocusState private var focused: Bool

    private var ink: Color { session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal }
    private var fieldBg: Color { session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.45) }

    private let examples = [
        "I used the rest of the broccoli",
        "Set the milk to half",
        "I bought 3 cans of beans",
        "Clear all my inventory"
    ]

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        field
                        if let err = parser.lastError {
                            Text(err).font(.system(size: 13)).foregroundStyle(.orange)
                        }
                        if noChanges {
                            Text("Couldn't find anything to change from that. Try naming an item you have.")
                                .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.55))
                        }
                        examplesBlock
                        askButton
                        if !InventoryIntentParser.isAvailable {
                            Text("This needs an internet connection and the recipe service set up.")
                                .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.45))
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
                }
            }
        }
        .onAppear { focused = true }
        .sheet(isPresented: $showReconcile) {
            if let proposed {
                ReconcileSheet(
                    title: "Review Changes",
                    subtitle: "Confirm what should change in your inventory. Nothing is applied until you tap Apply.",
                    changes: proposed,
                    onApply: { _ in close() }
                ).environment(session)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Inventory Assistant")
                    .font(.stockedSerif(24, weight: .bold))
                    .foregroundStyle(session.themeTextColor)
                Text("Tell me what changed, in plain words.")
                    .font(.system(size: 12.5)).foregroundStyle(session.themeTextColor.opacity(0.55))
            }
            Spacer()
            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(session.themeTextColor.opacity(0.6))
                    .frame(width: 30, height: 30)
                    .background((session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal).opacity(0.08))
                    .clipShape(Circle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.top, StockedScreen.safeTopInset + 6).padding(.bottom, 12)
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What changed?")
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(session.themeTextColor.opacity(0.5))
            TextField("e.g. I finished the eggs and used half the butter", text: $request, axis: .vertical)
                .lineLimit(2...4)
                .font(.system(size: 15)).foregroundStyle(ink)
                .focused($focused)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(fieldBg))
        }
    }

    private var examplesBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Examples")
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(session.themeTextColor.opacity(0.5))
            ForEach(examples, id: \.self) { ex in
                Button { request = ex } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "text.bubble").font(.system(size: 12)).foregroundStyle(Color.stockedGold)
                        Text(ex).font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.7))
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9).padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(fieldBg))
                }.buttonStyle(.plain)
            }
        }
    }

    private var askButton: some View {
        Button {
            Task { await ask() }
        } label: {
            HStack(spacing: 8) {
                if parser.isParsing {
                    ProgressView().tint(Color.stockedWhite)
                    Text("Reading…")
                } else {
                    Image(systemName: "sparkles")
                    Text("Review Changes")
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.stockedWhite)
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .background(Color.stockedGold.opacity(canAsk ? 1 : 0.4))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!canAsk || parser.isParsing)
        .padding(.top, 4)
    }

    private var canAsk: Bool {
        request.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 && InventoryIntentParser.isAvailable
    }

    private func ask() async {
        noChanges = false
        focused = false
        let changes = await parser.parse(request, store: session.guestStore)
        guard let changes else { return }          // parser.lastError is shown
        if changes.isEmpty {
            noChanges = true
            return
        }
        proposed = changes
        showReconcile = true
    }
}

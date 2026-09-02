//
//  CookingSessionSummaryView.swift
//  Stocked
//
//  Post-cook recap. The spec's final acceptance criteria require that finishing
//  ONE component (an entrée with no sides, a single prepped item) counts as a
//  fully successful session. This view honors that: it celebrates whatever level
//  the user completed, never implies an entrée without sides is "incomplete",
//  and surfaces the natural next actions (serve, save, add sides — all optional).
//
//  Reads the finished CookNowSession from the environment. Matches the existing
//  Stocked visual language (serif headers, gold/green accents, theme colors).
//

import SwiftUI

struct CookingSessionSummaryView: View {
    @Environment(AppSession.self) var session
    @Environment(CookNowSession.self) private var cookSession: CookNowSession?
    @Environment(\.dismiss) private var dismiss

    /// Optional explicit completion override (used by previews/tests). When nil,
    /// the value is read from the active session.
    var completionOverride: CookCompletionType? = nil
    /// Optional explicit anchor/preparation for previews.
    var anchorOverride: String? = nil
    var sidesOverride: [String]? = nil

    private var completion: CookCompletionType {
        completionOverride ?? cookSession?.completionType ?? .entreeCompleted
    }
    private var anchorTitle: String {
        anchorOverride ?? cookSession?.preparationTitle ?? cookSession?.anchorItem ?? "Your cooking"
    }
    private var sides: [String] {
        sidesOverride ?? cookSession?.selectedSideTitles ?? []
    }

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    affirmation
                    if !sides.isEmpty { sidesSection }
                    nextActions
                    Spacer(minLength: 8)
                }
                .padding(20)
            }
        }
        .navigationTitle("Nice work")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: completion.isSuccessful ? "checkmark.seal.fill" : "pause.circle.fill")
                    .scaledFont(26)
                    .foregroundStyle(completion.isSuccessful ? Color.stockedGreen : Color.stockedGold)
                Text(completion.isSuccessful ? "Done" : "Paused")
                    .scaledFont(26, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
            }
            Text(anchorTitle.displayNormalized)
                .scaledFont(16, weight: .semibold)
                .foregroundStyle(session.themeTextColor.opacity(0.75))
            Text(completion.summaryLabel)
                .scaledFont(12.5, weight: .semibold)
                .foregroundStyle(Color.stockedGold)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.stockedGold.opacity(0.12))
                .clipShape(Capsule())
        }
    }

    /// The nonjudgmental line — cooking one thing is a complete session.
    private var affirmation: some View {
        Text(affirmationText)
            .scaledFont(14)
            .foregroundStyle(session.themeTextColor.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var affirmationText: String {
        switch completion {
        case .ingredientPrepared: return "That component is ready to use whenever you need it. Prepping ahead counts — this was a complete session."
        case .entreeCompleted:    return "The entrée is done, and that's enough. Add something only if you feel like it."
        case .sideCompleted:      return "Side's ready. Nice and simple."
        case .componentCompleted: return "One component down and stored. That's a real win on its own."
        case .mealCompleted:      return "A full meal, start to finish. Well done."
        case .cookedForLater:     return "Cooked ahead and set aside. It'll be waiting under Finish & Serve when you're ready."
        case .partiallyCompleted: return "You got the important part done. The rest can wait for later."
        case .stoppedEarly:       return "Saved right where you left off. Come back whenever you like."
        }
    }

    private var sidesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Also made")
                .scaledFont(13, weight: .bold)
                .foregroundStyle(session.themeTextColor.opacity(0.5))
            ForEach(sides, id: \.self) { s in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").scaledFont(14).foregroundStyle(Color.stockedGreen)
                    Text(s).scaledFont(14).foregroundStyle(session.themeTextColor)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(session.themeTextColor.opacity(0.04)))
    }

    private var nextActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What now?")
                .scaledFont(13, weight: .bold)
                .foregroundStyle(session.themeTextColor.opacity(0.5))
            actionRow("fork.knife", "Serve it now")
            actionRow("refrigerator", "Save for later")
            actionRow("takeoutbag.and.cup.and.straw", "Portion for meal prep")
            actionRow("plus.circle", "Add a side")   // optional, never required
        }
    }

    private func actionRow(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).scaledFont(16).foregroundStyle(Color.stockedGold).frame(width: 24)
            Text(title).scaledFont(14.5, weight: .semibold).foregroundStyle(session.themeTextColor)
            Spacer()
            Image(systemName: "chevron.right").scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.3))
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(session.themeTextColor.opacity(0.04)))
    }
}

// DailyBriefOverlay.swift
// DEPRECATED — all functionality moved to QuickAccessMenu.swift.
// This file can be deleted from your project.
import SwiftUI

#Preview("Deprecated") {
    ZStack {
        Color.stockedBg.ignoresSafeArea()
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .scaledFont(36).foregroundStyle(Color.stockedGold)
            Text("DailyBriefOverlay").scaledFont(18, weight: .bold, design: .serif)
                .foregroundStyle(.primary)
            Text("Merged into QuickAccessMenu.swift")
                .scaledFont(13).foregroundStyle(Color.stockedCharcoal.opacity(0.5))
        }
    }
}

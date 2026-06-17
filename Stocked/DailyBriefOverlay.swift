// DailyBriefOverlay.swift
// DEPRECATED — all functionality moved to QuickAccessMenu.swift.
// This file can be deleted from your project.
import SwiftUI

#Preview("Deprecated") {
    ZStack {
        Color.stockedBg.ignoresSafeArea()
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 36)).foregroundStyle(Color.stockedGold)
            Text("DailyBriefOverlay").font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundStyle(.primary)
            Text("Merged into QuickAccessMenu.swift")
                .font(.system(size: 13)).foregroundStyle(Color.stockedCharcoal.opacity(0.5))
        }
    }
}

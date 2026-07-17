// TabBarView.swift — Flat bottom tab bar (5 tabs, icon over label).
// Active tab: gold. Inactive: dimmed theme text. Sits flat on the app background.
//
// Four tabs use SF Symbols (Home, Inventory, Recipes, Grocery). The Cook tab has no
// SF Symbol for a chef's hat, so it draws a custom toque — normalised to match the
// SF Symbols' optical size and baseline.
import SwiftUI

enum StockedTab: String, CaseIterable {
    case home      = "Home"
    case cook      = "Cook"
    case inventory = "Inventory"
    case recipes   = "Recipes"
    case grocery   = "Grocery List"

    var icon: String {
        switch self {
        case .home:      return "house"
        case .cook:      return "frying.pan"        // fallback only; Cook draws the toque below
        case .inventory: return "archivebox"
        case .recipes:   return "fork.knife"
        case .grocery:   return "cart"
        }
    }
    var iconFilled: String {
        switch self {
        case .home:      return "house.fill"
        case .cook:      return "frying.pan.fill"
        case .inventory: return "archivebox.fill"
        case .recipes:   return "fork.knife"
        case .grocery:   return "cart.fill"
        }
    }
    var label: String { rawValue }
}

// MARK: - Cook (chef's toque)
// Drawn in a raw 24×24 design space, then uniformly scaled + centred so it reads at the
// same optical size as the SF Symbol icons and sits on the same baseline.
nonisolated private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

nonisolated private func addRRect(_ path: inout Path, _ x0: CGFloat, _ x1: CGFloat,
                      _ y0: CGFloat, _ y1: CGFloat, _ r: CGFloat) {
    path.move(to: p(x0 + r, y0)); path.addLine(to: p(x1 - r, y0))
    path.addQuadCurve(to: p(x1, y0 + r), control: p(x1, y0))
    path.addLine(to: p(x1, y1 - r))
    path.addQuadCurve(to: p(x1 - r, y1), control: p(x1, y1))
    path.addLine(to: p(x0 + r, y1))
    path.addQuadCurve(to: p(x0, y1 - r), control: p(x0, y1))
    path.addLine(to: p(x0, y0 + r))
    path.addQuadCurve(to: p(x0 + r, y0), control: p(x0, y0))
}

struct ChefHatShape: Shape {
    func path(in rect: CGRect) -> Path {
        var raw = Path()
        // Billowy crown.
        raw.move(to: p(5.4, 17.6))
        raw.addCurve(to: p(1.4, 8.8),  control1: p(1.2, 16.3), control2: p(0.2, 11.8))
        raw.addCurve(to: p(9.0, 5.0),  control1: p(2.8, 4.6),  control2: p(7.2, 2.6))
        raw.addCurve(to: p(15.0, 5.0), control1: p(9.9, 1.2),  control2: p(14.1, 1.2))
        raw.addCurve(to: p(22.6, 8.8), control1: p(16.8, 2.6), control2: p(21.2, 4.6))
        raw.addCurve(to: p(18.6, 17.6),control1: p(23.8, 11.8),control2: p(22.8, 16.3))
        // Band.
        addRRect(&raw, 5.4, 18.6, 17.6, 23.6, 1.1)
        // Pleats.
        raw.move(to: p(9.0, 17.6))
        raw.addCurve(to: p(10.2, 13.2), control1: p(9.2, 15.6), control2: p(9.6, 14.2))
        raw.move(to: p(12.0, 17.6)); raw.addLine(to: p(12.0, 13.0))
        raw.move(to: p(15.0, 17.6))
        raw.addCurve(to: p(13.8, 13.2), control1: p(14.8, 15.6), control2: p(14.4, 14.2))

        // Normalise: scale the artwork's bounding box to ~79% of the frame, centred.
        let b = raw.boundingRect
        guard b.width > 0, b.height > 0 else { return raw }
        let target = min(rect.width, rect.height) * (19.0 / 24.0)
        let scale  = target / max(b.width, b.height)
        let tx = rect.midX - b.midX * scale
        let ty = rect.midY - b.midY * scale
        let t = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
        return raw.applying(t)
    }
}

struct StockedTabBar: View {
    @Environment(AppSession.self) var session
    @Binding var selected: StockedTab
    var onTap:     ((StockedTab) -> Void)? = nil  // called on every tap (overrides default)
    var onSameTap: (() -> Void)? = nil            // called when tapping current tab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(StockedTab.allCases, id: \.self) { tab in
                    tabCell(tab)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
        // Flat bar that sits directly on the app background (no dark pill), matching
        // the mockup. A hairline top divider separates it from content.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(session.themeTextColor.opacity(0.08))
                .frame(height: 1)
        }
        .background(session.themeBgColor.ignoresSafeArea(edges: .bottom))
    }

    @ViewBuilder
    private func tabCell(_ tab: StockedTab) -> some View {
        let isActive = selected == tab

        Button {
            if let handler = onTap {
                handler(tab)              // delegate all navigation to MainTabView.navigate(to:)
            } else if selected == tab {
                onSameTap?()
            } else {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                    selected = tab
                }
            }
        } label: {
            VStack(spacing: 4) {
                // Fixed-height icon slot keeps every icon centred on the same line.
                Group {
                    if tab == .cook {
                        ChefHatShape()
                            .stroke(style: StrokeStyle(lineWidth: isActive ? 1.7 : 1.4,
                                                       lineCap: .round, lineJoin: .round))
                            .frame(width: 22, height: 22)
                    } else if tab == .home {
                        // Home uses the filled house when active, outline when not.
                        Image(systemName: isActive ? tab.iconFilled : tab.icon)
                            .font(.system(size: 17, weight: isActive ? .semibold : .regular))
                    } else {
                        Image(systemName: tab.icon)
                            .font(.system(size: 17, weight: isActive ? .semibold : .regular))
                    }
                }
                .frame(height: 26)
                .foregroundStyle(isActive ? Color.stockedGold : session.themeTextColor.opacity(0.7))

                Text(tab.rawValue)
                    .font(.system(size: 9, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Color.stockedGold : session.themeTextColor.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // #6 — VoiceOver: the icons (esp. the custom chef hat) have no inherent label.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.rawValue)
        .accessibilityHint("Opens the \(tab.rawValue) tab")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    let session = AppSession()
    return ZStack(alignment: .bottom) {
        session.themeBgColor.ignoresSafeArea()
        StockedTabBar(selected: .constant(.home))
            .padding(.bottom, 24)
    }.environment(session)
}

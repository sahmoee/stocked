// QAWorkbookTheme.swift — self-contained paper theme + components for the QA
// Workbook overlay. Kept separate from the app's own theme so the workbook keeps
// its warm-paper look (cream / tan / brown, serif titles) exactly like the PDF.

import SwiftUI

enum QATheme {
    // Palette (sampled from the workbook PDF).
    static let page      = Color(red: 0.929, green: 0.902, blue: 0.839) // #EDE6D6
    static let card      = Color(red: 0.969, green: 0.949, blue: 0.910) // #F7F2E8
    static let tan       = Color(red: 0.867, green: 0.804, blue: 0.706) // #DDCDB4
    static let headerTan = Color(red: 0.859, green: 0.796, blue: 0.698) // #DBCBB2
    static let brown     = Color(red: 0.541, green: 0.427, blue: 0.310) // #8A6D4F
    static let ink       = Color(red: 0.239, green: 0.204, blue: 0.157) // #3D3428
    static let accent    = Color(red: 0.608, green: 0.482, blue: 0.357) // #9B7B5B
    static let underline = Color(red: 0.788, green: 0.718, blue: 0.604) // #C9B79A

    static let pass   = Color(red: 0.306, green: 0.478, blue: 0.306)
    static let fail   = Color(red: 0.698, green: 0.333, blue: 0.286)
    static let review = Color(red: 0.780, green: 0.604, blue: 0.243)
    static let na     = Color(red: 0.604, green: 0.565, blue: 0.494)

    static func markColor(_ m: QAMark) -> Color {
        switch m { case .pass: return pass; case .fail: return fail; case .review: return review; case .na: return na; case .none: return brown.opacity(0.35) }
    }

    // Fonts — serif titles like the workbook, sans body.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { .system(size: size, weight: weight, design: .serif) }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
}

extension View {
    /// Force the warm paper look on every QA screen — including NavigationStack
    /// destinations, which don't inherit the panel's background and would otherwise
    /// show the app's dark chrome (dark text on black) in dark mode.
    func qaScreen() -> some View {
        self
            .background(QATheme.page.ignoresSafeArea())
            .toolbarBackground(QATheme.headerTan, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .environment(\.colorScheme, .light)
            .tint(QATheme.brown)
    }
}

// A rounded paper card.
struct QACard<Content: View>: View {
    var fill: Color = QATheme.card
    var outlined: Bool = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .background(RoundedRectangle(cornerRadius: 18).fill(fill))
            .overlay(outlined ? RoundedRectangle(cornerRadius: 18).stroke(QATheme.brown.opacity(0.25), lineWidth: 1) : nil)
    }
}

// Section label ("PURPOSE", "CHECKLIST", …).
struct QALabel: View {
    let text: String
    var body: some View {
        Text(text).font(QATheme.sans(11, .bold)).tracking(0.6)
            .foregroundStyle(QATheme.ink.opacity(0.7))
    }
}

// The four-state marking control (Pass / Fail / Review / N/A).
struct QAMarkPicker: View {
    let mark: QAMark
    let onPick: (QAMark) -> Void
    var body: some View {
        HStack(spacing: 6) {
            chip(.pass, "P"); chip(.fail, "F"); chip(.review, "R"); chip(.na, "N")
        }
    }
    private func chip(_ m: QAMark, _ letter: String) -> some View {
        Button { onPick(m) } label: {
            Text(letter)
                .font(QATheme.sans(12, .bold))
                .frame(width: 26, height: 26)
                .foregroundStyle(mark == m ? Color.white : QATheme.ink.opacity(0.6))
                .background(RoundedRectangle(cornerRadius: 7).fill(mark == m ? QATheme.markColor(m) : QATheme.tan.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }
}

// A written-on underline field (ticket / quick note / resume).
struct QAUnderlineField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = nil
    var body: some View {
        TextField(placeholder, text: $text)
            .font(QATheme.sans(13))
            .foregroundStyle(QATheme.ink)
            .frame(width: width)
            .padding(.bottom, 3)
            .overlay(Rectangle().fill(QATheme.underline).frame(height: 1), alignment: .bottom)
    }
}

// Collapsible plain-language helper ("ELI5") for concepts that aren't self-explanatory.
struct QAExplainer: View {
    let text: String
    var label: String = "ELI5"
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "questionmark.circle.fill").font(.system(size: 12))
                    Text(label).font(QATheme.sans(11, .bold))
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                }.foregroundStyle(QATheme.accent)
            }.buttonStyle(.plain)
            if open {
                Text(text).font(QATheme.sans(12)).foregroundStyle(QATheme.ink.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(QATheme.card))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(QATheme.accent.opacity(0.25)))
            }
        }
    }
}

// Small progress bar for section progress.
struct QAProgressBar: View {
    let value: Double   // 0…1
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(QATheme.tan.opacity(0.6))
                Capsule().fill(QATheme.brown).frame(width: max(6, geo.size.width * value))
            }
        }
        .frame(height: 8)
    }
}

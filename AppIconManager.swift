// AppIconManager.swift — alternate app-icon switching + drawer picker.
//
// The 16 alternate icons ship as loose PNGs in the app bundle (AppIcon-01…16,
// plus @2x/@3x), registered under CFBundleIcons/CFBundleAlternateIcons in
// Info.plist. iOS swaps the home-screen icon via setAlternateIconName(_:);
// passing nil restores the asset-catalog primary.
//
// Picker thumbnails load the same bundle PNGs with UIImage(named:), so no
// separate asset-catalog thumbnail set is needed.
import SwiftUI
import UIKit

@MainActor
enum AppIconManager {

    /// Number of alternate icons shipped. Keys must match CFBundleAlternateIcons.
    static let count = 16

    /// Alternate icon keys ("Icon01"…"Icon16") — the Info.plist dictionary keys.
    static let keys: [String] = (1...count).map { String(format: "Icon%02d", $0) }

    /// The bundle file base name for a given 1-based index ("AppIcon-01").
    static func fileName(for index: Int) -> String { String(format: "AppIcon-%02d", index) }

    /// The alternate-icon key for a given 1-based index ("Icon01").
    static func key(for index: Int) -> String { String(format: "Icon%02d", index) }

    /// Whether the device supports alternate icons (false on some iPads / older setups).
    static var isSupported: Bool { UIApplication.shared.supportsAlternateIcons }

    /// The currently active alternate key, or nil when the primary icon is set.
    static var current: String? { UIApplication.shared.alternateIconName }

    /// Set an alternate icon by key, or nil to restore the default. No-ops if the
    /// requested icon is already active (avoids the system alert firing twice).
    @discardableResult
    static func set(_ key: String?) async -> Bool {
        guard isSupported else { return false }
        guard key != UIApplication.shared.alternateIconName else { return true }
        do {
            try await UIApplication.shared.setAlternateIconName(key)
            return true
        } catch {
            // Non-fatal: an unknown name or unsupported device. Keep the current icon.
            print("AppIconManager: setAlternateIconName failed — \(error.localizedDescription)")
            return false
        }
    }

    /// Thumbnail for the picker. Loads the loose bundle PNG; falls back to the
    /// asset-catalog primary preview for the "default" cell.
    static func thumbnail(for index: Int) -> UIImage? {
        UIImage(named: fileName(for: index))
    }
}

// MARK: - Drawer picker

/// A grid of app-icon options. The first cell restores the default (asset-catalog)
/// icon; the rest set alternates. Selection updates live and persists via iOS.
struct AppIconPickerView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var selected: String? = AppIconManager.current
    @State private var working = false

    private let columns = [GridItem(.adaptive(minimum: 78), spacing: 14)]

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Choose an icon for Stocked. It updates on your Home Screen right away.")
                        .font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .padding(.horizontal, 20).padding(.top, 8)

                    if !AppIconManager.isSupported {
                        Text("Alternate icons aren't available on this device.")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(session.themeTextColor.opacity(0.7))
                            .padding(.horizontal, 20)
                    }

                    LazyVGrid(columns: columns, spacing: 14) {
                        // Default (primary) icon cell.
                        cell(key: nil, thumb: UIImage(named: "AppIcon-1024px") ?? AppIconManager.thumbnail(for: 1), label: "Default")
                        // Alternates.
                        ForEach(1...AppIconManager.count, id: \.self) { i in
                            cell(key: AppIconManager.key(for: i),
                                 thumb: AppIconManager.thumbnail(for: i),
                                 label: "\(i)")
                        }
                    }
                    .padding(.horizontal, 20)
                    Color.clear.frame(height: 30)
                }
            }
        }
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
    }

    private func cell(key: String?, thumb: UIImage?, label: String) -> some View {
        Button {
            guard !working else { return }
            working = true
            Task {
                let ok = await AppIconManager.set(key)
                if ok { selected = key; HapticManager.light() }
                working = false
            }
        } label: {
            VStack(spacing: 6) {
                Group {
                    if let thumb {
                        Image(uiImage: thumb).resizable().scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(session.themeTextColor.opacity(0.08))
                    }
                }
                .frame(width: 66, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(selected == key ? Color.stockedGold : Color.clear, lineWidth: 3)
                )
                .overlay(alignment: .bottomTrailing) {
                    if selected == key {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.stockedGold)
                            .background(Circle().fill(Color.white).frame(width: 16, height: 16))
                            .offset(x: 4, y: 4)
                    }
                }
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(session.themeTextColor.opacity(0.5))
            }
        }
        .buttonStyle(.plain)
        .disabled(!AppIconManager.isSupported)
        .a11yButton(key == nil ? "Default app icon" : "App icon \(label)")
    }
}

// ShareHelpers.swift
// Helper types for data export (#46) and share sheet presentation

import SwiftUI
import UIKit

// MARK: - ShareActivityItem (Identifiable wrapper for sheet presentation)
struct ShareActivityItem: Identifiable {
    let id    = UUID()
    let url: URL?
    init(data: URL?) { self.url = data }
}

// MARK: - ShareSheet (UIActivityViewController wrapper)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any?]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let filtered = items.compactMap { $0 }
        let vc = UIActivityViewController(activityItems: filtered, applicationActivities: nil)
        return vc
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

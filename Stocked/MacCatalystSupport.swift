// MacCatalystSupport.swift — everything Stocked needs to feel like a real Mac app.
//
// Stocked ships to macOS via MAC CATALYST: the same target, same code, same data
// layer. Enabling the destination is a checkbox in Xcode (see MAC_APP_SETUP.md);
// this file is the code half — window behavior, pointer polish, and the few
// platform facts other files may want to branch on.
//
// WHAT ALREADY JUST WORKS ON THE MAC (verified in the Catalyst audit):
//   • Every screen: UIDevice idiom reports .pad under Catalyst, so the Mac gets
//     the iPad layout (native TabView + drawer) with no changes.
//   • Sync: household Worker sync, iCloud/CloudKit, offline queue — identical.
//   • Recipes: add/edit/import (web, social links, share sheet), AI generation,
//     images via PhotosPicker (browses the Mac photo library and files).
//   • Household editing, grocery, planner, Cook Later/Now, QA system, notifications.
//   • Barcode/receipt capture: AVCapture works with the built-in/Continuity camera;
//     the photo-library and manual paths cover Macs with no camera.
//   • Live Activities: ActivityKit compiles; areActivitiesEnabled is false on
//     macOS and LiveActivityManager already no-ops on that flag.
//   • Haptics: UIKit feedback generators are silent no-ops on the Mac.

import SwiftUI

/// Platform facts, usable from any file without sprinkling #if everywhere.
nonisolated enum StockedPlatform {
    /// True when running as a Mac app (Catalyst).
    static var isMac: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }
}

#if targetEnvironment(macCatalyst)
@MainActor
enum MacWindowSupport {

    /// Call once the UI is up (RootView.onAppear). Sets a sane minimum window so
    /// the iPad layout never collapses, allows full free resize above it, and
    /// merges the title bar into the content for an edge-to-edge look that
    /// matches the app's custom header.
    static func configureWindows() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            windowScene.sizeRestrictions?.minimumSize = CGSize(width: 1000, height: 700)
            windowScene.sizeRestrictions?.allowsFullScreen = true
            if let titlebar = windowScene.titlebar {
                titlebar.titleVisibility = .hidden
                titlebar.toolbar = nil
            }
        }
    }
}
#endif

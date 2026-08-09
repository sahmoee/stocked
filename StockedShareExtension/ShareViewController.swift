// ShareViewController.swift
// ─────────────────────────────────────────────────────────────────────────────
// Stocked. Share Extension — lets the user share a recipe from Instagram / TikTok /
// Safari / Notes / anywhere into Stocked.
//
// WHAT IT DOES
//   1. Receives whatever the host app shares: a URL, a block of text, and/or an image.
//   2. Writes that payload into the SHARED App Group container (so the main app can read it).
//   3. Opens the main app via the stocked://shareImport deep link.
//   4. The main app reads the payload, deciphers it (URL → web import; text/image → the
//      same RecipeTextParser/OCR used by "Text Manually" / "Import from Screenshot"), and
//      opens the recipe in the editable form — keeping only the essentials (title,
//      ingredients, steps) and discarding captions/hashtags/UI chrome.
//
// WHY THIS SHAPE: parsing (and the Anthropic/web calls) stays in the MAIN APP, not the
// extension. Extensions are memory-limited and sandboxed; doing the heavy lifting in the
// app is more reliable and avoids duplicating the parser. The extension's only job is
// "capture + handoff".
//
// ⚠️ This file belongs to a SHARE EXTENSION TARGET you create in Xcode — see SETUP_GUIDE.md.
//    It will NOT do anything if simply dropped into the main app target.
// ─────────────────────────────────────────────────────────────────────────────

import UIKit
import Social
import UniformTypeIdentifiers
import MobileCoreServices

final class ShareViewController: UIViewController {

    // MUST match the App Group you create in BOTH targets' Signing & Capabilities.
    private let appGroupID = "group.com.sowens.Stocked"
    // MUST match the URL scheme already registered in the main app's Info.plist.
    private let appScheme  = "stocked"

    override func viewDidLoad() {
        super.viewDidLoad()
        handleSharedContent()
    }

    private func handleSharedContent() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let providers = item.attachments, !providers.isEmpty else {
            complete(); return
        }

        final class SharedPayload: @unchecked Sendable {
            var url: String?
            var text: String?
            var image: Data?
        }
        let payload = SharedPayload()
        let group = DispatchGroup()

        for provider in providers {
            // URL
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { data, _ in
                    if let url = data as? URL { payload.url = url.absoluteString }
                    group.leave()
                }
            }
            // Plain text
            else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { data, _ in
                    if let s = data as? String { payload.text = s }
                    group.leave()
                }
            }
            // Image (screenshot of a recipe)
            else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { data, _ in
                    if let url = data as? URL, let d = try? Data(contentsOf: url) { payload.image = d }
                    else if let img = data as? UIImage { payload.image = img.jpegData(compressionQuality: 0.85) }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.persistAndOpen(url: payload.url, text: payload.text, image: payload.image)
        }
    }

    private func persistAndOpen(url: String?, text: String?, image: Data?) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { complete(); return }

        // Write the payload into the shared container under a known key.
        var payload: [String: Any] = ["receivedAt": Date().timeIntervalSince1970]
        if let url  { payload["url"]  = url }
        if let text { payload["text"] = text }
        if let image {
            // Store the image as a file in the group container; keep the path in defaults.
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
                let fileURL = container.appendingPathComponent("shared_recipe_image.jpg")
                try? image.write(to: fileURL)
                payload["imagePath"] = fileURL.path
            }
        }
        defaults.set(payload, forKey: "pendingSharedRecipe")
        defaults.synchronize()

        openMainApp()
    }

    private func openMainApp() {
        guard let url = URL(string: "\(appScheme)://shareImport") else { complete(); return }

        // Walk the responder chain to find a UIApplication we can call open(_:options:completionHandler:)
        // on. Extensions can't touch UIApplication.shared directly, but the application object is
        // reachable up the responder chain. We use the modern open API (the legacy openURL: is
        // deprecated and unreliable here), and only complete the request AFTER the open is
        // dispatched — completing too early tears down the extension before the URL opens, which
        // is what leaves a lingering black screen and a host app that never advances.
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        var opened = false
        while let r = responder {
            if let app = r as? UIApplication {
                app.open(url, options: [:]) { [weak self] _ in
                    self?.complete()
                }
                opened = true
                break
            }
            // Fallback for older runtimes: legacy openURL: if the modern path isn't reachable.
            if r.responds(to: NSSelectorFromString("openURL:")) {
                r.perform(NSSelectorFromString("openURL:"), with: url)
                opened = true
                break
            }
            responder = r.next
        }
        _ = selector  // silence unused on runtimes where only the fallback fires

        if !opened {
            complete()
        } else {
            // Safety net: if the completion handler never fires, still dismiss after a moment so
            // the extension never hangs on the black screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.complete() }
        }
    }

    private var didComplete = false
    private func complete() {
        guard !didComplete else { return }   // guard against double-complete from the safety net
        didComplete = true
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}

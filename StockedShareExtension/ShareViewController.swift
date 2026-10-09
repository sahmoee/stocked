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
import ImageIO

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

        // Provider callbacks write from background queues while the timeout below may read
        // on main, so every access goes through `lock`.
        final class SharedPayload: @unchecked Sendable {
            let lock = NSLock()
            var url: String?
            var text: String?
            var image: Data?

            func snapshot() -> (url: String?, text: String?, image: Data?) {
                lock.withLock { (url: url, text: text, image: image) }
            }
        }
        let payload = SharedPayload()
        let group = DispatchGroup()

        for provider in providers {
            // URL
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { data, _ in
                    // Hosts hand URLs over as URL, String or raw Data depending on the app.
                    if let url = SharePayloadReader.urlString(from: data) {
                        payload.lock.withLock { if payload.url == nil { payload.url = url } }
                    }
                    group.leave()
                }
            }
            // Plain text
            else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { data, _ in
                    // Notes and some social apps deliver attributed text or UTF-8 Data, which the
                    // old String-only cast silently dropped ("Couldn't find the shared item").
                    if let s = SharePayloadReader.text(from: data) {
                        payload.lock.withLock { if payload.text == nil { payload.text = s } }
                    }
                    group.leave()
                }
            }
            // Image (screenshot of a recipe)
            else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { data, _ in
                    // Downsampled through ImageIO so a 48 MP photo never gets fully decoded inside
                    // the extension's small memory budget (which terminated the share).
                    if let loaded = SharePayloadReader.imageJPEG(from: data) {
                        payload.lock.withLock { if payload.image == nil { payload.image = loaded } }
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            let p = payload.snapshot()
            self?.proceedWithSharedContent(url: p.url, text: p.text, image: p.image)
        }
        // Safety net: if a provider never calls back, the group never finishes and the
        // extension would hang forever. After a timeout, hand off whatever partial payload
        // has arrived. proceedWithSharedContent runs at most once, so whichever fires
        // second is a no-op.
        DispatchQueue.main.asyncAfter(deadline: .now() + itemLoadTimeout) { [weak self] in
            let p = payload.snapshot()
            self?.proceedWithSharedContent(url: p.url, text: p.text, image: p.image)
        }
    }

    /// Upper bound on how long we wait for item providers before proceeding anyway.
    private let itemLoadTimeout: TimeInterval = 5
    private var didProceedWithSharedContent = false
    private func proceedWithSharedContent(url: String?, text: String?, image: Data?) {
        guard !didProceedWithSharedContent else { return }
        didProceedWithSharedContent = true
        persistAndOpen(url: url, text: text, image: image)
    }

    private func persistAndOpen(url: String?, text: String?, image: Data?) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { complete(); return }

        // Write the payload into the shared container under a known key.
        var payload: [String: Any] = ["receivedAt": Date().timeIntervalSince1970]
        if let url  { payload["url"]  = url }
        if let text { payload["text"] = text }
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let fileURL = container.appendingPathComponent(SharePayloadReader.imageFileName)
            if let image {
                // Atomic write, and only advertise the file when it actually landed — a failed
                // write used to leave imagePath pointing at a missing or half-written file.
                do {
                    try image.write(to: fileURL, options: .atomic)
                    payload["imagePath"] = fileURL.path
                } catch {
                    // Fall through: URL/text (if any) still hand off.
                }
            } else {
                // Don't leave an older screenshot sitting in the shared container.
                try? FileManager.default.removeItem(at: fileURL)
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

// MARK: - Payload coercion (nonisolated; runs on item-provider callback queues)

/// Normalises whatever an item provider hands back into the plain values the main app reads.
/// Bounded so a pathological share can't exhaust the extension's memory budget.
enum SharePayloadReader {
    /// Fixed file name inside the App Group container; the main app resolves it itself.
    static let imageFileName = "shared_recipe_image.jpg"
    /// Recipes are a few KB; anything far larger is not a recipe and would only slow parsing.
    static let maximumTextCharacters = 100_000
    /// Long edge for the handed-off screenshot — plenty for OCR, a fraction of the memory.
    static let maximumImagePixels = 2_048

    static func urlString(from item: NSSecureCoding?) -> String? {
        if let url = item as? URL { return url.absoluteString }
        if let s = item as? String { return trimmedURLText(s) }
        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil) { return url.absoluteString }
            if let s = String(data: data, encoding: .utf8) { return trimmedURLText(s) }
        }
        return nil
    }

    static func text(from item: NSSecureCoding?) -> String? {
        var raw: String?
        if let s = item as? String { raw = s }
        else if let attributed = item as? NSAttributedString { raw = attributed.string }
        else if let data = item as? Data { raw = String(data: data, encoding: .utf8) }
        else if let url = item as? URL, url.isFileURL,
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                let size = attrs[.size] as? NSNumber, size.intValue <= maximumTextCharacters * 4 {
            raw = try? String(contentsOf: url, encoding: .utf8)
        }
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw.count > maximumTextCharacters ? String(raw.prefix(maximumTextCharacters)) : raw
    }

    static func imageJPEG(from item: NSSecureCoding?) -> Data? {
        let source: CGImageSource?
        if let url = item as? URL {
            source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        } else if let data = item as? Data {
            source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        } else if let image = item as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
            source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        } else {
            source = nil
        }
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honour EXIF orientation for OCR
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumImagePixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
    }

    private static func trimmedURLText(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

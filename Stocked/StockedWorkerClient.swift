// StockedWorkerClient.swift — one place to talk to the Stocked. Cloudflare Worker.
// ─────────────────────────────────────────────────────────────────────────────
// Centralizes the pattern that was copy-pasted across the receipt, barcode, and
// recipe paths: guard the placeholder URL, POST JSON, check the status, and pull
// content[0].text out of the Anthropic envelope. Each caller still parses its own
// payload (receipt JSON, barcode name, recipe JSON) from the returned text.
//
// Adoption status: RecipeImportAI uses this now. ReceiptScannerView and
// BarcodeScannerView are the next adopters — see CODE_HEALTH.md (they touch the
// working scan paths, so migrate them with a compiler in hand).
// ─────────────────────────────────────────────────────────────────────────────

import Foundation
import os

enum StockedWorkerClient {

    /// The configured Worker URL, or nil if still the placeholder.
    nonisolated static func url() -> URL? {
        let s = BuildConfig.receiptWorkerURL
        guard !s.contains("REPLACE-WITH-YOUR-WORKER"), let u = URL(string: s) else { return nil }
        return u
    }

    nonisolated static var isConfigured: Bool { url() != nil }

    /// POST `payload` to the Worker and return the model's text (content[0].text), or nil
    /// on any failure. Logs the failure reason via Log.app so problems aren't silent (#8).
    static func completionText(payload: [String: Any], timeout: TimeInterval = 30) async -> String? {
        guard let url = url() else {
            Log.app.error("WorkerClient: skipped — Worker URL not configured.")
            return nil
        }
        guard ConnectivityMonitor.isOnlineFlag else {
            Log.app.log("WorkerClient: skipped — offline.")
            return nil
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            Log.app.error("WorkerClient: failed to encode payload.")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        BuildConfig.authorizeWorkerRequest(&request)   // X-Stocked-Key shared secret
        request.httpBody = body
        request.timeoutInterval = timeout

        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                Log.app.error("WorkerClient: HTTP \(code).")
                return nil
            }
            guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let text    = content.first?["text"] as? String else {
                Log.app.error("WorkerClient: response missing content[0].text.")
                return nil
            }
            return text
        } catch {
            Log.app.error("WorkerClient: request failed — \(error.localizedDescription)")
            return nil
        }
    }
}

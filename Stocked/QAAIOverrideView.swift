import SwiftUI

/// QA-only server override. Production continues to use each app's cheapest default.
struct QAAIOverrideView: View {
    let app: String
    var hasActiveAI = true
    @State private var provider = "default"
    @State private var model = ""
    @State private var status = ""
    @State private var busy = false

    private let models = [
        "anthropic": ["claude-haiku-4-5-20251001", "claude-sonnet-4-6", "claude-opus-4-8"],
        "openai": ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol"],
    ]
    private var availableModels: [String] { models[provider] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("AI model override", systemImage: "brain.head.profile").font(.headline)
            Picker("Agent", selection: $provider) {
                Text("App Default (lowest credit)").tag("default")
                Text("Claude").tag("anthropic")
                Text("ChatGPT").tag("openai")
            }
            .onChange(of: provider) { _, value in model = models[value]?.first ?? "" }
            if provider != "default" {
                Picker("Model", selection: $model) { ForEach(availableModels, id: \.self) { Text($0).tag($0) } }
            }
            Button(busy ? "Applying…" : "Apply QA override") { Task { await save() } }.disabled(busy)
            Text(status.isEmpty ? "This affects QA runs only. API keys remain in the Worker." : status)
                .font(.caption).foregroundStyle(.secondary)
            if !hasActiveAI { Text("This app currently has no metered AI route; the choice is saved for future QA builds.").font(.caption).foregroundStyle(.secondary) }
        }
        .task { await load() }
    }

    private func request(method: String, body: Data? = nil) async throws -> Data {
        var components = URLComponents(string: "https://api.sowensstudios.com/_unified/qa/ai-config")!
        if method == "GET" { components.queryItems = [URLQueryItem(name: "app", value: app)] }
        var request = URLRequest(url: components.url!); request.httpMethod = method
        request.setValue("Joo", forHTTPHeaderField: "X-QA-Passcode")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    @MainActor private func load() async {
        do {
            let data = try await request(method: "GET")
            if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let override = root["override"] as? [String: String] {
                provider = override["provider"] ?? "default"; model = override["model"] ?? ""
            }
        } catch { status = "Could not load the current override." }
    }

    @MainActor private func save() async {
        busy = true; defer { busy = false }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["app": app, "provider": provider, "model": provider == "default" ? "" : model])
            _ = try await request(method: "POST", body: body)
            status = provider == "default" ? "Restored the app's lowest-credit default." : "QA now uses \(model)."
        } catch { status = "Override failed: \(error.localizedDescription)" }
    }
}

import SwiftUI
import Security

enum StockedAIBackend: String, CaseIterable, Identifiable {
    case managed = "Stocked managed service"
    case custom = "My private Worker"
    var id: String { rawValue }
}

nonisolated enum StockedAIConfiguration {
    private static let backendKey = "stocked.ai.backend"
    private static let endpointKey = "stocked.ai.customEndpoint"
    private static let modelKey = "stocked.ai.model"
    private static let keychainService = "com.sowens.Stocked.ai"
    private static let tokenAccount = "worker-token"

    static var backend: StockedAIBackend {
        get { StockedAIBackend(rawValue: UserDefaults.standard.string(forKey: backendKey) ?? "") ?? .managed }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: backendKey) }
    }
    static var endpoint: String {
        get { UserDefaults.standard.string(forKey: endpointKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: endpointKey) }
    }
    static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? "" }
        set { UserDefaults.standard.set(safeModel(newValue), forKey: modelKey) }
    }
    static var baseURL: URL? {
        if backend == .custom, let url = URL(string: endpoint), url.scheme == "https" { return url }
        return URL(string: BuildConfig.receiptWorkerURL)
    }
    static var token: String { keychainRead() ?? "" }

    static func saveToken(_ value: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: tokenAccount]
        SecItemDelete(query as CFDictionary)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    static func apply(to request: inout URLRequest) {
        if backend == .custom, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if !model.isEmpty { request.setValue(model, forHTTPHeaderField: "X-AI-Model") }
        request.setValue(backend == .custom ? "custom-worker" : "managed", forHTTPHeaderField: "X-AI-Agent")
    }
    private static func safeModel(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            .filter { $0.isLetter || $0.isNumber || "-_.:/".contains($0) }
    }
    private static func keychainRead() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: tokenAccount,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct StockedAISettingsView: View {
    @Environment(AppSession.self) private var session
    @State private var backend = StockedAIConfiguration.backend
    @State private var endpoint = StockedAIConfiguration.endpoint
    @State private var model = StockedAIConfiguration.model
    @State private var token = StockedAIConfiguration.token

    var body: some View {
        Form {
            Section("Agent") {
                Picker("AI service", selection: $backend) {
                    ForEach(StockedAIBackend.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.inline)
            }
            if backend == .custom {
                Section("Private Worker") {
                    TextField("https://example.workers.dev", text: $endpoint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Worker access token (optional)", text: $token)
                    Text("Deploy UnifiedWorker in your Cloudflare account and add your provider API key with Wrangler. Stocked keeps only this Worker's optional token in Stocked's Keychain.")
                        .font(.caption)
                }
            }
            Section("Model") {
                TextField("Worker default", text: $model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Blank keeps the existing automatic model. Your private Worker can accept this model ID or enforce its own allowlist.").font(.caption)
            }
        }
        .scrollContentBackground(.hidden)
        .background(session.backgroundView.ignoresSafeArea())
        .navigationTitle("AI Agent & Model")
        .onDisappear {
            StockedAIConfiguration.backend = backend
            StockedAIConfiguration.endpoint = endpoint
            StockedAIConfiguration.model = model
            StockedAIConfiguration.saveToken(token)
        }
    }
}

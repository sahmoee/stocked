import SwiftUI
import Security

nonisolated enum StockedAIBackend: String, CaseIterable, Identifiable {
    case automatic = "Automatic — Apple on-device first"
    case managed = "Stocked managed service"
    case credits = "Prepaid managed AI credits"
    case custom = "My private Worker"
    var id: String { rawValue }

    static var availableCases: [StockedAIBackend] {
        allCases.filter { $0 != .credits || AICreditStorefront.isEnabled }
    }
}

nonisolated enum StockedAIProvider: String, CaseIterable, Identifiable {
    case anthropic = "Anthropic — Claude"
    case openAI = "OpenAI — ChatGPT models"
    var id: String { rawValue }
    var headerValue: String { self == .openAI ? "openai" : "anthropic" }
}

nonisolated enum StockedAIConfiguration {
    private static let backendKey = "stocked.ai.backend"
    private static let endpointKey = "stocked.ai.customEndpoint"
    private static let modelKey = "stocked.ai.model"
    private static let providerKey = "stocked.ai.provider"
    private static let managedUnlockKey = "stocked.ai.managedSettingsUnlocked"
    private static let keychainService = "com.sowens.Stocked.ai"
    private static let tokenAccount = "worker-token"

    static var backend: StockedAIBackend {
        get { StockedAIBackend(rawValue: UserDefaults.standard.string(forKey: backendKey) ?? "") ?? .automatic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: backendKey) }
    }
    static var provider: StockedAIProvider {
        get { StockedAIProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .anthropic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }
    static var managedSettingsUnlocked: Bool {
        get { UserDefaults.standard.bool(forKey: managedUnlockKey) }
        set { UserDefaults.standard.set(newValue, forKey: managedUnlockKey) }
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
        guard managedSettingsUnlocked || (backend == .credits && AICreditStorefront.isEnabled) else { return nil }
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
        request.setValue(provider.headerValue, forHTTPHeaderField: "X-AI-Provider")
        request.setValue(backend == .custom ? "custom-worker" : backend == .credits ? "managed-credit" : "managed-owner", forHTTPHeaderField: "X-AI-Agent")
        if backend == .credits { AICreditStore.applyAccount(to: &request) }
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
    @State private var provider = StockedAIConfiguration.provider
    @State private var token = StockedAIConfiguration.token
    @State private var unlockCode = ""
    @State private var managedUnlocked = StockedAIConfiguration.managedSettingsUnlocked

    var body: some View {
        Form {
            Section("Agent") {
                Picker("AI service", selection: $backend) {
                    ForEach(StockedAIBackend.availableCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.inline)
                if backend == .automatic {
                    Label(AppleOnDeviceAI.isAvailable ? "Apple Intelligence is ready" : (AppleOnDeviceAI.unavailableReason ?? "Apple Intelligence unavailable; hosted fallback will be used"), systemImage: AppleOnDeviceAI.isAvailable ? "apple.intelligence" : "icloud")
                        .font(.caption)
                }
            }
            if backend == .custom {
                Section("Private Worker") {
                    TextField("https://example.workers.dev", text: $endpoint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Worker access token (optional)", text: $token)
                    Picker("Provider", selection: $provider) { ForEach(StockedAIProvider.allCases) { Text($0.rawValue).tag($0) } }
                    Text("Deploy UnifiedWorker in your Cloudflare account and add ANTHROPIC_API_KEY or OPENAI_API_KEY with Wrangler. Stocked keeps only this Worker's optional token in Stocked's Keychain.")
                        .font(.caption)
                }
            }
            Section("Model") {
                TextField("Worker default", text: $model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(backend != .custom && !managedUnlocked)
                if backend != .custom && !managedUnlocked {
                    SecureField("Passcode to change included model", text: $unlockCode)
                    Button("Unlock included model") {
                        guard unlockCode == "Joo" else { return }
                        managedUnlocked = true
                        StockedAIConfiguration.managedSettingsUnlocked = true
                        unlockCode = ""
                    }
                }
                Text(backend == .custom
                     ? "Choose any model supported by your own Worker and provider account."
                     : "Included AI is reserved for registered production/test devices and keeps its current credentials and standard model. Enter the device passcode once, or use your own private Worker credentials for more usage or a higher model.")
                    .font(.caption)
            }
            if AICreditStorefront.isEnabled {
                Section("AI credits") {
                    NavigationLink("Buy or view AI credits") { AICreditStoreView().environment(session) }
                    Text("For people who do not want to configure a private Worker. Purchases unlock the existing managed AI and are charged by successful action.").font(.caption)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(session.backgroundView.ignoresSafeArea())
        .navigationTitle("AI Agent & Model")
        .onAppear {
            if backend == .credits && !AICreditStorefront.isEnabled {
                backend = .automatic
                StockedAIConfiguration.backend = .automatic
            }
        }
        .onDisappear {
            StockedAIConfiguration.backend = backend
            StockedAIConfiguration.endpoint = endpoint
            StockedAIConfiguration.model = model
            StockedAIConfiguration.provider = provider
            StockedAIConfiguration.saveToken(token)
        }
    }
}

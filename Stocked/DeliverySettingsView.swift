import SwiftUI
import UIKit

struct DeliverySettingsView: View {
    @Environment(AppSession.self) private var session
    @State private var service = HouseholdDeliveryService.shared
    @State private var endpoint = ""
    @State private var secret: String?
    @State private var problem = ""
    @State private var busy = false
    @State private var confirmEnable = false
    @State private var reviewedEndpoint = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ToolboxCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Household updates", systemImage: "antenna.radiowaves.left.and.right").font(.headline)
                        Text(service.connection)
                        Text("While Stocked is open, a small change notice asks the app to fetch the latest shared information. Regular checks continue if the live connection drops.")
                            .font(.caption).foregroundStyle(session.themeSecondaryText)
                    }
                }
                if HouseholdSync.shared.joinCode == nil {
                    Text("Create or join a household in Sharing to use delivery settings.")
                } else {
                    ToolboxCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Updates when the app is closed", systemImage: "bell.badge").font(.headline)
                            Text(service.status?.apns == "available" ? "Apple server: ready" : "Apple server: setup required")
                            Text("iOS permission: \(service.permission)")
                            Text(service.registeredWithApple ? "This device: registered with Apple" : "This device: waiting for Apple registration")
                            Text(service.masterNotificationsEnabled ? "App notifications: on" : "App notifications: off in Settings")
                            Toggle("Allow background household updates on this device", isOn: Binding(
                                get: { service.deviceOptIn }, set: { value in Task { await service.setDeviceOptIn(value) } }))
                                .disabled(busy || (service.status?.apns != "available" && !service.deviceOptIn))
                            if service.permission != "Allowed" {
                                Button("Review notification permission") { NotificationPermissionCoordinator.promptFromUserAction() }
                                Button("Open iOS Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                            }
                            Text("This is optional. Apple decides when background updates arrive, so delivery can be delayed. No shopping details appear in a push notification. Your app notification preference still applies.")
                                .font(.caption).foregroundStyle(session.themeSecondaryText)
                        }
                    }
                    ToolboxCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Send change notices to your own tool", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                            Text("A webhook is an address you control that receives a signed change notice. It receives only an event ID, time, revision and names of changed sections. It does not receive household names, invite codes, items, recipes or receipts.")
                                .font(.caption).foregroundStyle(session.themeSecondaryText)
                            if service.status?.ownerVerified == true {
                                TextField("https://receiver.account.workers.dev", text: $endpoint)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).textFieldStyle(.roundedBorder)
                                Button(service.status?.webhookEnabled == true ? "Change receiver and signing key…" : "Enable this receiver…") {
                                    reviewedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                                    confirmEnable = true
                                }
                                    .disabled(busy || endpoint.isEmpty)
                                if service.status?.webhookEnabled == true {
                                    Button("Turn off webhook", role: .destructive) { updateWebhook(enabled: false) }.disabled(busy)
                                    Text("Before leaving this share or erasing local app data, turn this receiver off if you want notices to stop. Erasing your owner key does not turn off the server receiver.")
                                        .font(.caption).foregroundStyle(session.themeSecondaryText)
                                }
                                Text("Only Cloudflare workers.dev receivers are supported. They can run on a free plan. Redirects and custom domains are refused to protect the server. An already-sent request cannot be recalled.")
                                    .font(.caption).foregroundStyle(session.themeSecondaryText)
                            } else if service.status?.secureShare == false {
                                Text("This older share has no private owner key. Webhook setup is locked. To use it, first review your local data, then explicitly stop sharing and create a new share in Sharing. Your members will need the new invite. Nothing is moved or deleted here.")
                            } else { Text("Only the device that created this secure share can change its receiver.") }
                            if let secret {
                                Text("Receiver signing key — shown only for this setup").font(.headline)
                                Text(secret).font(.system(.caption, design: .monospaced)).textSelection(.enabled).privacySensitive()
                                Button("Copy signing key for 2 minutes") {
                                    UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: secret]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                                }
                                Text("Save this in your receiver's secret settings. It isn't a bank or account password. Changing the receiver creates a new key.").font(.caption)
                            }
                            if let status = service.status {
                                Text(status.webhookEnabled ? "Webhook is enabled" : "Webhook is off")
                                Text("Queued change notices: \(status.pending)")
                                if let result = status.lastResult { Text("Last delivery: \(resultDescription(result))") }
                                if let date = status.lastAttempt { Text("Last attempt: \(date)").font(.caption) }
                                if status.coalesced > 0 { Text("Busy periods combined \(status.coalesced) older change notices. The newest notice still asks for a full refresh.").font(.caption) }
                            }
                        }
                    }
                    Button("Refresh delivery status") { Task { await service.refreshStatus(); endpoint = service.status?.endpoint ?? endpoint } }.disabled(busy)
                }
                if busy { ProgressView("Saving delivery settings…") }
                if !problem.isEmpty { Text(problem).foregroundStyle(session.themeSecondaryText) }
                if !service.problem.isEmpty { Text(service.problem).foregroundStyle(session.themeSecondaryText) }
            }.padding()
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .foregroundStyle(session.themeTextColor)
        .tint(session.themeButtonColor)
        .navigationTitle("Household delivery")
        .task { await service.refreshStatus(); endpoint = service.status?.endpoint ?? "" }
        .onDisappear { secret = nil }
        .confirmationDialog("Enable signed notices to this receiver?", isPresented: $confirmEnable, titleVisibility: .visible) {
            Button("Enable receiver") { updateWebhook(enabled: true) }
        } message: { Text("Future shared changes will send small notices to:\n\(reviewedEndpoint)\n\nThe signing key changes each time you enable or change the receiver. No test message is sent.") }
    }
    private func updateWebhook(enabled: Bool) {
        busy = true; problem = ""
        let selectedEndpoint = enabled ? reviewedEndpoint : endpoint
        Task { @MainActor in
            defer { busy = false }
            do { secret = try await service.configureWebhook(endpoint: selectedEndpoint, enabled: enabled) }
            catch { problem = error.localizedDescription }
        }
    }
    private func resultDescription(_ value: String) -> String {
        if value == "delivered" { return "Receiver accepted the notice" }
        if value == "appleAccepted" { return "Apple accepted the update; arrival is not guaranteed" }
        if value == "cancelled" || value == "memberLeft" { return "Cancelled after settings or membership changed" }
        if value == "retryLimitReached" { return "Stopped after six attempts; check your receiver" }
        if value.hasPrefix("receiverHTTP") { return "Receiver declined or was unavailable (\(value.dropFirst(12)))" }
        if value.hasPrefix("appleHTTP") { return "Apple declined the request (\(value.dropFirst(9)))" }
        return "Temporarily unavailable; check setup and refresh status"
    }
}

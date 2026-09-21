import SwiftUI

/// Navigation only. Each destination keeps its existing data and authorization owner.
struct FreeKitchenHubView: View {
    @Environment(AppSession.self) private var session
    @State private var showRecipes = false
    @State private var showConnections = false
    @AppStorage("stocked.freeConnections.resetWarning.v1") private var resetWarning = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Your kitchen, connected").font(.stocked(.title2))
                Text("Choose the connections you want. No new subscription is required. Your existing kitchen works without setting these up.")
                    .foregroundStyle(session.themeSecondaryText)
                if !resetWarning.isEmpty {
                    ToolboxCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(resetWarning, systemImage: "exclamationmark.lock")
                            Text("Retry removes Grocy/calendar credentials, local receipts and household connection keys on this device. Your kitchen items and remote calendars/shares stay. You may need to join your household again. Turn off any remote webhook in Household delivery first if you still have access.").font(.stocked(.footnote))
                            Button("Retry removing connection keys", role: .destructive) {
                                do { try FreeKitchenLocalReset.clearAllConnections(); resetWarning = "" }
                                catch { resetWarning = "Unlock this device and try again. Some connection keys could not be removed." }
                            }
                        }
                    }
                }
                ToolboxCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Button { showConnections = true } label: {
                            Label("Grocy & calendars", systemImage: "calendar.badge.clock").frame(minHeight: 44)
                        }
                        Text("Use your own Grocy server or compatible calendar account. Review imports and calendar changes before applying them.")
                            .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                    }
                }
                ToolboxCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Button { showRecipes = true } label: { Label("Find Cooklang recipes", systemImage: "book.closed").frame(minHeight: 44) }
                        Text("Search the free federation service, open the source, then review a private recipe import.")
                            .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                    }
                }
                ToolboxCard {
                    VStack(alignment: .leading, spacing: 12) {
                        NavigationLink { CommunityPriceWatchesView() } label: {
                            Label("Saved price checks", systemImage: "tag.circle").frame(minHeight: 44)
                        }
                        Text("Save a target and check recent community reports when you choose. Your receipt history stays separate.")
                            .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                    }
                }
                ToolboxCard {
                    VStack(alignment: .leading, spacing: 12) {
                        NavigationLink { DeliverySettingsView() } label: {
                            Label("Household updates & delivery", systemImage: "antenna.radiowaves.left.and.right").frame(minHeight: 44)
                        }
                        Text("See connection status, manage optional update delivery and configure a signed webhook receiver you control.")
                            .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                    }
                }
                NavigationLink { StockedHealthView() } label: { Label("App health & recovery", systemImage: "waveform.path.ecg").frame(minHeight: 44) }
                Text("Connecting an outside service is optional and sends only the information described in that connection’s review. Keys stay out of shared recipes and household backups.")
                    .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
            }.padding(20).foregroundStyle(session.themeTextColor)
        }.background(session.themeBgColor.ignoresSafeArea()).tint(session.themeButtonColor)
            .navigationTitle("Free kitchen connections").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showRecipes) { CooklangRecipeConnectionView().environment(session) }
            .sheet(isPresented: $showConnections) { FreeKitchenConnectionsView().environment(session) }
    }
}

import Foundation
@preconcurrency import WatchConnectivity

@MainActor final class KitchenWatchTransport: NSObject, WCSessionDelegate {
    var receive: ((Data) -> Void)?
    var changed: (() -> Void)?
    private(set) var failure: String?
    var reachable: Bool { WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isReachable }
    var ready: Bool {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return false }
        #if os(iOS)
        return WCSession.default.isPaired && WCSession.default.isWatchAppInstalled
        #else
        return true
        #endif
    }
    func start() {
        guard WCSession.isSupported() else { failure = "Watch connection is unavailable on this device."; return }
        WCSession.default.delegate = self; WCSession.default.activate()
    }
    func send(_ data: Data, durableID: UUID? = nil) {
        guard ready, data.count <= KitchenWatch.wireLimit else { return }
        if reachable {
            WCSession.default.sendMessageData(data, replyHandler: nil) { [weak self] _ in
                Task { @MainActor in self?.failure = "Waiting for the paired device." }
            }
        }
        if let durableID, !WCSession.default.outstandingUserInfoTransfers.contains(where: { ($0.userInfo["id"] as? String) == durableID.uuidString }) {
            WCSession.default.transferUserInfo(["stocked": data, "id": durableID.uuidString])
        }
    }
    func context(_ data: Data) {
        guard ready, data.count <= KitchenWatch.wireLimit else { return }
        do { try WCSession.default.updateApplicationContext(["stocked": data]); failure = nil }
        catch { failure = "Snapshot will retry when the connection is available." }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let data = session.receivedApplicationContext["stocked"] as? Data
        Task { @MainActor in
            if let data { self.receive?(data) }
            self.changed?()
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) { Task { @MainActor in self.changed?() } }
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) { deliver(messageData) }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let data = applicationContext["stocked"] as? Data { deliver(data) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let data = userInfo["stocked"] as? Data { deliver(data) }
    }
    nonisolated private func deliver(_ data: Data) {
        guard data.count <= KitchenWatch.wireLimit else { return }
        Task { @MainActor in self.receive?(data) }
    }
    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}

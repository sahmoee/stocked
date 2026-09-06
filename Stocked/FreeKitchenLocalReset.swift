import Foundation

/// Try every device cleanup even when one Keychain deletion fails. Never delete remote kitchen data.
@MainActor enum FreeKitchenLocalReset {
    enum Failure: LocalizedError {
        case keysRemain
        var errorDescription: String? { "Some saved connection keys could not be removed. Unlock this device and retry removal in Free Kitchen Connections." }
    }
    static func clearAllConnections() throws {
        var failed = false
        do { try KitchenConnectionReset.clearLocalState() } catch { failed = true }
        do { try HouseholdDeliveryService.shared.clearLocalState() } catch { failed = true }
        if failed { throw Failure.keysRemain }
    }
}

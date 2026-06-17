// AuthSession.swift — Authentication state and actions for AppSession.
// Extracted from AppSession.swift (item #1).
import Foundation

// MARK: - AuthSessionProtocol
// Allows mocking AppSession in tests and previews.
protocol AuthSessionProtocol: AnyObject {
    var isLoggedIn:  Bool        { get set }
    var accountType: AccountType { get set }
    var displayName: String      { get set }
    var appleUserID: String      { get set }
    func enterKitchen(name: String)
    func signOut(clearData: Bool)
}

// AppSession conforms to the protocol automatically via its existing properties
extension AppSession: AuthSessionProtocol {}

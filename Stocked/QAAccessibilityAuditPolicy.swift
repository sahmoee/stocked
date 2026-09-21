import Foundation

/// Separates actual VoiceOver stops from UIKit/SwiftUI implementation plumbing.
/// Windows, scroll hosts, passthrough surfaces and floating-bar containers often
/// carry gesture recognizers but are not accessibility elements themselves.
nonisolated enum QAAccessibilityAuditPolicy {
    static func shouldAudit(isAccessibilityElement: Bool,
                            isControl: Bool,
                            hasButtonOrLinkTrait: Bool,
                            isUserInteractionEnabled: Bool,
                            hasTapOrLongPressGesture: Bool) -> Bool {
        guard isAccessibilityElement else { return false }
        return isControl || hasButtonOrLinkTrait ||
            (isUserInteractionEnabled && hasTapOrLongPressGesture)
    }
}

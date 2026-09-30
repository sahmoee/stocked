#if DEBUG && (os(iOS) || os(tvOS) || os(watchOS))
import SwiftUI
import PulseUI

public struct SowensNetworkConsole: View {
    public init() {}
    public var body: some View {
        if let store = NetworkDiagnostics.store {
            ConsoleView(store: store)
        } else {
            SowensStatusView("Diagnostics unavailable", detail: "Network requests continue normally.", symbol: "network.slash", state: .failed)
        }
    }
}
#endif

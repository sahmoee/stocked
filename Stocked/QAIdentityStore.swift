import SwiftUI
import UIKit
import Darwin

@Observable @MainActor final class QAIdentityStore {
    static let shared = QAIdentityStore()
    var tester: QATester {
        didSet { UserDefaults.standard.set(tester.rawValue, forKey: "qa.identity.tester.v1") }
    }
    let installationID: String
    private init() {
        let defaults = UserDefaults.standard
        tester = QATester(rawValue: defaults.string(forKey: "qa.identity.tester.v1") ?? "") ?? .unassigned
        // A restored device backup must not clone the QA installation identity.
        // The vendor token is local only; reports contain a random QA-specific UUID.
        let vendor = UIDevice.current.identifierForVendor?.uuidString
        let previousVendor = defaults.string(forKey: "qa.identity.localVendor.v1")
        let restoredOnAnotherDevice = vendor != nil && previousVendor != nil && vendor != previousVendor
        let saved = defaults.string(forKey: "qa.identity.installation.v1").flatMap(UUID.init(uuidString:))
        installationID = (!restoredOnAnotherDevice ? saved : nil)?.uuidString ?? UUID().uuidString
        defaults.set(installationID, forKey: "qa.identity.installation.v1")
        if let vendor { defaults.set(vendor, forKey: "qa.identity.localVendor.v1") }
        if restoredOnAnotherDevice { tester = .unassigned }
    }
    static var hardwareIdentifier: String {
        var system = utsname(); uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
    func capture() -> QAReportIdentity {
        #if targetEnvironment(simulator)
        let simulated = true
        let identifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? Self.hardwareIdentifier
        #else
        let simulated = false
        let identifier = Self.hardwareIdentifier
        #endif
        let family = QADeviceModels.family(identifier: identifier, fallback: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : UIDevice.current.model)
        return QAReportIdentity(deviceFamily: family, deviceModel: QADeviceModels.name(identifier: identifier, fallback: family),
            modelIdentifier: identifier, installationID: installationID, isSimulator: simulated).assigning(tester)
    }
}

struct QAIdentitySettingsSection: View {
    @State private var identity = QAIdentityStore.shared
    var body: some View {
        Section {
            Picker("Tester on this device", selection: $identity.tester) {
                ForEach(QATester.allCases) { tester in Text(tester.name).tag(tester) }
            }
            let device = identity.capture()
            LabeledContent("Device type", value: device.deviceFamily)
            LabeledContent("Model", value: device.deviceModel)
            LabeledContent("Hardware identifier", value: device.modelIdentifier)
            LabeledContent("QA device", value: String(device.installationID.prefix(8)))
        } header: { Text("Tester and device") }
        footer: {
            Text("Choose Key or Shalise once on each phone and iPad. The selection stays on this device, separate from household profiles. New manual and automatic reports include it; older reports remain unassigned unless you identify them explicitly.")
        }
    }
}

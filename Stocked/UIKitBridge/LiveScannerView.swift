// LiveScannerView.swift — Canonical live camera scanner (UIKit bridge).
// Wraps VisionKit's DataScannerViewController for barcode (and optional live-text)
// recognition. This is the single live-scanner bridge used across the app; the
// SwiftUI BarcodeScannerView presents it inside its livePanel.
//
// Renamed from the old duplicate `BarcodeScannerView` (which collided with the
// SwiftUI view of the same name and produced a "Multiple commands produce" build
// error under Xcode's synchronized file groups).
import SwiftUI
import VisionKit

/// UIKit bridge: live barcode and text scanning via DataScannerViewController.
///
/// Check `LiveScannerView.isSupported` before presenting; the controller is only
/// available on devices with a supported camera and a neural engine.
@available(iOS 16.0, *)
struct LiveScannerView: UIViewControllerRepresentable {
    var recognizesBarcodes: Bool = true
    var recognizesText: Bool = false
    /// Called on the main actor with the scanned barcode payload or recognized text.
    var onScan: @MainActor (String) -> Void

    /// True only on devices that actually support and can present the scanner.
    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        var recognized: [DataScannerViewController.RecognizedDataType] = []
        if recognizesBarcodes { recognized.append(.barcode()) }
        if recognizesText { recognized.append(.text()) }
        if recognized.isEmpty { recognized.append(.barcode()) }

        let vc = DataScannerViewController(
            recognizedDataTypes: Set(recognized),
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        // Start scanning shortly after the view is attached so the session is ready.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            try? vc.startScanning()
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    // Stop scanning when the view disappears — prevents the camera staying open
    // and the associated memory leak.
    static func dismantleUIViewController(_ uiViewController: DataScannerViewController,
                                          coordinator: Coordinator) {
        uiViewController.stopScanning()
        uiViewController.delegate = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: @MainActor (String) -> Void
        // Debounce identical reads so a single item isn't reported repeatedly.
        private var lastValue = ""
        private var lastTime = Date.distantPast

        init(onScan: @escaping @MainActor (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard let value = Self.value(from: addedItems.first), !value.isEmpty else { return }
            let now = Date()
            guard value != lastValue || now.timeIntervalSince(lastTime) > 2 else { return }
            lastValue = value; lastTime = now
            Task { @MainActor in self.onScan(value) }
        }

        private static func value(from item: RecognizedItem?) -> String? {
            switch item {
            case .barcode(let bc):
                return bc.payloadStringValue
            case .text(let text):
                return text.transcript
            default:
                return nil
            }
        }
    }
}

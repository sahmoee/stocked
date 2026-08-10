import SwiftUI
import VisionKit

/// UIKit bridge: live barcode and text scanning via DataScannerViewController.
/// Best fit UIKit area four: fast add to inventory by scanning product barcodes.
///
/// Check BarcodeScannerView.isSupported before presenting; the controller is
/// only available on devices with a supported camera and a neural engine.
@available(iOS 16.0, *)
struct BarcodeScannerView: UIViewControllerRepresentable {
    var recognizesBarcodes: Bool = true
    var recognizesText: Bool = false
    var onScan: @MainActor (String) -> Void

    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        var recognized: [DataScannerViewController.RecognizedDataType] = []
        if recognizesBarcodes {
            recognized.append(.barcode())
        }
        if recognizesText {
            recognized.append(.text())
        }
        if recognized.isEmpty {
            recognized.append(.barcode())
        }

        let scanner = DataScannerViewController(
            recognizedDataTypes: Set(recognized),
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onScan = onScan
        try? scanner.startScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onScan: (String) -> Void

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                switch item {
                case .barcode(let barcode):
                    if let value = barcode.payloadStringValue {
                        onScan(value)
                    }
                case .text(let text):
                    onScan(text.transcript)
                @unknown default:
                    break
                }
            }
        }
    }
}

import SwiftUI
import VisionKit

/// UIKit bridge: system document camera (VisionKit) surfaced to SwiftUI.
/// Best fit UIKit area one: receipt and document capture.
///
/// Usage:
///   .sheet(isPresented: $showScanner) {
///       DocumentScannerView { pages in
///           // pages is an ordered array of scanned UIImage pages
///       } onCancel: { showScanner = false }
///   }
struct DocumentScannerView: UIViewControllerRepresentable {
    var onComplete: @MainActor ([UIImage]) -> Void
    var onCancel: @MainActor () -> Void = {}

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete, onCancel: onCancel)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onComplete: @MainActor ([UIImage]) -> Void
        private let onCancel: @MainActor () -> Void

        init(onComplete: @escaping @MainActor ([UIImage]) -> Void,
             onCancel: @escaping @MainActor () -> Void) {
            self.onComplete = onComplete
            self.onCancel = onCancel
        }

        nonisolated func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                                      didFinishWith scan: VNDocumentCameraScan) {
            var pages: [UIImage] = []
            pages.reserveCapacity(scan.pageCount)
            for index in 0 ..< scan.pageCount {
                pages.append(scan.imageOfPage(at: index))
            }
            MainActor.assumeIsolated { onComplete(pages) }
        }

        nonisolated func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            MainActor.assumeIsolated { onCancel() }
        }

        nonisolated func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                                      didFailWithError error: Error) {
            MainActor.assumeIsolated { onCancel() }
        }
    }
}

import UIKit
import Vision

/// On device Vision OCR helper that pairs with DocumentScannerView.
/// Returns recognized lines in top to bottom reading order.
enum ImageTextRecognizer {
    static func recognizeText(in image: UIImage,
                              languages: [String] = ["en-US"]) async -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    /// Convenience joining the recognized lines into a single block of text.
    static func recognizeText(in image: UIImage,
                              languages: [String] = ["en-US"]) async -> String {
        let lines: [String] = await recognizeText(in: image, languages: languages)
        return lines.joined(separator: "\n")
    }
}

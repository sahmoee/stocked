import Foundation

/// Device-local correction evidence; only bounded item-name pairs enter inventory prompts.
@MainActor final class AICorrectionStore {
    static let shared = AICorrectionStore()
    typealias Kind = CorrectionCalibration.Kind
    typealias Outcome = CorrectionCalibration.Outcome
    private let key = "aiCorrectionCalibration_v1"
    private var calibration = CorrectionCalibration()

    private init() {
        if let data = UserDefaults.standard.data(forKey: key), data.count <= CorrectionCalibration.maximumEncodedBytes,
           let records = try? JSONDecoder().decode([String: CorrectionCalibration.Record].self, from: data) {
            calibration = CorrectionCalibration(records: records)
        }
    }
    func record(kind: Kind, original: String, predicted: String, final: String, outcome: Outcome) {
        guard original.utf8.count <= CorrectionCalibration.maximumText * 4, original.count <= CorrectionCalibration.maximumText,
              calibration.record(kind: kind, original: FoodNameMatcher.normalized(original), predicted: predicted, final: final, outcome: outcome),
              let data = try? JSONEncoder().encode(calibration.records), data.count <= CorrectionCalibration.maximumEncodedBytes else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    func promptCorrections(limit: Int = 24) -> [String: String] { calibration.promptCorrections(limit: limit) }
    func adjustedConfidence(kind: Kind, original: String, predicted: String, base: Double) -> Double {
        guard original.utf8.count <= CorrectionCalibration.maximumText * 4, original.count <= CorrectionCalibration.maximumText else {
            return base.isFinite ? min(1, max(0, base)) : 0
        }
        return calibration.confidence(kind: kind, original: FoodNameMatcher.normalized(original), predicted: predicted, base: base)
    }
}

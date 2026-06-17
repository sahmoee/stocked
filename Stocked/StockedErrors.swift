// StockedErrors.swift — Typed error system (Code Professional #5)
import SwiftUI

enum StockedError: LocalizedError {
    case networkUnavailable
    case invalidURL(String)
    case decodingFailed(String)
    case apiTimeout
    case noResults(String)
    case saveFailed(String)
    case loadFailed(String)
    case cameraUnavailable
    case barcodeNotFound
    case ocrFailed
    case biometricFailed
    case biometricUnavailable
    case calendarAccessDenied
    case calendarSaveFailed

    var errorDescription: String? {
        switch self {
        case .networkUnavailable:   return "No internet connection. Showing cached results."
        case .invalidURL:           return "Invalid URL provided."
        case .decodingFailed:       return "Could not read server response."
        case .apiTimeout:           return "Request timed out. Please try again."
        case .noResults:            return "No recipes found. Try a different search."
        case .saveFailed:           return "Could not save data."
        case .loadFailed:           return "Could not load data."
        case .cameraUnavailable:    return "Camera access required. Enable in Settings."
        case .barcodeNotFound:      return "Barcode not recognised. Try again."
        case .ocrFailed:            return "Could not read the receipt. Try better lighting."
        case .biometricFailed:      return "Face ID / Touch ID failed."
        case .biometricUnavailable: return "Biometrics not available on this device."
        case .calendarAccessDenied: return "Calendar access denied. Enable in Settings."
        case .calendarSaveFailed:   return "Could not add meal to Calendar."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .networkUnavailable, .apiTimeout, .noResults:
            return true
        default:
            return false
        }
    }
}


// MARK: - Debug error logging (item #4)
// Use tryLogged instead of try? to surface silent failures during development.
func tryLogged<T>(_ label: String = "", _ expression: @autoclosure () throws -> T) -> T? {
    do {
        return try expression()
    } catch {
        #if DEBUG
        print("⚠️ Stocked silent error [\(label)]: \(error)")
        #endif
        return nil
    }
}

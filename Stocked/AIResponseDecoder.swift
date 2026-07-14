// AIResponseDecoder.swift
// Centralized Anthropic-envelope and lenient JSON extraction.
import Foundation

nonisolated struct AITextResponse: Sendable, Equatable {
    let text: String
    let stopReason: String?
    let model: String?
    let schemaVersion: Int?

    var wasTruncated: Bool { stopReason == "max_tokens" }
}

nonisolated enum AIResponseDecoder {
    static func textResponse(from data: Data) throws -> AITextResponse {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? String {
                let upstream = object["upstreamStatus"] as? Int
                throw StockedServiceError.httpStatus(upstream ?? 500, error)
            }

            if let content = object["content"] as? [[String: Any]] {
                let text = content.compactMap { block -> String? in
                    guard (block["type"] as? String ?? "text") == "text" else { return nil }
                    return block["text"] as? String
                }.joined(separator: "\n")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw StockedServiceError.malformedResponse("The assistant returned no text.")
                }
                let response = AITextResponse(
                    text: text,
                    stopReason: object["stop_reason"] as? String,
                    model: object["model"] as? String,
                    schemaVersion: object["schemaVersion"] as? Int
                )
                if response.wasTruncated { throw StockedServiceError.truncatedResponse }
                return response
            }

            // Typed Worker responses may be returned directly rather than in an Anthropic envelope.
            if JSONSerialization.isValidJSONObject(object),
               let direct = try? JSONSerialization.data(withJSONObject: object),
               let text = String(data: direct, encoding: .utf8) {
                return AITextResponse(text: text, stopReason: nil, model: nil,
                                      schemaVersion: object["schemaVersion"] as? Int)
            }
        }

        guard let raw = String(data: data, encoding: .utf8), !raw.isEmpty else {
            throw StockedServiceError.malformedResponse("The service returned unreadable data.")
        }
        return AITextResponse(text: raw, stopReason: nil, model: nil, schemaVersion: nil)
    }

    static func jsonData(from text: String, root: Character? = nil) throws -> Data {
        let stripped = stripCodeFences(text)
        if let data = stripped.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }

        let preferredOpen = root ?? firstJSONRoot(in: stripped)
        guard let open = preferredOpen else {
            throw StockedServiceError.malformedResponse("No JSON object or array was found in the response.")
        }
        let close: Character = open == "[" ? "]" : "}"
        guard let slice = balancedSlice(in: stripped, opening: open, closing: close),
              let data = slice.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw StockedServiceError.malformedResponse("The response contained incomplete JSON.")
        }
        return data
    }

    static func jsonObject(from text: String) throws -> [String: Any] {
        do {
            let data = try jsonData(from: text, root: "{")
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw StockedServiceError.malformedResponse("The response JSON was not an object.")
            }
            return object
        } catch {
            // Models occasionally leave a trailing comma before a closing bracket. Repair only
            // that narrow syntax error; do not invent missing fields or silently reshape data.
            let repaired = stripCodeFences(text)
                .replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
            let data = try jsonData(from: repaired, root: "{")
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw StockedServiceError.malformedResponse("The response JSON was not an object.")
            }
            return object
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from responseData: Data,
                                     expectedSchemaVersion: Int? = nil) throws -> T {
        let response = try textResponse(from: responseData)
        if let expectedSchemaVersion,
           let actual = response.schemaVersion,
           actual != expectedSchemaVersion {
            throw StockedServiceError.schemaMismatch(expected: expectedSchemaVersion, actual: actual)
        }
        let data = try jsonData(from: response.text)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw StockedServiceError.malformedResponse(error.localizedDescription) }
    }

    static func stripCodeFences(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            if let firstNewline = value.firstIndex(of: "\n") {
                value = String(value[value.index(after: firstNewline)...])
            }
            if let closing = value.range(of: "```", options: .backwards) {
                value.removeSubrange(closing.lowerBound..<value.endIndex)
            }
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstJSONRoot(in text: String) -> Character? {
        for ch in text where ch == "{" || ch == "[" { return ch }
        return nil
    }

    private static func balancedSlice(in text: String, opening: Character, closing: Character) -> String? {
        guard let start = text.firstIndex(of: opening) else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                if ch == "\"" { inString = true }
                else if ch == opening { depth += 1 }
                else if ch == closing {
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

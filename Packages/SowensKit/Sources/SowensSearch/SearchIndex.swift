import Foundation
import GRDB

/// A derived, replaceable index. Never the owner of user records or their persistence.
/// Apps with existing FTS stores keep them; new consumers opt into this product explicitly.
public actor SearchIndex {
    public struct Document: Sendable {
        public let id: String
        public let text: String
        public init(id: String, text: String) { self.id = id; self.text = text }
    }
    public enum IndexError: Error { case tooManyDocuments, invalidDocument, duplicateID }
    private let queue: DatabaseQueue
    private var revision: String?

    public init() throws {
        queue = try DatabaseQueue()
        try queue.write { database in
            try database.create(virtualTable: "documents", using: FTS5()) { table in
                table.column("id").notIndexed()
                table.column("text")
                table.tokenizer = .unicode61()
            }
        }
    }

    /// One atomic replacement; validation failure leaves the previous index intact.
    public func replace(with documents: [Document], revision: String) throws {
        guard self.revision != revision else { return }
        guard documents.count <= 10_000 else { throw IndexError.tooManyDocuments }
        var ids = Set<String>()
        var totalBytes = 0
        for document in documents {
            try Task.checkCancellation()
            totalBytes += document.text.utf8.count
            guard totalBytes <= 16 * 1_024 * 1_024 else { throw IndexError.tooManyDocuments }
            guard !document.id.isEmpty, document.id.utf8.count <= 256, document.text.utf8.count <= 16_384 else {
                throw IndexError.invalidDocument
            }
            guard ids.insert(document.id).inserted else { throw IndexError.duplicateID }
        }
        try queue.write { database in
            try database.execute(sql: "DELETE FROM documents")
            for document in documents {
                try Task.checkCancellation()
                try database.execute(sql: "INSERT INTO documents (id, text) VALUES (?, ?)", arguments: [document.id, document.text])
            }
        }
        self.revision = revision
    }

    public func search(_ query: String, limit: Int = 50) throws -> [String] {
        try Task.checkCancellation()
        let tokens = String(query.prefix(512)).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(12)
        guard !tokens.isEmpty else { return [] }
        let expression = tokens.map { "\"" + $0 + "\"*" }.joined(separator: " AND ")
        return try queue.read { database in
            try String.fetchAll(database, sql: "SELECT id FROM documents WHERE documents MATCH ? ORDER BY rank, id LIMIT ?",
                                arguments: [expression, min(max(limit, 1), 100)])
        }
    }
}

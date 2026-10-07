import XCTest
@testable import Stocked

/// Real file I/O against the simulator sandbox's StockedDB. A directory placed at a key's
/// primary path makes the atomic write fail, which stands in for a full or unwritable disk.
final class LocalDatabaseDurabilityTests: XCTestCase {
    private let database = LocalDatabase.shared
    private var key = ""
    private var primaryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StockedDB", isDirectory: true)
            .appendingPathComponent("\(key).json")
    }

    override func setUp() {
        key = "durability_fixture_\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        database.delete(key: key)
        await database.flush()
        try? FileManager.default.removeItem(at: primaryURL)
    }

    private func blockWrites() throws {
        try FileManager.default.createDirectory(at: primaryURL, withIntermediateDirectories: true)
    }

    private func unblockWrites() throws {
        // `delete(key:)` may already have removed the blocking directory on the write queue.
        try? FileManager.default.removeItem(at: primaryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryURL.path))
    }

    func testFailedWriteIsRetainedAndCommittedOnRetry() async throws {
        try blockWrites()
        database.save(["kept"], key: key)
        await database.flush()
        try unblockWrites()
        await database.flush()
        XCTAssertEqual(database.load([String].self, key: key), ["kept"],
                       "A failed write must stay pending instead of being forgotten")
    }

    func testNewerSaveWinsOverRetainedFailure() async throws {
        try blockWrites()
        database.save(["old"], key: key)
        await database.flush()
        database.save(["new"], key: key)
        try unblockWrites()
        await database.flush()
        XCTAssertEqual(database.load([String].self, key: key), ["new"])
    }

    func testDeleteDiscardsRetainedFailure() async throws {
        try blockWrites()
        database.save(["deleted"], key: key)
        await database.flush()
        database.delete(key: key)
        try unblockWrites()
        await database.flush()
        XCTAssertNil(database.load([String].self, key: key), "A deleted value must not be resurrected by a retry")
    }
}

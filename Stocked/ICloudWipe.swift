// ICloudWipe.swift — deletes every Stocked backup record from the user's private iCloud
// database. This is separate from "Clear All App Data" (which wipes the local device and
// signs out): this targets only what lives in CloudKit, so a user can remove their cloud
// footprint while keeping the app set up locally, or clean up before handing off a device.
//
// Kept in its own extension file to avoid touching the high-churn KitchenTransferManager
// body. All state accessed here is @MainActor-isolated on the manager.
import CloudKit
import os

extension KitchenTransferManager {
    /// Deletes all KitchenBackup records from the private iCloud database.
    /// Reports progress through the manager's existing statusMessage / errorMessage so the
    /// Data & Storage UI reflects it with no new plumbing.
    func wipeAllICloudData() {
        statusMessage = "Deleting iCloud data…"
        errorMessage = ""

        Task { @MainActor in
            let container = CKContainer(identifier: "iCloud.Stocked")
            let db = container.privateCloudDatabase

            // Confirm the account is reachable first, so "no account" doesn't read as success.
            if let status = try? await container.accountStatus(), status != .available {
                errorMessage = status == .noAccount
                    ? "No iCloud account signed in. Sign in to iCloud to manage cloud data."
                    : "iCloud not available yet — try again in a moment."
                statusMessage = ""
                return
            }

            do {
                // Fetch all backup record IDs (ids only — we only need to delete them).
                let query = CKQuery(recordType: "KitchenBackup", predicate: NSPredicate(value: true))
                var idsToDelete: [CKRecord.ID] = []
                var cursor: CKQueryOperation.Cursor?

                let firstPage = try await db.records(matching: query, desiredKeys: [], resultsLimit: 200)
                idsToDelete.append(contentsOf: firstPage.matchResults.map { $0.0 })
                cursor = firstPage.queryCursor

                // Page through any remaining records.
                while let c = cursor {
                    let page = try await db.records(continuingMatchFrom: c, desiredKeys: [], resultsLimit: 200)
                    idsToDelete.append(contentsOf: page.matchResults.map { $0.0 })
                    cursor = page.queryCursor
                }

                if idsToDelete.isEmpty {
                    statusMessage = "No iCloud data found to delete."
                    return
                }

                // Delete in batches (CloudKit caps modify operations at 400 records).
                var deleted = 0
                for chunk in idsToDelete.chunkedForDelete(200) {
                    let op = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: chunk)
                    op.savePolicy = .allKeys
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        op.modifyRecordsResultBlock = { result in
                            switch result {
                            case .success:        cont.resume()
                            case .failure(let e): cont.resume(throwing: e)
                            }
                        }
                        db.add(op)
                    }
                    deleted += chunk.count
                }

                // A fresh device should be free to auto-restore again if the user re-backs-up
                // later; clearing this flag matches the "cloud is now empty" state.
                UserDefaults.standard.removeObject(forKey: "didAutoRestoreFromiCloud_v1")
                UserDefaults.standard.removeObject(forKey: "lastICloudBackup")

                iCloudStatus  = "No backups"
                statusMessage = deleted == 1
                    ? "Deleted 1 iCloud backup."
                    : "Deleted \(deleted) iCloud backups."
                Log.transfer.notice("iCloud wipe removed \(deleted, privacy: .public) records")
            } catch {
                errorMessage = "Couldn't delete iCloud data: \(error.localizedDescription)"
                statusMessage = ""
                Log.transfer.notice("iCloud wipe failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

private extension Array where Element == CKRecord.ID {
    /// Split into fixed-size chunks for batched CloudKit deletes.
    func chunkedForDelete(_ size: Int) -> [[CKRecord.ID]] {
        guard size > 0 else { return [self] }
        var chunks: [[CKRecord.ID]] = []
        var index = 0
        while index < count {
            let end = Swift.min(index + size, count)
            chunks.append(Array(self[index..<end]))
            index = end
        }
        return chunks
    }
}

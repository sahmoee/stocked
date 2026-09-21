// Run scripts/test-kitchen-archive.py. Fixtures use Python's independent ZIP/gzip producers.
import Foundation

@main struct KitchenArchiveChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let cases = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "zip" || $0.pathExtension == "gz" }.sorted { $0.path < $1.path }
        var checked = 0
        for url in cases {
            let input = try Data(contentsOf: url)
            let reject = url.lastPathComponent.hasPrefix("reject-")
            var failed = false
            do {
                if url.pathExtension == "gz" {
                    let output = try KitchenArchive.gunzip(input)
                    guard !reject else { fatalError("Accepted unsafe fixture: \(url.lastPathComponent)") }
                    precondition(output == Data("Original recipe text — unchanged".utf8))
                } else {
                    let entries = try KitchenArchive.read(input)
                    guard !reject else { fatalError("Accepted unsafe fixture: \(url.lastPathComponent)") }
                    let expectedURL = url.deletingPathExtension().appendingPathExtension("json")
                    let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: expectedURL))
                    precondition(entries.count == expected.count, "Entry count: \(url.lastPathComponent)")
                    for item in entries {
                        precondition(item.data == Data(base64Encoded: expected[item.name] ?? "invalid"), "Original bytes changed")
                    }
                }
            } catch { failed = true; precondition(reject, "Rejected valid fixture \(url.lastPathComponent): \(error)") }
            precondition(failed == reject)
            checked += 1
        }
        // A cancelled background read must not return a seemingly complete import.
        let semaphore = DispatchSemaphore(value: 0)
        let job = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            do {
                _ = try KitchenArchive.read(Data(repeating: 0, count: 100))
                fatalError("Cancelled read completed")
            } catch is CancellationError { } catch { fatalError("Cancellation was lost") }
            semaphore.signal()
        }
        job.cancel(); semaphore.wait()
        print("\(checked + 1) native archive checks passed (original bytes, bounds, CRC, paths, gzip and cancellation).")
    }
}

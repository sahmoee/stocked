// Native macOS check; no simulator or application data.
// xcrun swiftc -swift-version 6 Stocked/CookComputationPool.swift scripts/CookComputationChecks.swift -o /tmp/stocked-cook-checks
import Foundation

@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Int?, Never>?
    private(set) var started = false
    func wait() async -> Int? {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ value: Int) { continuation?.resume(returning: value); continuation = nil }
}

@main
struct CookComputationChecks {
    @MainActor
    static func main() async {
        let pool = CookComputationPool<Int>()
        let gate = Gate()
        var starts = 0
        var calls = 0
        let start: @MainActor () -> Task<Int?, Never> = {
            starts += 1
            return Task { await gate.wait() }
        }
        let readers = (0..<12).map { _ in
            Task { @MainActor in
                calls += 1
                return await pool.value(for: "kitchen-1", start: start)
            }
        }
        while calls < 12 || !gate.started { await Task.yield() }
        precondition(starts == 1, "Overlapping surfaces must share one calculation")
        readers[0].cancel()
        await Task.yield()
        gate.finish(42)
        for (index, reader) in readers.enumerated() {
            let answer = await reader.value
            precondition(answer == (index == 0 ? nil : 42), "One cancellation must not cancel other readers")
        }

        var cancelledStarts = 0
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await pool.value(for: "cancelled") {
                cancelledStarts += 1
                return Task { 1 }
            }
        }
        let cancelledValue = await cancelled.value
        precondition(cancelledValue == nil && cancelledStarts == 0, "Cancelled callers cannot start work")

        let invalidationGate = Gate()
        let old = Task { @MainActor in
            await pool.value(for: "kitchen-2") { Task { await invalidationGate.wait() } }
        }
        while !invalidationGate.started { await Task.yield() }
        pool.cancelAll()
        let replacement = Task { @MainActor in
            await pool.value(for: "kitchen-2") { Task { 17 } }
        }
        invalidationGate.finish(99)
        let oldValue = await old.value
        let newValue = await replacement.value
        precondition(oldValue == nil && newValue == 17, "Invalidation discards old work without deleting replacement")

        var workerCancelled = false
        var workerStarted = false
        let last = Task { @MainActor in
            await pool.value(for: "last-reader") {
                Task {
                    workerStarted = true
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { workerCancelled = true }
                    return 100
                }
            }
        }
        while !workerStarted { await Task.yield() }
        last.cancel()
        let lastValue = await last.value
        precondition(lastValue == nil && workerCancelled, "Last reader must cancel unused work immediately")
        print("PASS: shared computation, isolated cancellation, pre-cancellation, invalidation/replacement, last-reader cancellation")
    }
}

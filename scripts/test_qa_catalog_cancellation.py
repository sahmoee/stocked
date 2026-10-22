#!/usr/bin/env python3
"""Run the production QA suite orchestration against gated synthetic probes.

No app data, simulator, network, or full application build. The worker gate makes
revision invalidation and cancellation deterministic rather than timing-dependent.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def declaration(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


production = declaration((ROOT / 'Stocked/QAInvariants.swift').read_text(),
                         'static func runAllYielding(')
fixture = r'''
import Foundation

final class Control: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    // Reads occur only after the finished semaphore establishes ordering.
    func waitForFinish() -> Bool { finished.wait(timeout: .now() + 5) == .success }
    var cancelled = false
    let mode: Int
    init(_ mode: Int) { self.mode = mode }
}
struct Recipe: Sendable { let id = UUID(); let control: Control }
enum Status: Sendable { case ok, violation }
struct QAInvariantResult: Sendable {
    let name: String
    let status: Status
    let detail: String
    let critical: Bool
}
@MainActor final class GuestDataStore {
    var revision = 0
    let cookCatalog: [Recipe]
    var savedGeneratedRecipes: [Recipe] { [] }
    var inventoryItems: [Recipe] { [] }
    var inStockNameSet: Set<String> { [] }
    var userRecipes: [Recipe] { cookCatalog }
    init(_ control: Control) { cookCatalog = [Recipe(control: control)] }
}
@MainActor final class CookNowSession {}
@MainActor enum CookNowCompute {
    struct Output: Sendable {}
    static func cached(store: GuestDataStore, session: CookNowSession?) -> Output? { Output() }
    static func runYielding(store: GuestDataStore, session: CookNowSession?) async -> Output? { Output() }
    static func revisionKey(store: GuestDataStore, session: CookNowSession?) -> String { String(store.revision) }
}
@MainActor final class OnlineRecipesLoader {
    static let shared = OnlineRecipesLoader()
    let recipes: [Recipe] = []
}
struct Feature: Sendable { let name: String; let passed: Bool; let detail: String }
enum QAFeatureContracts { static func run() -> [Feature] { [] } }
@MainActor enum QAInvariants {
'''
fixture += production
fixture += r'''
    static var ok: QAInvariantResult {
        QAInvariantResult(name: "fixture", status: .ok, detail: "", critical: false)
    }
    static func noteSlowPhase(_ name: String, since: Date) {}
    nonisolated static func catalogChecks(recipes: [Recipe], generated: [Recipe],
        discover: [Recipe], inventory: [Recipe], inStockNames: Set<String>, recipeIDs: [UUID]) -> [QAInvariantResult] {
        let control = recipes[0].control
        control.started.signal()
        precondition(control.release.wait(timeout: .now() + 5) == .success, "worker gate timed out")
        control.cancelled = Task.isCancelled
        control.finished.signal()
        return [QAInvariantResult(name: "catalog", status: .ok, detail: "", critical: false)]
    }
    static func allergenExclusion(store: GuestDataStore, session: CookNowSession?,
                                  snapshot: CookNowCompute.Output) -> QAInvariantResult {
        let control = store.cookCatalog[0].control
        precondition(control.started.wait(timeout: .now() + 5) == .success, "worker did not start")
        if control.mode == 1 { store.revision += 1 }
        if control.mode == 2 { withUnsafeCurrentTask { $0?.cancel() } }
        if control.mode == 3 { control.release.signal() }
        return ok
    }
'''
for name in ['readyRecipesTrulyStocked', 'surfacedRecipesAreShowable', 'homeMatchesCookExact']:
    fixture += f'''static func {name}(store: GuestDataStore, session: CookNowSession?,
        snapshot: CookNowCompute.Output) -> QAInvariantResult {{ ok }}\n'''
for name in ['reservationMath', 'lowStockAgreement', 'expiringAgreement', 'availabilityFloorRespected']:
    fixture += f'static func {name}(store: GuestDataStore) -> QAInvariantResult {{ ok }}\n'
for name in ['classificationNotRepeating', 'workerConfigured']:
    fixture += f'static func {name}() -> QAInvariantResult {{ ok }}\n'
fixture += r'''
}
struct Failure: Error, CustomStringConvertible {
    let description: String
}
@main struct Checks {
    @MainActor static func main() async throws {
        for mode in 1...3 {
            let control = Control(mode)
            let store = GuestDataStore(control)
            let run = Task { @MainActor in
                await QAInvariants.runAllYielding(store: store, session: CookNowSession())
            }
            let results = await run.value
            if mode != 3 { control.release.signal() }
            guard control.waitForFinish() else {
                throw Failure(description: "worker completion timed out")
            }
            if mode == 3 {
                guard results.count == 11, !control.cancelled else {
                    throw Failure(description: "unchanged run must retain all ten probes and catalog results")
                }
            } else {
                guard results.isEmpty, control.cancelled else {
                    throw Failure(description: "aborted QA run left detached catalog worker uncancelled (mode \(mode))")
                }
            }
        }
        print("QA catalog lifetime: revision invalidation, parent cancellation, complete unchanged run passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='stocked-qa-cancellation-') as directory:
    source = Path(directory) / 'Checks.swift'
    source.write_text(fixture)
    binary = Path(directory) / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                    str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)

// Native Foundation-only checks; no simulator, UI automation or device sign-off.
import Foundation

@main struct QAFeatureChecks {
  static func main() {
    var total = 0
    func check(_ passed: @autoclosure () -> Bool, _ label: String) {
      guard passed() else { fatalError("FAILED: " + label) }
      total += 1
    }
    for result in QAFeatureContracts.run() { check(result.passed, result.name) }
    let sections = QAFeatureCoverage.sections
    check(sections.map(\.number) == Array(37...48), "stable appended section IDs")
    check(sections.first(where: { $0.number == 48 })?.rows.count == 11,
          "inventory redesign journeys retain all eleven stable definitions")
    let ids = sections.flatMap { section in
      section.rows.indices.map { "QA-\(section.number)-\($0 + 1)" }
    }
    check(Set(ids).count == ids.count, "unique feature check IDs")
    check(
      sections.allSatisfy { !$0.title.isEmpty && !$0.rows.isEmpty },
      "coverage sections named and populated")
    check(sections.allSatisfy { $0.rows.allSatisfy { !$0.0.isEmpty } }, "all checks actionable")
    for verdict in ["untested", "fail", "blocked", "unknown"] {
      check(
        QAFeatureCoverage.isOpenBlocker(blocker: true, verdict: verdict), "non-pass blocks sign-off"
      )
      check(
        !QAFeatureCoverage.isOpenBlocker(blocker: false, verdict: verdict),
        "non-blocker does not block")
    }
    check(
      !QAFeatureCoverage.isOpenBlocker(blocker: true, verdict: "pass"), "tested pass closes blocker"
    )
    check(
      !QAAccessibilityAuditPolicy.shouldAudit(
        isAccessibilityElement: false, isControl: false, hasButtonOrLinkTrait: false,
        isUserInteractionEnabled: true, hasTapOrLongPressGesture: true),
      "interactive implementation container is not a VoiceOver stop")
    check(
      QAAccessibilityAuditPolicy.shouldAudit(
        isAccessibilityElement: true, isControl: true, hasButtonOrLinkTrait: true,
        isUserInteractionEnabled: true, hasTapOrLongPressGesture: false),
      "exposed accessibility control is audited")
    check(
      !QAFeatureCoverage.requiresRetest(
        id: "QA-01-01", storedDefinition: nil, currentDefinition: "Original"),
      "unchanged legacy check retained")
    for id in ["QA-16-01", "QA-16-09", "QA-18-07"] {
      check(
        QAFeatureCoverage.requiresRetest(id: id, storedDefinition: nil, currentDefinition: "New"),
        "changed legacy semantics require retest")
      check(
        !QAFeatureCoverage.requiresRetest(
          id: id, storedDefinition: "New", currentDefinition: "New"), "retested definition retained"
      )
    }
    check(
      QAFeatureCoverage.requiresRetest(
        id: "QA-37-01", storedDefinition: "Old", currentDefinition: "New"),
      "future definition edit invalidates verdict")
    let first = UUID()
    let second = UUID()
    check(
      FinderWebPolicy.recipeIdentity(sourceURL: nil, id: first)
        != FinderWebPolicy.recipeIdentity(sourceURL: nil, id: second),
      "personal recipes have distinct identities")
    check(
      FinderWebPolicy.recipeIdentity(sourceURL: "  ", id: first)
        == FinderWebPolicy.recipeIdentity(sourceURL: nil, id: first),
      "empty source uses stable saved ID")
    check(
      FinderWebPolicy.recipeIdentity(
        sourceURL: "https://www.example.com/rice/?utm_source=x#recipe", id: first)
        == FinderWebPolicy.recipeIdentity(sourceURL: "https://example.com/rice", id: second),
      "same publisher canonical identity")
    check(
      FinderWebPolicy.mergedCount(
        localCount: 8005, localIdentities: ["page8005"], webIdentities: ["page8005", "new"])
        == 8006, "global count beyond 8000")
    check(
      FinderWebPolicy.mergedCount(localCount: 0, localIdentities: [], webIdentities: ["a", "b"])
        == 2, "web-only results")
    check(
      FinderWebPolicy.mergedCount(
        localCount: 3, localIdentities: ["a", "b", "c"], webIdentities: []) == 3,
      "offline results remain")
    var request = FinderRequestState()
    let firstQuery = request.begin()
    check(
      request.preview(firstQuery, count: 4) && request.count == 4 && request.isWorking
        && !request.isBlocking,
      "early cards become usable while enrichment continues")
    check(
      request.complete(firstQuery, count: 6) && request.count == 6, "web additions finish count")
    check(
      !request.preview(firstQuery, count: 4) && request.count == 6,
      "late partial cannot replace final")
    let retry = request.begin()
    check(request.count == 0, "new query does not show stale count")
    check(
      request.fail(retry) && !request.preview(retry, count: 3), "failed query rejects late partial")
    let cancel = request.begin()
    request.cancel()
    check(!request.preview(cancel, count: 3), "cancelled partial rejected")
    print(
      "\(total) QA feature checks passed; \(ids.count) device checks defined (not marked passed).")
  }
}

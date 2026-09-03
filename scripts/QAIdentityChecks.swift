import Foundation

@main struct QAIdentityChecks {
    static func main() throws {
        var total = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), label); total += 1
        }
        check(QATester.key.name == "Key", "Key label")
        check(QATester.shalise.name == "Shalise", "Shalise label")
        for (identifier, expected) in [("iPhone18,3", "iPhone 17"), ("iPhone18,1", "iPhone 17 Pro"),
            ("iPhone18,2", "iPhone 17 Pro Max"), ("iPad17,1", "iPad Pro 11-inch (M5)")] {
            check(QADeviceModels.name(identifier: identifier, fallback: "Unknown") == expected, "exact hardware model")
        }
        check(QADeviceModels.name(identifier: "iPhone99,1", fallback: "Unknown") == "iPhone (iPhone99,1)", "unknown hardware remains honest")
        check(QADeviceModels.family(identifier: "iPad99,1", fallback: "Unknown") == "iPad", "unknown iPad retains family")
        let devices = (0..<4).map { index in
            QAReportIdentity(deviceFamily: index % 2 == 0 ? "iPhone" : "iPad",
                deviceModel: index % 2 == 0 ? "iPhone 17 Pro" : "iPad Pro",
                modelIdentifier: index % 2 == 0 ? "iPhone18,1" : "iPad17,1",
                installationID: UUID().uuidString, isSimulator: false)
                .assigning(index < 2 ? .key : .shalise)
        }
        check(Set(devices.map { QAReportIdentity.ticketNumber(build: 100, sequence: 1,
            installationID: $0.installationID) }).count == 4, "four devices never collide")
        for a in devices.indices { for b in devices.indices {
            check(QAReportIdentity.sameOrigin(devices[a], devices[b]) == (a == b), "origin isolation")
        }}
        let captured = devices[0]
        let reassigned = captured.assigning(.shalise)
        check(captured.testerID == "key", "capture remains immutable")
        check(reassigned.installationID == captured.installationID && reassigned.modelIdentifier == captured.modelIdentifier, "assignment preserves original hardware")
        check(!QAReportIdentity.sameOrigin(captured, reassigned), "tester isolation on one device")
        check(reassigned.assigning(.unassigned).testerID == nil, "explicit unassignment")
        let legacy = QAReportIdentity.legacy(device: "iPad").assigning(.key)
        check(legacy.modelIdentifier.isEmpty && legacy.installationID.isEmpty, "no guessed legacy hardware")
        check(legacy.deviceFamily == "iPad", "legacy family")
        check(!QAReportIdentity.sameOrigin(nil, nil), "legacy reports never auto coalesce")
        check(!QAReportIdentity.sameOrigin(legacy, legacy), "unknown installation never coalesces")
        check(QAReportIdentity.decode(captured.dictionary) == captured, "wire round trip")
        let decoded = try JSONDecoder().decode(QAReportIdentity.self, from: JSONEncoder().encode(captured))
        check(decoded == captured, "disk round trip")
        check(QAReportIdentity.decode(["deviceFamily": "iPhone"]) == nil, "partial unsupported identity remains unknown")
        for status in ["open", "inProgress", "refiled", "unknown"] {
            check(QATicketLifecycle.needsAttention(status: status, manualReview: false), "active status")
        }
        check(!QATicketLifecycle.needsAttention(status: "fixed", manualReview: false), "fixed completed")
        check(QATicketLifecycle.needsAttention(status: "fixed", manualReview: true), "manual review stays active")
        check(!QATicketLifecycle.needsAttention(status: "verified", manualReview: true), "verified closes review")
        check(!QATicketLifecycle.needsAttention(status: "wontFix", manualReview: false), "wontFix archived")
        check(QATicketLifecycle.shouldReopen(status: "fixed", manualReview: false, automatic: true, sameOrigin: true, sameCheck: true), "fresh regression reopens")
        for flags in [(false, true, true), (true, false, true), (true, true, false)] {
            check(!QATicketLifecycle.shouldReopen(status: "fixed", manualReview: false,
                automatic: flags.0, sameOrigin: flags.1, sameCheck: flags.2), "unrelated report never reopens")
        }
        check(!QATicketLifecycle.shouldReopen(status: "wontFix", manualReview: false, automatic: true, sameOrigin: true, sameCheck: true), "wontFix never auto reopens")
        check(!QATicketLifecycle.shouldReopen(status: "fixed", manualReview: true, automatic: true, sameOrigin: true, sameCheck: true), "review still pending")
        for verdict in ["fail", "blocked"] {
            check(QATicketLifecycle.completedCheck(verdict: verdict, status: "fixed", manualReview: false), "fixed issue leaves active checks")
            check(!QATicketLifecycle.completedCheck(verdict: verdict, status: "open", manualReview: false), "regression restores failure")
            check(!QATicketLifecycle.completedCheck(verdict: verdict, status: "fixed", manualReview: true), "manual review stays open")
        }
        for verdict in ["untested", "pass"] {
            check(!QATicketLifecycle.completedCheck(verdict: verdict, status: "fixed", manualReview: false), "real test verdict preserved")
        }
        print("\(total) QA identity/lifecycle checks passed (no simulator).")
    }
}

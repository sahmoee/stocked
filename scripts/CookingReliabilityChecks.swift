// xcrun swiftc Stocked/CookingTimerPolicy.swift Stocked/StepTimer.swift Stocked/UnitMath.swift Stocked/UnitConverter.swift scripts/CookingReliabilityChecks.swift -o /tmp/stocked-cooking-reliability
import Foundation

@main struct CookingReliabilityChecks {
    @MainActor static func main() async {
        var checks = 0
        func check(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
        let durations: [(String, Int?)] = [
            ("Bake for 30 minutes", 1800), ("Simmer 1 hour 30 minutes", 5400),
            ("Wait one hour and 30 minutes", 5400), ("Cook 1½ hours", 5400),
            ("Wait ½ hour", 1800), ("Wait 1 1/2 hours", 5400), ("Wait 1/4 hour", 900),
            ("Wait ⅓ hour", 1200), ("Wait 2¾ minutes", 165), ("Wait half hour", 1800),
            ("Bake 10–15 minutes", 900), ("Bake 10 to 15 minutes", 900),
            ("Bake 30 minutes, cool 10 minutes", 1800), ("Cook 1 hour then rest 30 minutes", 3600),
            ("Wait 1 minute and 5 seconds", 65), ("Wait 45 seconds", 45),
            ("Bake at 350 degrees for 20 min", 1200), ("Cook 0 minutes", nil),
            ("Cook -5 minutes", nil), ("Cook 1/0 hour", nil), ("Chop onions", nil),
            ("Wait 999999999999999999999999999999999999999 hours", nil),
            ("Cook 31 days", nil), ("Cook 721 hours", nil), ("Cook 720 hours", 2592000),
            (String(repeating: "x", count: 32769) + "1 minute", nil)
        ]
        for (text, expected) in durations { check(CookingTimerPolicy.detectSeconds(in: text) == expected, text) }
        let now = Date(timeIntervalSince1970: 1000)
        check(CookingTimerPolicy.remaining(until: now.addingTimeInterval(0.1), now: now, total: 10) == 1, "fractional final second is not lost")
        check(CookingTimerPolicy.remaining(until: now.addingTimeInterval(-10), now: now, total: 10) == 0, "expired")
        check(CookingTimerPolicy.remaining(until: Date(timeIntervalSince1970: .infinity), now: now, total: 10) == 0, "nonfinite deadline")
        check(CookingTimerPolicy.remaining(until: .distantFuture, now: now, total: 10) == 10, "future deadline bounded to total")
        check(CookingTimerPolicy.display(5401) == "1:30:01", "hours readable")
        check(CookingTimerPolicy.display(-10) == "0:00", "negative clock")
        check(CookingTimerPolicy.spoken(3661) == "1 hour, 1 minute, 1 second", "spoken duration")
        let timer = StepTimer(stepIndex: 1, seconds: 10)
        var finished = 0
        check(timer.start(now: now) { _ in finished += 1 }, "first start")
        let deadline = timer.endDate
        check(!timer.start(now: now) { _ in finished += 100 }, "duplicate start rejected")
        timer.refresh(now: now.addingTimeInterval(7.3))
        check(timer.remaining == 3 && timer.endDate == deadline, "elapsed deadline replaces tick counting")
        timer.pause(now: now.addingTimeInterval(8.2))
        check(timer.remaining == 2 && !timer.isRunning && timer.endDate == nil, "pause captures current real remaining")
        check(timer.start(now: now.addingTimeInterval(30)) { _ in finished += 1 }, "resume")
        timer.refresh(now: now.addingTimeInterval(33))
        check(timer.isFinished && timer.remaining == 0 && timer.progress == 1, "finished deadline")
        check(!timer.start(now: now) { _ in finished += 100 }, "finished timer cannot restart accidentally")
        timer.reset(); check(!timer.isFinished && timer.remaining == 10 && timer.progress == 0, "reset")
        let restored = StepTimer(stepIndex: 2, seconds: 10, remaining: 3)
        let savedDeadline = now.addingTimeInterval(2.2)
        check(restored.start(now: now, restoringDeadline: savedDeadline) { _ in }, "restore starts from saved deadline")
        check(restored.endDate == savedDeadline, "restore does not extend fractional deadline")
        restored.pause(now: now)
        check(!restored.start(now: now, restoringDeadline: Date(timeIntervalSince1970: .infinity)) { _ in }, "nonfinite restored deadline rejected")
        check(!restored.start(now: now, restoringDeadline: now) { _ in }, "expired restored deadline rejected")
        check(restored.start(now: now, restoringDeadline: .distantFuture) { _ in }, "future restore starts")
        check(restored.endDate == now.addingTimeInterval(3), "future restore bounded to remaining")
        restored.pause(now: now)
        let repaired = StepTimer(stepIndex: 0, seconds: 20, remaining: 100)
        check(repaired.remaining == 20, "restore excessive remaining clamped")
        let invalid = StepTimer(stepIndex: 0, seconds: -1)
        check(invalid.isFinished && !invalid.start { _ in }, "zero/negative total not scheduled")
        weak var released: StepTimer?
        do { let temporary = StepTimer(stepIndex: 4, seconds: 30); released = temporary; temporary.start { _ in } }
        check(released == nil, "task does not retain abandoned timer")
        let live = StepTimer(stepIndex: 5, seconds: 1)
        live.start { _ in finished += 1 }; live.start { _ in finished += 100 }
        try? await Task.sleep(for: .milliseconds(1250))
        check(finished == 1 && live.isFinished, "actual task finishes once")
        let canceled = StepTimer(stepIndex: 6, seconds: 1)
        canceled.start { _ in finished += 100 }; canceled.pause()
        try? await Task.sleep(for: .milliseconds(1100))
        check(finished == 1 && !canceled.isRunning, "paused task cannot finish later")
        let aliases = [" ml. ", "milliliters", "litres", "fl.  oz.", "fluid ounces", "pints", "quarts", "gallons", "kg.", "kilograms", "lbs"]
        for alias in aliases {
            check(UnitMath.baseFactor(for: alias) != nil, "base alias \(alias)")
            check(UnitConverter.kind(of: alias) != .count, "display alias \(alias)")
        }
        for amount in [Double.nan, .infinity, -.infinity, -1] { check(UnitMath.convert(amount, from: "g", to: "g") == nil, "invalid same-unit amount") }
        check(UnitMath.convert(.greatestFiniteMagnitude, from: "kg", to: "g") == nil, "conversion overflow fails closed")
        check(UnitMath.convert(500, from: "g", to: "kg") == 0.5, "mass factor")
        check(UnitMath.convert(1, from: "cup", to: "g") == nil, "no density inferred for merge")
        check(UnitMath.convert(0, from: "g", to: "kg") == 0, "zero preserved")
        check(UnitMath.convert(5, from: "cans", to: " cans ") == 5, "same unknown unit remains compatible")
        check(UnitConverter.convert(amount: 2, unit: "litres", ingredient: "", to: .metric).unit == "l", "plural unit converts")
        check(UnitConverter.convert(amount: 1.01, unit: "cups", ingredient: "", to: .us).unit == "cup", "rounded displayed singular")
        check(ReminderClockPolicy.hour(0) == 0, "midnight retained")
        check(ReminderClockPolicy.hour(nil) == 7, "unset morning default")
        check(ReminderClockPolicy.hour(-1) == 0 && ReminderClockPolicy.hour(50) == 23, "hour bounds")
        check(ReminderClockPolicy.minute(-1) == 0 && ReminderClockPolicy.minute(90) == 59, "minute bounds")
        print("Cooking reliability: \(checks) checks passed")
    }
}

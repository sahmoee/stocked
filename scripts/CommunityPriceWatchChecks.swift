// xcrun swiftc Stocked/CommunityPricesCore.swift scripts/CommunityPriceWatchChecks.swift -o /tmp/stocked-community-watch-checks
import Foundation

@main struct CommunityPriceWatchChecks {
    static func main() throws {
        var count = 0
        func check(_ condition: Bool, _ label: String) { count += 1; precondition(condition, label) }
        func rejects(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        let now = CommunityPriceWatchEngine.day("2026-09-05")!
        var watch = CommunityPriceWatch(); watch.label = "Milk"; watch.barcode = "12345678"; watch.targetPrice = 3
        func row(_ id: Int = 1, price: Double = 2.5, currency: String = "USD", day: String? = "2026-09-05", basis: String? = "UNIT", discount: Bool = false, city: String? = "Chicago", country: String? = "US") -> CommunityPriceResponse.Observation {
            .init(id: id, price: price, currency: currency, observedAt: day, pricePer: basis, discounted: discount,
                  discountType: nil, regularPrice: nil, store: "Fixture store", city: city, country: country,
                  sourceURL: "https://prices.openfoodfacts.org/prices/1")
        }
        func result(_ rows: [CommunityPriceResponse.Observation], _ rule: CommunityPriceWatch? = nil) throws -> CommunityPriceWatchEngine.Result {
            try CommunityPriceWatchEngine.evaluate(rows, watch: rule ?? watch, now: now)
        }
        check(try result([row()]).match?.price == 2.5, "exact currency and per-item report qualifies")
        check(try result([row(price: 3)]).match != nil, "target boundary includes exact price")
        check(try result([row(price: 3.01)]).match == nil, "above target excluded")
        check(try result([row(price: .nan), row(2, price: .infinity), row(3, price: -1)]).excluded == 3, "invalid prices excluded")
        check(try result([row(currency: "EUR")]).match == nil, "never convert currencies")
        check(try result([row(basis: "KILOGRAM"), row(2, basis: nil)]).excluded == 2, "never compare different or unknown bases")
        check(try result([row(discount: true)]).match == nil, "discounts off by default")
        var changed = watch; changed.includeDiscounts = true
        check(try result([row(discount: true)], changed).match != nil, "explicit discounts allowed")
        check(try result([row(day: nil), row(2, day: "unknown"), row(3, day: "2026-02-30")]).excluded == 3, "unknown impossible dates excluded")
        check(try result([row(day: "2026-09-06")]).match == nil, "future reports excluded")
        changed = watch; changed.maximumAgeDays = 1
        check(try result([row(day: "2026-09-04")], changed).match == nil, "one day includes today only")
        check(try result([row()], changed).match != nil, "today accepted")
        changed.maximumAgeDays = 2
        check(try result([row(day: "2026-09-04")], changed).match != nil, "yesterday inside two-day window")
        changed = watch; changed.country = "us"; changed.city = " CHICAGO "
        check(try result([row()], changed).match != nil, "location exact labels normalize")
        check(try result([row(city: "New Chicago")], changed).match == nil, "city is not substring match")
        check(try result([row(country: nil)], changed).match == nil, "unknown location fails specific location")
        check(try result([row(2, price: 2.7), row(1), row(3, price: 1.5)]).match?.id == 3, "lowest eligible price chosen")
        check(try result([row(2, day: "2026-09-04"), row(3), row(1)]).match?.id == 1, "newest date then stable ID ties")
        let many = (1...30).map { row($0, price: $0 == 30 ? 0.01 : 2) }
        check(try result(many).match?.id == 1, "work bounded to25 provider records")
        check(try result([]).match == nil, "empty response not fabricated price")
        check(CommunityPriceWatchEngine.alertKey(row()) == CommunityPriceWatchEngine.alertKey(row()), "same observation alert is stable")
        check(CommunityPriceWatchEngine.alertKey(row()) != CommunityPriceWatchEngine.alertKey(row(price: 2)), "changed observation can alert again")
        changed = watch; changed.targetPrice = .nan
        check(rejects { _ = try changed.validated() }, "nonfinite target rejected")
        changed = watch; changed.targetPrice = 0
        check(rejects { _ = try changed.validated() }, "zero target rejected")
        changed = watch; changed.currency = "US"
        check(rejects { _ = try changed.validated() }, "invalid currency rejected")
        changed = watch; changed.country = "USA"
        check(rejects { _ = try changed.validated() }, "invalid country rejected")
        changed = watch; changed.maximumAgeDays = 366
        check(rejects { _ = try changed.validated() }, "bounded age")
        changed = watch; changed.barcode = "１２３４５６７８"
        check(rejects { _ = try changed.validated() }, "ASCII barcode only")
        changed = watch; changed.label = String(repeating: "x", count: 81)
        check(rejects { _ = try changed.validated() }, "bounded label")
        changed = watch; changed.match = row(); changed.failure = "Previous result kept"; changed.lastAlertKey = "fixture"
        let decoded = try JSONDecoder().decode(CommunityPriceWatch.self, from: JSONEncoder().encode(changed))
        check(decoded == changed, "local preference/result roundtrip")
        check(CommunityPriceWatchEngine.day("2024-02-29") != nil && CommunityPriceWatchEngine.day("2025-02-29") == nil, "leap day verified")
        print("Community price watches: \(count) native checks passed")
    }
}

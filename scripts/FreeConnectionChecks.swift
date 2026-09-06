import Foundation

nonisolated protocol HouseholdSyncable: Codable, Identifiable, Sendable where ID == UUID {
    var updatedAt: Double { get set }; var lastWriterID: String { get set }
}

actor FixtureConnectionTransport: KitchenConnectionTransport {
    var responses: [KitchenConnectionResponse]
    var requests: [URLRequest] = []
    let mirrorWriteOnGET: Bool
    let changeMirroredBody: Bool
    init(_ responses: [KitchenConnectionResponse], mirrorWriteOnGET: Bool = false, changeMirroredBody: Bool = false) {
        self.responses = responses; self.mirrorWriteOnGET = mirrorWriteOnGET; self.changeMirroredBody = changeMirroredBody
    }
    func send(_ request: URLRequest, origin: URL, maximumBytes: Int) async throws -> KitchenConnectionResponse {
        try Task.checkCancellation()
        guard KitchenConnectionPolicy.sameOrigin(origin, request.url!) else { throw KitchenConnectionFailure.endpoint }
        requests.append(request)
        if responses.isEmpty, mirrorWriteOnGET, request.httpMethod == "GET", let body = requests.last(where: { $0.httpMethod == "PUT" })?.httpBody {
            let result = changeMirroredBody ? Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: "Meal copy from Stocked", with: "Edited outside Stocked").utf8) : body
            return KitchenConnectionResponse(status: 200, data: result, etag: "\"after-put\"")
        }
        guard !responses.isEmpty else { throw KitchenConnectionFailure.response }
        return responses.removeFirst()
    }
}

@main struct FreeConnectionChecks {
    static var count = 0
    static func check(_ result: Bool, _ message: String) { guard result else { fatalError(message) }; count += 1 }
    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); fatalError("Expected rejection: \(message)") } catch { count += 1 }
    }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    static func main() async throws {
        let base = try KitchenConnectionPolicy.endpoint("https://kitchen.example:443/grocy/api")
        for value in ["http://kitchen.example", "https://you:secret@kitchen.example", "https://kitchen.example?key=secret", "https://kitchen.example#fragment", "https://kitchen.example/\n"] {
            rejects("Bad endpoint") { _ = try KitchenConnectionPolicy.endpoint(value) }
        }
        check(KitchenConnectionPolicy.sameOrigin(base, URL(string: "https://kitchen.example/other")!), "Default HTTPS port equivalence")
        check(!KitchenConnectionPolicy.sameOrigin(base, URL(string: "https://kitchen.example:444/other")!), "Port change not authorized")
        rejects("Cross-origin calendar href") { _ = try KitchenConnectionPolicy.href("https://other.example/calendar/", relativeTo: base) }
        rejects("Credential-bearing href") { _ = try KitchenConnectionPolicy.href("https://you:password@kitchen.example/calendar/", relativeTo: base) }
        check(try KitchenConnectionPolicy.href("/calendars/home/", relativeTo: base).absoluteString.hasSuffix("/calendars/home/"), "Relative same-origin href")

        let products = try json([["id": "1", "name": "Rice", "qu_id_stock": "1"], ["id": "2", "name": "Milk", "qu_id_stock": "2"]])
        let units = try json([["id": "1", "name": "kg"], ["id": "2", "name": "Piece"]])
        let stock = try json([["product_id": "1", "amount": "2.5", "best_before_date": "2026-09-20"], ["product_id": "2", "amount": "3"]])
        let shopping = try json([["id": "8", "product_id": "2", "amount": "2", "note": "For breakfast"]])
        let rows = try GrocyReadParser.parse(stock: stock, shopping: shopping, products: products, units: units)
        check(rows.count == 3, "Stock and shopping parsed")
        check(rows[0].suggestedContainers == nil && rows[0].remoteAmount == "2.5" && rows[0].unit == "kg", "Weight is not converted to containers")
        check(rows[1].suggestedContainers == 3, "Explicit integer count unit")
        check(rows[2].suggestedContainers == 2 && rows[2].kind == .shopping, "Shopping uses product stock unit")
        check(rows[0].note.contains("Earliest"), "Aggregate due date remains context")
        check(try rows == GrocyReadParser.parse(stock: stock, shopping: shopping, products: products, units: units), "Stable source hashes")
        let fractionalCount = try GrocyReadParser.parse(stock: json([["product_id": 2, "amount": 1.5]]), shopping: json([]), products: products, units: units)
        check(fractionalCount.first?.suggestedContainers == nil, "Fractional counts need review")
        let emptyStock = try GrocyReadParser.parse(stock: json([["product_id": 2, "amount": 0]]), shopping: json([]), products: products, units: units)
        check(emptyStock.isEmpty, "Zero stock does not create positive food")
        rejects("Bad stock amount") { _ = try GrocyReadParser.parse(stock: json([["product_id": 2, "amount": true]]), shopping: json([]), products: products, units: units) }
        rejects("Negative amount") { _ = try GrocyReadParser.parse(stock: json([["product_id": 2, "amount": -1]]), shopping: json([]), products: products, units: units) }
        rejects("Duplicate remote identity") { _ = try GrocyReadParser.parse(stock: json([["product_id": 2, "amount": 1], ["product_id": 2, "amount": 2]]), shopping: json([]), products: products, units: units) }
        rejects("Oversized row count") { _ = try GrocyReadParser.parse(stock: json(Array(repeating: ["product_id": 2, "amount": 1], count: 501)), shopping: json([]), products: products, units: units) }

        let xml = """
        <?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:response><d:href>/calendars/me/meals/</d:href><d:propstat><d:prop><d:displayname>Our meals &amp; plans</d:displayname><d:resourcetype><d:collection/><c:calendar/></d:resourcetype><c:supported-calendar-component-set><c:comp name="VEVENT"/></c:supported-calendar-component-set></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>https://other.example/calendar/</d:href><d:propstat><d:prop><d:resourcetype><c:calendar/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/calendars/me/not-a-calendar/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """
        let calendars = try CalDAVReadParser.calendars(Data(xml.utf8), base: base)
        check(calendars.count == 1 && calendars[0].title == "Our meals & plans", "Only same-origin calendar collections")
        rejects("Entity declaration") { _ = try CalDAVReadParser.calendars(Data("<!DOCTYPE foo [<!ENTITY x SYSTEM 'https://other.example'>]><foo>&x;</foo>".utf8), base: base) }
        rejects("Non-UTF8 XML") { _ = try CalDAVReadParser.calendars(xml.data(using: .utf16)!, base: base) }
        rejects("Malformed XML") { _ = try CalDAVReadParser.calendars(Data("<broken>".utf8), base: base) }
        let errorXML = xml.replacingOccurrences(of: "200 OK", with: "404 Not Found")
        check(try CalDAVReadParser.calendars(Data(errorXML.utf8), base: base).isEmpty, "Failed properties never list calendars")
        let splitProperties = """
        <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:response><d:href>/calendars/me/tasks/</d:href>
        <d:propstat><d:prop><d:resourcetype><c:calendar/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
        <d:propstat><d:prop><c:supported-calendar-component-set><c:comp name="VTODO"/></c:supported-calendar-component-set></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
        </d:response></d:multistatus>
        """
        check(try CalDAVReadParser.calendars(Data(splitProperties.utf8), base: base).isEmpty, "Task-only calendar rejected across split successful properties")
        check(try CalDAVReadParser.calendars(Data(splitProperties.replacingOccurrences(of: "VTODO", with: "VEVENT").utf8), base: base).count == 1, "Event support retained across split successful properties")

        let meal = CalDAVMeal(id: "dated:fixture-id", civilDate: "2026-12-31", title: "Soup; rice, vegetables", mealType: "Dinner", servings: 2)
        let instant = ISO8601DateFormatter().date(from: "2026-09-05T12:00:00Z")!
        let body = try CalDAVMealExport.calendar(meal, now: instant)
        let text = String(decoding: body, as: UTF8.self)
        check(text.contains("DTEND;VALUE=DATE:20270101"), "Exclusive all-day end crosses year safely")
        check(text.contains("Soup\\; rice\\, vegetables"), "Calendar escaping")
        check(CalDAVMealExport.isOwnEvent(body, uid: meal.uid), "Recognizes own event")
        check(!CalDAVMealExport.isOwnEvent(body, uid: "unrelated"), "Unrelated UID rejected")
        check(!text.contains("ingredients") && !text.contains("household"), "Export only meal display fields")
        check(text.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 }, "UTF8 line folding")
        check(CalDAVMealExport.strongETag("W/\"weak\"") == nil && CalDAVMealExport.strongETag("\"strong\"") != nil, "Only strong ETags")
        check(CalDAVMealExport.strongETag("\"one\", \"two\"") == nil, "Multiple ETags cannot weaken If-Match")
        let foreign = Data(text.replacingOccurrences(of: "END:VEVENT", with: "ATTENDEE:mailto:other@example.invalid\r\nEND:VEVENT").utf8)
        check(!CalDAVMealExport.isOwnEvent(foreign, uid: meal.uid), "Invitation/scheduling event never overwritten")
        let url = calendars[0].url.appendingPathComponent(meal.filename)
        let response = KitchenConnectionResponse(status: 200, data: body, etag: "\"one\"")
        let receipt = CalDAVWriteReceipt(uid: meal.uid, etag: "\"one\"", bodyHash: KitchenConnectionPolicy.hash(body), contentKey: meal.contentKey, savedAt: instant)
        check(CalDAVConnectionClient.review(meal, url: url, response: response, receipt: nil).action == .conflict, "No local baseline never claims an existing event")
        check(CalDAVConnectionClient.review(meal, url: url, response: response, receipt: receipt).action == .unchanged, "No-op recognized")
        let changedMeal = CalDAVMeal(id: meal.id, civilDate: "2027-01-01", title: "Updated soup", mealType: meal.mealType, servings: 4)
        check(changedMeal.uid == meal.uid && changedMeal.filename == meal.filename, "Dated event identity survives date/title changes")
        check(CalDAVConnectionClient.review(changedMeal, url: url, response: response, receipt: receipt).action == .update, "Unchanged own remote may be reviewed for update")
        check(CalDAVConnectionClient.review(changedMeal, url: url, response: KitchenConnectionResponse(status: 200, data: body, etag: "\"new\""), receipt: receipt).action == .conflict, "Concurrent remote edit protected")
        check(CalDAVConnectionClient.review(changedMeal, url: url, response: KitchenConnectionResponse(status: 200, data: foreign, etag: "\"one\""), receipt: receipt).action == .conflict, "Body change protected even with reused ETag")

        let credentials = KitchenConnectionCredentials(endpoint: "https://kitchen.example/calendars/me/", username: "fixture-user", secret: "fixture-only")
        let create = CalDAVConnectionClient.review(meal, url: url, response: KitchenConnectionResponse(status: 404, data: Data(), etag: nil), receipt: nil)
        check(create.action == .create, "Missing resource becomes reviewed create")
        let createTransport = FixtureConnectionTransport([KitchenConnectionResponse(status: 201, data: Data(), etag: "\"created\"")])
        let createdReceipt = try await CalDAVConnectionClient.publish(create, credentials: credentials, transport: createTransport)
        let createRequests = await createTransport.requests
        check(createRequests.count == 1 && createRequests[0].httpMethod == "PUT" && createRequests[0].value(forHTTPHeaderField: "If-None-Match") == "*", "Create always conditional")
        check(createdReceipt.etag == "\"created\"" && createdReceipt.uid == meal.uid, "Strong write receipt captured")
        let update = CalDAVConnectionClient.review(changedMeal, url: url, response: response, receipt: receipt)
        let updateTransport = FixtureConnectionTransport([KitchenConnectionResponse(status: 204, data: Data(), etag: "\"two\"")])
        _ = try await CalDAVConnectionClient.publish(update, credentials: credentials, transport: updateTransport)
        let updateRequests = await updateTransport.requests
        check(updateRequests[0].value(forHTTPHeaderField: "If-Match") == "\"one\"" && updateRequests[0].value(forHTTPHeaderField: "If-None-Match") == nil, "Update always tied to reviewed ETag")
        let exactFallback = FixtureConnectionTransport([KitchenConnectionResponse(status: 201, data: Data(), etag: nil)], mirrorWriteOnGET: true)
        let fallbackReceipt = try await CalDAVConnectionClient.publish(create, credentials: credentials, transport: exactFallback)
        check(fallbackReceipt.etag == "\"after-put\"", "Missing PUT ETag permits an exact-byte GET baseline")
        let racedFallback = FixtureConnectionTransport([KitchenConnectionResponse(status: 201, data: Data(), etag: nil)], mirrorWriteOnGET: true, changeMirroredBody: true)
        do {
            _ = try await CalDAVConnectionClient.publish(create, credentials: credentials, transport: racedFallback)
            fatalError("GET after PUT must not adopt another writer's edit")
        } catch KitchenConnectionFailure.conflict { count += 1 }
        let grocyTransport = FixtureConnectionTransport([stock, shopping, products, units].map { KitchenConnectionResponse(status: 200, data: $0, etag: nil) })
        _ = try await GrocyConnectionClient.read(KitchenConnectionCredentials(endpoint: "https://kitchen.example/grocy", secret: "fixture-only"), transport: grocyTransport)
        let grocyRequests = await grocyTransport.requests
        check(grocyRequests.count == 4 && grocyRequests.allSatisfy { $0.httpMethod == "GET" }, "Grocy strictly read-only")
        check(grocyRequests.allSatisfy { $0.value(forHTTPHeaderField: "GROCY-API-KEY") == "fixture-only" && !($0.url?.query?.contains("fixture-only") ?? false) }, "Grocy secret in header only")
        check(grocyRequests[0].url?.path == "/grocy/api/stock", "Subpath endpoint retained")
        let revokedGrocy = FixtureConnectionTransport([KitchenConnectionResponse(status: 200, data: stock, etag: nil)])
        let guardedGrocy = KitchenGuardedConnectionTransport(transport: revokedGrocy, verifyCurrent: {
            // Model reset/revocation as soon as the first in-flight response finishes.
            guard await revokedGrocy.requests.isEmpty else { throw KitchenConnectionFailure.changed }
        })
        do {
            _ = try await GrocyConnectionClient.read(KitchenConnectionCredentials(endpoint: "https://kitchen.example/grocy", secret: "fixture-only"), transport: guardedGrocy)
            fatalError("Revocation must stop the remaining three Grocy requests")
        } catch KitchenConnectionFailure.changed { count += 1 }
        check(await revokedGrocy.requests.count == 1, "Only the already-dispatched Grocy request completes after revocation")
        let revokedCalendar = FixtureConnectionTransport([KitchenConnectionResponse(status: 201, data: Data(), etag: nil)], mirrorWriteOnGET: true)
        let guardedCalendar = KitchenGuardedConnectionTransport(transport: revokedCalendar, verifyCurrent: {
            guard await revokedCalendar.requests.isEmpty else { throw KitchenConnectionFailure.changed }
        })
        do {
            _ = try await CalDAVConnectionClient.publish(create, credentials: credentials, transport: guardedCalendar)
            fatalError("Revocation must stop the missing-ETag follow-up GET")
        } catch KitchenConnectionFailure.changed { count += 1 }
        check(await revokedCalendar.requests.count == 1, "CalDAV does not send a fallback request after revocation")
        print("Free connections: \(count) native checks passed; no real server or Keychain item was used.")
    }
}

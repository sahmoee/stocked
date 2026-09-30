import XCTest
import Kingfisher
@testable import SowensImages

private actor FetchCounter {
    var count = 0
    func fetched() { count += 1 }
}

final class PhotoLoaderTests: XCTestCase {
    func testInvalidURLsNeverFetch() async {
        let counter = FetchCounter()
        let loader = SowensPhotoLoader(cache: .init(name: UUID().uuidString)) { _ in
            await counter.fetched()
            return nil
        }
        for value in ["http://example.com/photo", "file:///private/photo", "https://user:secret@example.com/photo"] {
            let result = await loader.image(for: URL(string: value)!)
            XCTAssertNil(result)
        }
        let count = await counter.count
        XCTAssertEqual(count, 0)
        await loader.clear()
    }

    func testFailuresCanBeRetried() async {
        let counter = FetchCounter()
        let loader = SowensPhotoLoader(cache: .init(name: UUID().uuidString)) { _ in
            await counter.fetched()
            return nil
        }
        let url = URL(string: "https://fixture.invalid/photo")!
        _ = await loader.image(for: url)
        _ = await loader.image(for: url)
        let count = await counter.count
        XCTAssertEqual(count, 2)
        await loader.clear()
    }

    func testSuccessUsesCacheAndClearRetiresIt() async throws {
        let counter = FetchCounter()
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aB9sAAAAASUVORK5CYII=")!
        let loader = SowensPhotoLoader(cache: .init(name: UUID().uuidString)) { _ in
            await counter.fetched()
            return KFCrossPlatformImage(data: bytes)
        }
        let url = URL(string: "https://fixture.invalid/photo")!
        let first = await loader.image(for: url)
        XCTAssertNotNil(first)
        _ = await loader.image(for: url)
        let warm = await counter.count
        XCTAssertEqual(warm, 1)
        await loader.clear()
        _ = await loader.image(for: url)
        let cold = await counter.count
        XCTAssertEqual(cold, 2)
        await loader.clear()
    }
}

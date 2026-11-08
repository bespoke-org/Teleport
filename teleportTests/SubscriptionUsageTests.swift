import Foundation
import XCTest

final class SubscriptionUsageTests: XCTestCase {
    func testUsageAndQuotaFromCaseInsensitiveHTTPHeader() throws {
        let response = HTTPURLResponse(url: URL(string: "https://provider.invalid/sub")!, statusCode: 200,
            httpVersion: nil, headerFields: ["Subscription-Userinfo": "upload=1073741824; download=6442450944; total=1099511627776; expire=1800000000"])!
        let body = Data("vless://123e4567-e89b-12d3-a456-426614174000@server.invalid:443?security=tls#Server".utf8)
        let fetched = try SubscriptionFetchResult(data: body.base64EncodedData(), response: response)
        let usage = try XCTUnwrap(fetched.usage)
        XCTAssertEqual(usage.usedBytes, 7 * 1073741824)
        XCTAssertEqual(try XCTUnwrap(usage.fractionUsed), 7.0 / 1024, accuracy: 0.000001)
        XCTAssertFalse(fetched.candidates.isEmpty)
    }

    func testMissingMalformedAndPartialInformation() {
        XCTAssertNil(SubscriptionUsage.parse(nil))
        XCTAssertNil(SubscriptionUsage.parse("expire=1800000000"))
        XCTAssertNil(SubscriptionUsage.parse("upload=12; download=-1; total=NaN"))
        XCTAssertNil(SubscriptionUsage.parse("upload=12; download=1.5"))
        let partial = SubscriptionUsage.parse("upload=12; total=100")
        XCTAssertNil(partial?.usedBytes)
        XCTAssertNil(partial?.fractionUsed)
        XCTAssertEqual(partial?.totalBytes, 100)
        let noQuota = SubscriptionUsage.parse(" Upload = 12 ; DOWNLOAD = 8; total=bad")
        XCTAssertEqual(noQuota?.usedBytes, 20)
        XCTAssertNil(noQuota?.fractionUsed)
        XCTAssertNil(SubscriptionUsage.parse("upload=1; download=2; download=3; download=4"))
    }

    func testUnlimitedZeroExhaustedAndOverflow() {
        let unlimited = SubscriptionUsage.parse("upload=12; download=8; total=0")
        XCTAssertEqual(unlimited?.usedBytes, 20)
        XCTAssertEqual(unlimited?.totalBytes, 0)
        XCTAssertNil(unlimited?.fractionUsed)
        XCTAssertEqual(SubscriptionUsage.parse("upload=0; download=0; total=100")?.fractionUsed, 0)
        XCTAssertEqual(SubscriptionUsage.parse("upload=60; download=40; total=100")?.fractionUsed, 1)
        XCTAssertEqual(SubscriptionUsage.parse("upload=60; download=90; total=100")?.fractionUsed, 1)
        XCTAssertNil(SubscriptionUsage.parse("upload=9223372036854775807; download=1")?.usedBytes)
        XCTAssertNil(SubscriptionUsage.parse("total=9223372036854775808"))
    }

    func testSubscriptionPersistenceAndLegacyCompatibility() throws {
        var source = SubscriptionSource(id: UUID(), urlString: "https://provider.invalid/sub", title: "Provider", savedAt: Date())
        let legacy = try JSONEncoder().encode(source)
        XCTAssertNil(try JSONDecoder().decode(SubscriptionSource.self, from: legacy).usage)
        source.usage = SubscriptionUsage.parse("upload=1; download=2; total=100")
        let restored = try JSONDecoder().decode(SubscriptionSource.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(restored, source)
    }
}

import Foundation
import XCTest

final class SubscriptionAnnouncementTests: XCTestCase {
    private let message = "Наш впн работает везде"
    private let server = "vless://123e4567-e89b-12d3-a456-426614174000@server.invalid:443?security=tls#Server"

    func testPlainAndBase64HTTPAnnouncement() throws {
        for header in [message, "base64:" + Data(message.utf8).base64EncodedString()] {
            let fetched = try fetch(header: header, body: Data(server.utf8).base64EncodedData())
            XCTAssertEqual(fetched.announcement, message)
            XCTAssertEqual(fetched.candidates.count, 1)
        }
    }

    func testCommentsInPlainAndBase64Subscriptions() throws {
        for value in [message, "base64:" + Data(message.utf8).base64EncodedString()] {
            let body = Data("#AnNoUnCe: \(value)\n\(server)".utf8)
            for data in [body, body.base64EncodedData()] {
                let fetched = try fetch(body: data)
                XCTAssertEqual(fetched.announcement, message)
                XCTAssertEqual(fetched.candidates.count, 1)
            }
        }
    }

    func testHeaderPrecedenceAndInvalidMetadataDoNotBreakImport() throws {
        let body = Data("#announce: Body message\n\(server)".utf8)
        XCTAssertEqual(try fetch(header: "Header message", body: body).announcement, "Header message")
        for header in ["", "   ", "base64:!!!", "base64:/w=="] {
            let fetched = try fetch(header: header, body: body)
            XCTAssertNil(fetched.announcement)
            XCTAssertEqual(fetched.candidates.count, 1)
        }
        XCTAssertNil(try fetch(body: Data(server.utf8)).announcement)
    }

    func testUnicodeLimitAndWhitespaceNormalization() {
        let text = String(repeating: "🌍", count: 210)
        XCTAssertEqual(SubscriptionAnnouncement.parse(header: text, body: Data()), String(text.prefix(200)))
        let encoded = Data("  Наш\n впн\tработает\u{0000}везде  ".utf8).base64EncodedString()
        XCTAssertEqual(SubscriptionAnnouncement.parse(header: "base64:" + encoded, body: Data()), message)
    }

    func testPersistenceAndExistingSubscriptions() throws {
        var source = SubscriptionSource(id: UUID(), urlString: "https://provider.invalid/sub", title: "Provider", savedAt: Date())
        let legacy = try JSONEncoder().encode(source)
        XCTAssertNil(try JSONDecoder().decode(SubscriptionSource.self, from: legacy).announcement)
        source.announcement = message
        let restored = try JSONDecoder().decode(SubscriptionSource.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(restored, source)
    }

    private func fetch(header: String? = nil, body: Data) throws -> SubscriptionFetchResult {
        let response = HTTPURLResponse(url: URL(string: "https://provider.invalid/sub")!, statusCode: 200,
            httpVersion: nil, headerFields: header.map { ["AnNoUnCe": $0] })!
        return try SubscriptionFetchResult(data: body, response: response)
    }
}

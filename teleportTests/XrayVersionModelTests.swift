import XCTest

@MainActor
final class XrayVersionModelTests: XCTestCase {
    func testConcurrentAndLaterLoadsShareOneQuery() async {
        var calls = 0
        let model = XrayVersionModel {
            calls += 1
            await Task.yield()
            return "Xray 26.1.1 (Xray, Penetrates Everything.)"
        }
        XCTAssertEqual(model.version, "Checking…")

        async let first: Void = model.load()
        async let second: Void = model.load()
        _ = await (first, second)
        await model.load()

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.versionNumber, "26.1.1")
        XCTAssertEqual(model.version, "Xray 26.1.1 (Xray, Penetrates Everything.)")
    }

    func testPendingQueryDoesNotBlockMainActorAndPublishesWhenReady() async {
        let started = expectation(description: "Background query started")
        var finish: CheckedContinuation<String, Never>?
        let model = XrayVersionModel {
            await withCheckedContinuation { continuation in
                finish = continuation
                started.fulfill()
            }
        }
        let load = Task { await model.load() }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(model.versionNumber, "Checking…")
        finish?.resume(returning: "Xray 26.1.1")
        await load.value
        XCTAssertEqual(model.versionNumber, "26.1.1")
    }

    func testFailureIsCachedWithoutQueryingAgainOnLaterVisits() async {
        var calls = 0
        let model = XrayVersionModel {
            calls += 1
            return "Bundled xray not found"
        }
        await model.load()
        await model.load()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.versionNumber, "Bundled xray not found")
    }
}

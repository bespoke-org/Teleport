import Foundation
import XCTest

@MainActor
final class LogReaderTests: XCTestCase {
    func testMissingAndEmptyFilesHaveDifferentStates() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try LogReader.readFile(url).isMissing)
        try Data().write(to: url)
        let empty = try LogReader.readFile(url)
        XCTAssertFalse(empty.isMissing)
        XCTAssertEqual(empty.text, "")
        XCTAssertFalse(empty.isTruncated)
    }

    func testBoundedReadHandlesUTF8BoundaryAndInvalidBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("prefix café\nnext".utf8).write(to: url)
        let tail = try LogReader.readFile(url, maximumBytes: 6)
        XCTAssertTrue(tail.isTruncated)
        XCTAssertEqual(tail.text, "\nnext")
        try Data([0x61, 0xFF, 0x62]).write(to: url)
        XCTAssertEqual(try LogReader.readFile(url).text, "a�b")
    }

    func testReadFailureDoesNotLookLikeAnEmptyLog() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try LogReader.readFile(url))
    }

    func testHelperNoticeIsSeparateFromCopiedContents() {
        let response = DiagnosticsResponse(log: .xray,
            text: "… showing last 256 KB …\nactual output\n", metadata: "file metadata", wasTruncated: true)
        let snapshot = LogReader.snapshot(from: response)
        XCTAssertEqual(snapshot.text, "actual output\n")
        XCTAssertTrue(snapshot.isTruncated)
        XCTAssertFalse(snapshot.isMissing)
        let missing = DiagnosticsResponse(log: .xray, text: "", metadata: "Missing: /example/log", wasTruncated: false)
        XCTAssertTrue(LogReader.snapshot(from: missing).isMissing)
    }

    func testSlowPreviousSourceCannotOverwriteNewSource() async {
        var pending: CheckedContinuation<LogSnapshot, Error>?
        let started = expectation(description: "first read started")
        let model = LogReaderModel { source in
            if source == .app {
                return try await withCheckedThrowingContinuation { continuation in
                    pending = continuation
                    started.fulfill()
                }
            }
            return LogSnapshot(text: "new source")
        }
        let old = Task { await model.refresh(.app) }
        await fulfillment(of: [started], timeout: 2)
        await model.refresh(.tun)
        pending?.resume(returning: LogSnapshot(text: "old source"))
        await old.value
        XCTAssertEqual(model.source, .tun)
        XCTAssertEqual(model.snapshot?.text, "new source")
        XCTAssertNil(model.error)
    }

    func testCancelledReadDoesNotPublishAndRefreshFailureKeepsLastSnapshot() async {
        var pending: CheckedContinuation<LogSnapshot, Error>?
        let started = expectation(description: "read started")
        let model = LogReaderModel { _ in
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
        }
        let task = Task { await model.refresh(.app) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        pending?.resume(returning: LogSnapshot(text: "cancelled"))
        await task.value
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(model.isLoading)

        var fails = false
        let refreshingModel = LogReaderModel { _ in
            if fails { throw CocoaError(.fileReadNoPermission) }
            return LogSnapshot(text: "last good read")
        }
        await refreshingModel.refresh(.app)
        fails = true
        await refreshingModel.refresh(.app)
        XCTAssertEqual(refreshingModel.snapshot?.text, "last good read")
        XCTAssertNotNil(refreshingModel.error)
        refreshingModel.select(.helper)
        XCTAssertNil(refreshingModel.snapshot)
        XCTAssertNil(refreshingModel.error)
    }
}

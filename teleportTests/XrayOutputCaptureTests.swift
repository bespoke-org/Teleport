import Foundation
import XCTest

@MainActor
final class XrayOutputCaptureTests: XCTestCase {
    private var directory: URL!
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    private func bytes(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).intValue
    }

    private func capture(_ pipe: Pipe, maximum: Int? = 4096) throws -> XrayOutputCapture {
        try XrayOutputCapture(reader: pipe.fileHandleForReading, directory: directory,
                              policy: XrayLogPolicy(maxLogSize: maximum, retentionDays: nil))
    }

    func testSustainedOutputHasBoundedDiagnosticsAndRotatesDuringOneRun() throws {
        let pipe = Pipe()
        let session = try capture(pipe, maximum: 64 * 1024)
        defer { session.close() }
        try pipe.fileHandleForWriting.write(contentsOf: Data("startup-context\n".utf8))
        let chunk = Data(repeating: 0x61, count: 32 * 1024)
        for _ in 0..<64 {
            try pipe.fileHandleForWriting.write(contentsOf: chunk)
            XCTAssertLessThanOrEqual(session.storedByteCount, 256 * 1024)
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("\nrecent-failure".utf8))
        try pipe.fileHandleForWriting.close()
        session.close()
        session.close()
        let output = try XCTUnwrap(session.capturedOutput())
        XCTAssertTrue(output.hasPrefix("startup-context"))
        XCTAssertTrue(output.hasSuffix("recent-failure"))
        XCTAssertTrue(output.contains("output omitted"))
        XCTAssertEqual(session.storedByteCount, 256 * 1024)
        XCTAssertGreaterThan(try files().count, 20)
        for url in try files() {
            XCTAssertLessThanOrEqual(try bytes(url), 64 * 1024)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        XCTAssertFalse(session.hasDiskFailure)
    }

    func testEmptyShortAndSplitMalformedUTF8() throws {
        let pipe = Pipe()
        let session = try capture(pipe)
        XCTAssertNil(session.capturedOutput())
        try pipe.fileHandleForWriting.write(contentsOf: Data([0x63, 0x61, 0x66, 0xC3]))
        try pipe.fileHandleForWriting.write(contentsOf: Data([0xA9, 0xFF]))
        try pipe.fileHandleForWriting.close()
        session.close()
        XCTAssertEqual(session.capturedOutput(), "café�")
        XCTAssertEqual(session.storedByteCount, 6)
    }

    func testOversizedAppendNeverExceedsFileSizeAndPreservesAllNewBytes() throws {
        let sink = try XrayLogSink(directory: directory, policy: XrayLogPolicy(maxLogSize: 17, retentionDays: nil))
        let data = Data(String(repeating: "🙂abc", count: 1000).utf8)
        try sink.append(data)
        sink.close()
        XCTAssertEqual(try files().reduce(0) { try $0 + bytes($1) }, data.count)
        for url in try files() { XCTAssertLessThanOrEqual(try bytes(url), 17) }
    }

    func testDailyAndSizeTriggersAreIndependentOfRetention() throws {
        var now = Date(timeIntervalSince1970: 1_700_006_400) // deterministic UTC day
        let sink = try XrayLogSink(directory: directory, policy: XrayLogPolicy(maxLogSize: 8, retentionDays: nil),
                                   clock: { now }, calendar: utc)
        try sink.append(Data(repeating: 65, count: 9))
        XCTAssertEqual(try files().count, 2)
        now = now.addingTimeInterval(86400)
        try sink.append(Data([66]))
        XCTAssertEqual(try files().count, 3)
        sink.close()
        let reopened = try XrayLogSink(directory: directory, policy: XrayLogPolicy(maxLogSize: 8, retentionDays: nil),
                                       clock: { now }, calendar: utc)
        try reopened.append(Data([67]))
        reopened.close()
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("xray.log")), Data([66, 67]))
    }

    func testOverlappingRuntimeSinksDoNotKeepWritingRenamedGenerations() throws {
        let policy = try XrayLogPolicy(maxLogSize: 16, retentionDays: nil)
        let first = try XrayLogSink(directory: directory, policy: policy)
        let second = try XrayLogSink(directory: directory, policy: policy)
        for _ in 0..<30 {
            try first.append(Data(repeating: 65, count: 13))
            try second.append(Data(repeating: 66, count: 13))
        }
        first.close()
        second.close()
        XCTAssertEqual(try files().reduce(0) { try $0 + bytes($1) }, 780)
        for url in try files() { XCTAssertLessThanOrEqual(try bytes(url), 16) }
    }

    func testBothNullRotateDailyWithoutAgeDeletionOrSizeTrigger() throws {
        var now = Date(timeIntervalSince1970: 1_700_006_400)
        let sink = try XrayLogSink(directory: directory, policy: XrayLogPolicy(maxLogSize: nil, retentionDays: nil),
                                   clock: { now }, calendar: utc)
        try sink.append(Data(repeating: 65, count: 128 * 1024))
        XCTAssertEqual(try files().count, 1)
        now = now.addingTimeInterval(20 * 86400)
        try sink.append(Data([66]))
        sink.close()
        XCTAssertEqual(try files().count, 2)
        XCTAssertTrue(try files().contains { try bytes($0) == 128 * 1024 })
    }

    func testRetentionDeletesOnlyOwnedOldArchivesEvenWithoutSizeLimit() throws {
        let now = Date(timeIntervalSince1970: 1_700_006_400)
        let old = directory.appendingPathComponent("xray.log.1")
        let unrelated = directory.appendingPathComponent("xray.log.keep")
        for url in [old, unrelated] {
            try Data([65]).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-10 * 86400)], ofItemAtPath: url.path)
        }
        let sink = try XrayLogSink(directory: directory, policy: XrayLogPolicy(maxLogSize: nil, retentionDays: 7),
                                   clock: { now }, calendar: utc)
        sink.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testOldOversizedFilesAreTrimmedWithAgeAndPermissionsPreserved() throws {
        for name in ["xray.log", "xray.log.1"] {
            let url = directory.appendingPathComponent(name)
            try Data(repeating: 65, count: 1024 * 1024).write(to: url)
        }
        let sink = try XrayLogSink(directory: directory, policy: XrayLogPolicy(maxLogSize: 64, retentionDays: nil))
        try sink.append(Data([66]))
        sink.close()
        for url in try files() { XCTAssertLessThanOrEqual(try bytes(url), 64) }
        XCTAssertEqual(try bytes(directory.appendingPathComponent("xray.log.1")), 64)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("xray.log")), Data([66]))
    }

    func testDiskWriteFailureDoesNotStopPipeDrainOrGrowMemory() throws {
        let pipe = Pipe()
        let session = try XrayOutputCapture(reader: pipe.fileHandleForReading, directory: directory,
                                            policy: .standard, write: { handle, data in
            if data.starts(with: Data("\n=====".utf8)) { try handle.write(contentsOf: data) }
            else { throw CocoaError(.fileWriteOutOfSpace) }
        })
        XCTAssertFalse(session.hasDiskFailure)
        try pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 65, count: 1024 * 1024))
        try pipe.fileHandleForWriting.close()
        session.close()
        XCTAssertTrue(session.hasDiskFailure)
        XCTAssertLessThanOrEqual(session.storedByteCount, 256 * 1024)
        XCTAssertTrue(try XCTUnwrap(session.capturedOutput()).contains("logging unavailable"))
    }

    func testCloseWaitsForAcceptedIOAndOldSessionCannotWriteIntoNewRun() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let pipe = Pipe()
        let old = try XrayOutputCapture(reader: pipe.fileHandleForReading, directory: directory, policy: .standard,
                                        write: { handle, data in
            if data == Data("late-old-output".utf8) {
                entered.signal()
                guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileWriteUnknown) }
            }
            try handle.write(contentsOf: data)
        })
        try pipe.fileHandleForWriting.write(contentsOf: Data("late-old-output".utf8))
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        try pipe.fileHandleForWriting.close()
        let closed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { old.close(); closed.signal() }
        XCTAssertEqual(closed.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        XCTAssertEqual(closed.wait(timeout: .now() + 3), .success)
        let nextPipe = Pipe()
        let next = try capture(nextPipe)
        try nextPipe.fileHandleForWriting.write(contentsOf: Data("new-only".utf8))
        try nextPipe.fileHandleForWriting.close()
        next.close()
        old.expectExit()
        old.close()
        XCTAssertEqual(old.capturedOutput(), "late-old-output")
        XCTAssertEqual(next.capturedOutput(), "new-only")
        XCTAssertFalse(next.expectsExit)
    }

    func testFailedSpawnAndRepeatedStopRetireCapture() throws {
        let directory = try XCTUnwrap(directory)
        let manager = XrayRuntimeManager(assetDirectoryURLProvider: { directory },
            log: TeleportLog(directoryURL: directory.appendingPathComponent("structured"), fileName: "test.log"),
            executableURLProvider: { directory.appendingPathComponent("does-not-exist") },
            logDirectoryURLProvider: { directory })
        XCTAssertThrowsError(try manager.start(configURL: directory.appendingPathComponent("unused")))
        manager.stop()
        manager.stop()
        XCTAssertFalse(manager.isRunning)
    }

    func testSyntheticChildRestartDoesNotReusePreviousDiagnostics() throws {
        let directory = try XCTUnwrap(directory)
        let script = directory.appendingPathComponent("synthetic-child")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$3\"\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var executable: URL? = script
        let manager = XrayRuntimeManager(assetDirectoryURLProvider: { directory },
            log: TeleportLog(directoryURL: directory.appendingPathComponent("structured"), fileName: "test.log"),
            executableURLProvider: { executable }, logDirectoryURLProvider: { directory })
        for marker in ["first-run", "second-run"] {
            try manager.start(configURL: directory.appendingPathComponent(marker))
            let deadline = Date().addingTimeInterval(3)
            while manager.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertFalse(manager.isRunning)
            let output = try XCTUnwrap(manager.stopAndCaptureErrorOutput())
            XCTAssertTrue(output.contains(marker))
            if marker == "second-run" { XCTAssertFalse(output.contains("first-run")) }
        }
        executable = nil
        XCTAssertThrowsError(try manager.start(configURL: directory.appendingPathComponent("third-run")))
        XCTAssertNil(manager.capturedErrorOutput())
        manager.stop()
    }

    func testPolicyDistinguishesMissingNullZeroAndInvalidValues() throws {
        func decode(_ text: String) throws -> XrayLogPolicy {
            try JSONDecoder().decode(XrayLogPolicy.self, from: Data(text.utf8))
        }
        XCTAssertEqual(try decode("{}").maxLogSize, 5 * 1024 * 1024)
        XCTAssertEqual(try decode("{}").retentionDays, 7)
        let disabled = try decode("{\"max_log_size\":null,\"retention_days\":null}")
        XCTAssertNil(disabled.maxLogSize)
        XCTAssertNil(disabled.retentionDays)
        XCTAssertThrowsError(try decode("{\"max_log_size\":0}"))
        XCTAssertThrowsError(try decode("{\"retention_days\":-1}"))
        XCTAssertThrowsError(try decode("{\"max_log_size\":\"None\"}"))
        let suite = "xray-log-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("{\"max_log_size\":null,\"retention_days\":3}", forKey: XrayLogPolicy.defaultsKey)
        XCTAssertNil(try XrayLogPolicy.load(defaults: defaults).maxLogSize)
        XCTAssertEqual(try XrayLogPolicy.load(defaults: defaults).retentionDays, 3)
    }
}

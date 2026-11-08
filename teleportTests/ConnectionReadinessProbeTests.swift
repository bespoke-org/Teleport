import Darwin
import Foundation
import XCTest

final class ConnectionReadinessProbeTests: XCTestCase {
    func testLiveLocalProxyDoesNotMaskRejectedRemoteTLSHandshake() async throws {
        let fixture = try ReadinessFixture(mode: "bad-handshake")
        defer { fixture.stop() }
        let probe = ConnectionReadinessProbe(targets: [fixture.target], timeout: 2)
        do {
            try await probe.verify(endpoint: fixture.endpoint)
            XCTFail("Local listener readiness must not hide the rejected remote handshake")
        } catch is ConnectionReadinessProbe.Failure {}
        XCTAssertTrue(fixture.process.isRunning, "The failure must be a remote handshake, not a dead local runtime")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("tls-attempted").path),
            "The synthetic remote server must have received the TLS handshake")
    }

    func testWorkingProxyAcceptsTargetResponseAndFallsBackFromUnavailableTarget() async throws {
        let fixture = try ReadinessFixture(mode: "working")
        defer { fixture.stop() }
        // An HTTPS request to the plain HTTP origin fails. The independent HTTP
        // target succeeds, proving one bad check endpoint doesn't reject a portal.
        let badTarget = URL(string: fixture.target.absoluteString.replacingOccurrences(of: "http:", with: "https:"))!
        try await ConnectionReadinessProbe(targets: [badTarget, fixture.target], timeout: 2).verify(endpoint: fixture.endpoint)
        // A site's access policy is distinct from a failed proxy handshake.
        try await ConnectionReadinessProbe(targets: [fixture.target.appendingPathComponent("blocked")], timeout: 2)
            .verify(endpoint: fixture.endpoint)
    }

    func testCancellationStopsVerification() async throws {
        let fixture = try ReadinessFixture(mode: "working")
        defer { fixture.stop() }
        let task = Task {
            try Task.checkCancellation()
            try await ConnectionReadinessProbe(targets: [fixture.target], timeout: 2).verify(endpoint: fixture.endpoint)
        }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
    }
}

private final class ReadinessFixture: @unchecked Sendable {
    let process = Process()
    let directory: URL
    let endpoint: ProxyEndpoint
    let target: URL
    private let input = Pipe()
    private let exited = DispatchSemaphore(value: 0)
    private var stopped = false

    init(mode: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("teleport-readiness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("scripts/tests/xray_connection_readiness.py").path,
                             root.appendingPathComponent("teleport/Resources/xray").path, directory.path, mode]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = exited
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        // The fixture has a bounded startup and always reaps its Xray child.
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }
            line.append(byte)
        }
        struct Ready: Decodable { let proxyPort: Int; let originPort: Int }
        do {
            let ready = try JSONDecoder().decode(Ready.self, from: line)
            endpoint = ProxyEndpoint(host: "127.0.0.1", httpPort: ready.proxyPort, socksPort: ready.proxyPort)
            target = URL(string: "http://127.0.0.1:\(ready.originPort)/")!
        } catch {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            _ = exited.wait(timeout: .now() + 5)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        try? input.fileHandleForWriting.close()
        if exited.wait(timeout: .now() + 5) == .timedOut, process.isRunning {
            process.terminate()
            if exited.wait(timeout: .now() + 3) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { stop() }
}

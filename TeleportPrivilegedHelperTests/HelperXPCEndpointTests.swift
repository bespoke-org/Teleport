import Foundation
import XCTest

actor RecordingDispatcher: HelperCommandDispatching {
    private(set) var commands: [TUNHelperCommand] = []
    private let responseData: Data

    init(responseData: Data) {
        self.responseData = responseData
    }

    func dispatch(command: TUNHelperCommand, requestData: Data) async -> Data {
        commands.append(command)
        return responseData
    }
}

private final class ReplyCounter {
    private let lock = NSLock()
    private var count = 0

    func record() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count == 1
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private struct InvocationResult {
    let data: Data?
    let error: NSError?
    let replyCount: Int
}

private func invoke(
    _ operation: (@escaping (Data?, NSError?) -> Void) -> Void
) async -> InvocationResult {
    let counter = ReplyCounter()
    let result: (Data?, NSError?) = await withCheckedContinuation { continuation in
        operation { data, error in
            if counter.record() {
                continuation.resume(returning: (data, error))
            }
        }
    }
    try? await Task.sleep(for: .milliseconds(20))
    return InvocationResult(data: result.0, error: result.1, replyCount: counter.value())
}

final class HelperXPCEndpointTests: XCTestCase {
    func testServiceRepliesWithDispatcherResponse() async throws {
        let expectedResponse = Data("encoded response".utf8)
        let dispatcher = RecordingDispatcher(responseData: expectedResponse)
        let service = HelperXPCService(dispatcher: dispatcher)
        let request = Data("encoded request".utf8)

        let status = await invoke { service.getStatus(request, withReply: $0) }
        XCTAssert(status.data == expectedResponse && status.error == nil && status.replyCount == 1)

        let start = await invoke { service.startSession(request, withReply: $0) }
        XCTAssert(start.data == expectedResponse && start.error == nil && start.replyCount == 1)

        let stop = await invoke { service.stopSession(request, withReply: $0) }
        XCTAssert(stop.data == expectedResponse && stop.error == nil && stop.replyCount == 1)

        let diagnostics = await invoke { service.readDiagnostics(request, withReply: $0) }
        XCTAssert(diagnostics.data == expectedResponse && diagnostics.error == nil && diagnostics.replyCount == 1)

        let commands = await dispatcher.commands
        XCTAssert(commands == [.status, .startSession, .stopSession, .readDiagnostics])

        let oversizedDispatcher = RecordingDispatcher(
            responseData: Data(repeating: 0, count: TUNHelperProtocol.maximumResponseBytes + 1)
        )
        let oversizedService = HelperXPCService(dispatcher: oversizedDispatcher)
        let oversized = await invoke { oversizedService.getStatus(request, withReply: $0) }
        XCTAssert(oversized.data == nil)
        XCTAssert(oversized.error?.domain == HelperXPCService.errorDomain)
        XCTAssert(oversized.error?.localizedDescription.count ?? 0 <= 256)
        XCTAssert(oversized.replyCount == 1)

    }
}

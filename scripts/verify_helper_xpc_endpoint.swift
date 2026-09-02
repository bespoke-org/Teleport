import Foundation

actor RecordingDispatcher: HelperCommandDispatching {
    private(set) var commands: [VPNHelperCommand] = []
    private let responseData: Data

    init(responseData: Data) {
        self.responseData = responseData
    }

    func dispatch(command: VPNHelperCommand, requestData: Data) async -> Data {
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

private struct MissingSourceFragment: Error {}

private func requireOffset(of fragment: String, in source: String) throws -> String.Index {
    guard let offset = source.range(of: fragment)?.lowerBound else {
        throw MissingSourceFragment()
    }
    return offset
}

@main
struct VerifyHelperXPCEndpoint {
    static func main() async throws {
        let mainSource = try String(contentsOfFile: "TeleportPrivilegedHelper/main.swift", encoding: .utf8)
        let authenticatorSource = try String(contentsOfFile: "TeleportPrivilegedHelper/IPC/ClientAuthenticator.swift", encoding: .utf8)
        let listenerSource = try String(contentsOfFile: "TeleportPrivilegedHelper/IPC/HelperXPCListenerDelegate.swift", encoding: .utf8)

        precondition(mainSource.contains("NSXPCListener(machServiceName: VPNHelperProtocol.machServiceName)"))
        precondition(mainSource.contains("listener.resume()"))
        precondition(authenticatorSource.contains("consoleOwner.uid != 0"))
        precondition(authenticatorSource.contains("effectiveUserIdentifier"))
        precondition(authenticatorSource.contains("setCodeSigningRequirement"))
        precondition(!authenticatorSource.contains("getpeereid"))
        precondition(!authenticatorSource.contains("LOCAL_PEERPID"))
        precondition(!authenticatorSource.contains("SecCodeCopyGuestWithAttributes"))
        precondition(listenerSource.contains("connection.exportedInterface"))
        precondition(listenerSource.contains("connection.exportedObject"))
        precondition(listenerSource.contains("connection.activate()"))
        precondition(listenerSource.contains("NSData.self"))
        precondition(listenerSource.contains("interface.setClasses"))
        let authenticationOffset = try requireOffset(of: "authenticator.configureAndAuthorize", in: listenerSource)
        let exposureOffset = try requireOffset(of: "connection.exportedInterface", in: listenerSource)
        let activationOffset = try requireOffset(of: "connection.activate()", in: listenerSource)
        precondition(authenticationOffset < exposureOffset && exposureOffset < activationOffset)

        let expectedResponse = Data("encoded response".utf8)
        let dispatcher = RecordingDispatcher(responseData: expectedResponse)
        let service = HelperXPCService(dispatcher: dispatcher)
        let request = Data("encoded request".utf8)

        let status = await invoke { service.getStatus(request, withReply: $0) }
        precondition(status.data == expectedResponse && status.error == nil && status.replyCount == 1)

        let start = await invoke { service.startSession(request, withReply: $0) }
        precondition(start.data == expectedResponse && start.error == nil && start.replyCount == 1)

        let stop = await invoke { service.stopSession(request, withReply: $0) }
        precondition(stop.data == expectedResponse && stop.error == nil && stop.replyCount == 1)

        let diagnostics = await invoke { service.readDiagnostics(request, withReply: $0) }
        precondition(diagnostics.data == expectedResponse && diagnostics.error == nil && diagnostics.replyCount == 1)

        let commands = await dispatcher.commands
        precondition(commands == [.status, .startSession, .stopSession, .readDiagnostics])

        let oversizedDispatcher = RecordingDispatcher(
            responseData: Data(repeating: 0, count: VPNHelperProtocol.maximumResponseBytes + 1)
        )
        let oversizedService = HelperXPCService(dispatcher: oversizedDispatcher)
        let oversized = await invoke { oversizedService.getStatus(request, withReply: $0) }
        precondition(oversized.data == nil)
        precondition(oversized.error?.domain == HelperXPCService.errorDomain)
        precondition(oversized.error?.localizedDescription.count ?? 0 <= 256)
        precondition(oversized.replyCount == 1)

        print("verify_helper_xpc_endpoint: all checks passed")
    }
}

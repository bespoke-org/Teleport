import Foundation

private func expectTransportError(
    _ expected: VPNHelperTransportError,
    operation: () async throws -> Data
) async {
    do {
        _ = try await operation()
        preconditionFailure("Expected transport error: \(expected)")
    } catch let error as VPNHelperTransportError {
        precondition(error == expected, "Expected \(expected), got \(error)")
    } catch {
        preconditionFailure("Unexpected error: \(error)")
    }
}

/// Awaits `task`, giving up after `timeout` so a regression reports a failure
/// instead of hanging the whole verification run.
private func value<T: Sendable>(of task: Task<T, Never>, timeout: Double) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await task.value }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

private final class FakeProxy: NSObject, VPNHelperXPCProtocol {
    private let lock = NSLock()
    private var commands: [VPNHelperCommand] = []
    var handle: (VPNHelperCommand, Data, @escaping (Data?, NSError?) -> Void) -> Void

    init(handle: @escaping (VPNHelperCommand, Data, @escaping (Data?, NSError?) -> Void) -> Void) {
        self.handle = handle
    }

    var recordedCommands: [VPNHelperCommand] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }

    func getStatus(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        invoke(.status, request: request, reply: reply)
    }

    func startSession(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        invoke(.startSession, request: request, reply: reply)
    }

    func stopSession(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        invoke(.stopSession, request: request, reply: reply)
    }

    func readDiagnostics(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        invoke(.readDiagnostics, request: request, reply: reply)
    }

    func engageLeakGuard(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        invoke(.engageLeakGuard, request: request, reply: reply)
    }

    func releaseLeakGuard(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        invoke(.releaseLeakGuard, request: request, reply: reply)
    }

    private func invoke(
        _ command: VPNHelperCommand,
        request: Data,
        reply: @escaping (Data?, NSError?) -> Void
    ) {
        lock.lock()
        commands.append(command)
        lock.unlock()
        handle(command, request, reply)
    }
}

private final class FakeConnection: VPNHelperXPCConnection, @unchecked Sendable {
    private let lock = NSLock()
    private let proxy: FakeProxy
    private var interruption: (@Sendable () -> Void)?
    private var invalidation: (@Sendable () -> Void)?
    private var proxyFailure: Error?
    private var activations = 0
    private var invalidations = 0
    private var configuredInterface: NSXPCInterface?
    private let interruptsWhenHandlerIsInstalled: Bool

    init(
        proxy: FakeProxy,
        proxyFailure: Error? = nil,
        interruptsWhenHandlerIsInstalled: Bool = false
    ) {
        self.proxy = proxy
        self.proxyFailure = proxyFailure
        self.interruptsWhenHandlerIsInstalled = interruptsWhenHandlerIsInstalled
    }

    var activationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activations
    }

    var invalidationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return invalidations
    }

    var didConfigureAllowedClasses: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let configuredInterface else { return false }
        let methods = [
            #selector(VPNHelperXPCProtocol.getStatus(_:withReply:)),
            #selector(VPNHelperXPCProtocol.startSession(_:withReply:)),
            #selector(VPNHelperXPCProtocol.stopSession(_:withReply:)),
            #selector(VPNHelperXPCProtocol.readDiagnostics(_:withReply:))
        ]
        return methods.allSatisfy { method in
            let requestClasses = configuredInterface.classes(
                for: method,
                argumentIndex: 0,
                ofReply: false
            )
            let dataReplyClasses = configuredInterface.classes(
                for: method,
                argumentIndex: 0,
                ofReply: true
            )
            let errorReplyClasses = configuredInterface.classes(
                for: method,
                argumentIndex: 1,
                ofReply: true
            )
            return NSSet(set: requestClasses).contains(NSData.self)
                && NSSet(set: dataReplyClasses).contains(NSData.self)
                && NSSet(set: errorReplyClasses).contains(NSError.self)
        }
    }

    func setRemoteObjectInterface(_ interface: NSXPCInterface) {
        lock.lock()
        configuredInterface = interface
        lock.unlock()
    }

    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        interruption = handler
        let shouldInterrupt = interruptsWhenHandlerIsInstalled
        lock.unlock()
        if shouldInterrupt {
            handler()
        }
    }

    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        invalidation = handler
        lock.unlock()
    }

    func remoteProxy(errorHandler: @escaping @Sendable (Error) -> Void) -> (any VPNHelperXPCProtocol)? {
        lock.lock()
        let failure = proxyFailure
        lock.unlock()
        if let failure {
            errorHandler(failure)
        }
        return proxy
    }

    func activate() {
        lock.lock()
        activations += 1
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        invalidations += 1
        let handler = invalidation
        lock.unlock()
        handler?()
    }

    func triggerInterruption() {
        lock.lock()
        let handler = interruption
        lock.unlock()
        handler?()
    }

    func triggerInvalidation() {
        lock.lock()
        let handler = invalidation
        lock.unlock()
        handler?()
    }
}

private final class ConnectionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [FakeConnection]
    private var index = 0

    init(_ connections: [FakeConnection]) {
        self.connections = connections
    }

    var creationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return index
    }

    func make() -> any VPNHelperXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        precondition(index < connections.count, "Unexpected connection creation")
        let connection = connections[index]
        index += 1
        return connection
    }
}

private final class StoredTransportResults: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Data, Error>] = []

    func append(_ value: Result<Data, Error>) {
        lock.lock()
        results.append(value)
        lock.unlock()
    }

    func load() -> [Result<Data, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return results
    }
}

private final class StoredTransportResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error>?

    func store(_ value: Result<Data, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func load() -> Result<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

private final class StoredReply: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: ((Data?, NSError?) -> Void)?

    func store(_ value: @escaping (Data?, NSError?) -> Void) {
        lock.lock()
        reply = value
        lock.unlock()
    }

    func take() -> ((Data?, NSError?) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let value = reply
        reply = nil
        return value
    }
}

@main
private enum VerifyXPCTransport {
    static func main() async throws {
        try await verifiesExplicitAllowedClassesConfiguration()
        try await verifiesCommandRoutingAndNormalReplies()
        await verifiesConcurrentSendsShareConnectionCreation()
        await verifiesProxyErrorMapping()
        await verifiesNSErrorReplyMapping()
        try await verifiesSynchronousLifecycleHandlerDuringConfiguration()
        try await verifiesInterruptionRetiresOnlyItsGeneration()
        try await verifiesInvalidationCreatesOneReplacement()
        try await verifiesDeadlineAndIgnoresLateReply()
        await verifiesInvalidResponseMapping()
        print("verify_xpc_transport: all checks passed")
    }

    private static func verifiesExplicitAllowedClassesConfiguration() async throws {
        let source = try String(
            contentsOfFile: "teleport/VPN/XPCVPNHelperTransport.swift",
            encoding: .utf8
        )
        precondition(source.contains("interface.setClasses"))
    }

    private static func verifiesCommandRoutingAndNormalReplies() async throws {
        let response = Data("response".utf8)
        let proxy = FakeProxy { _, request, reply in
            precondition(request == Data("request".utf8))
            reply(response, nil)
        }
        let connection = FakeConnection(proxy: proxy)
        let factory = ConnectionFactory([connection])
        let transport = XPCVPNHelperTransport(connectionFactory: { factory.make() })

        for command in [VPNHelperCommand.status, .startSession, .stopSession, .readDiagnostics] {
            let received = try await transport.send(
                command: command,
                requestData: Data("request".utf8),
                timeout: 1
            )
            precondition(received == response)
        }

        precondition(proxy.recordedCommands == [.status, .startSession, .stopSession, .readDiagnostics])
        precondition(factory.creationCount == 1)
        precondition(connection.activationCount == 1)
        precondition(connection.didConfigureAllowedClasses)
    }

    private static func verifiesConcurrentSendsShareConnectionCreation() async {
        let proxy = FakeProxy { _, _, reply in reply(Data("ok".utf8), nil) }
        let connection = FakeConnection(proxy: proxy)
        let factory = ConnectionFactory([connection])
        let creationStarted = DispatchSemaphore(value: 0)
        let allowCreation = DispatchSemaphore(value: 0)
        let transport = XPCVPNHelperTransport(connectionFactory: {
            creationStarted.signal()
            allowCreation.wait()
            return factory.make()
        })
        let results = StoredTransportResults()

        // The gate is released from the main actor, so it stays reachable even while
        // the concurrent senders occupy cooperative threads inside connection setup.
        let senders = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0 ..< 8 {
                    group.addTask {
                        do {
                            let data = try await transport.send(
                                command: .status,
                                requestData: Data(),
                                timeout: 1
                            )
                            results.append(.success(data))
                        } catch {
                            results.append(.failure(error))
                        }
                    }
                }
            }
        }

        precondition(creationStarted.wait(timeout: .now() + 1) == .success)
        allowCreation.signal()
        let sendersFinished = await value(of: senders, timeout: 5) != nil
        precondition(sendersFinished, "concurrent sends did not finish")
        precondition(results.load().count == 8)
        for result in results.load() {
            do {
                let data = try result.get()
                precondition(data == Data("ok".utf8))
            } catch {
                preconditionFailure("Unexpected concurrent send error: \(error)")
            }
        }
        precondition(factory.creationCount == 1)
        precondition(connection.activationCount == 1)
    }

    private static func verifiesProxyErrorMapping() async {
        let error = NSError(domain: "test.proxy", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "proxy unavailable"
        ])
        let proxy = FakeProxy { _, _, reply in reply(Data(), nil) }
        let connection = FakeConnection(proxy: proxy, proxyFailure: error)
        let factory = ConnectionFactory([connection])
        let transport = XPCVPNHelperTransport(connectionFactory: { factory.make() })

        await expectTransportError(.unavailable("proxy unavailable")) {
            try await transport.send(command: .status, requestData: Data(), timeout: 1)
        }
    }

    private static func verifiesNSErrorReplyMapping() async {
        let proxy = FakeProxy { _, _, reply in
            reply(nil, NSError(domain: "test.reply", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "reply rejected"
            ]))
            reply(Data("late".utf8), nil)
        }
        let connection = FakeConnection(proxy: proxy)
        let factory = ConnectionFactory([connection])
        let transport = XPCVPNHelperTransport(connectionFactory: { factory.make() })

        await expectTransportError(.unavailable("reply rejected")) {
            try await transport.send(command: .status, requestData: Data(), timeout: 1)
        }
    }

    private static func verifiesSynchronousLifecycleHandlerDuringConfiguration() async throws {
        let firstProxy = FakeProxy { _, _, reply in reply(Data("unexpected".utf8), nil) }
        let firstConnection = FakeConnection(
            proxy: firstProxy,
            interruptsWhenHandlerIsInstalled: true
        )
        let secondProxy = FakeProxy { _, _, reply in reply(Data("replacement".utf8), nil) }
        let secondConnection = FakeConnection(proxy: secondProxy)
        let factory = ConnectionFactory([firstConnection, secondConnection])
        let transport = XPCVPNHelperTransport(connectionFactory: { factory.make() })
        let result = StoredTransportResult()

        let send = Task {
            do {
                let data = try await transport.send(command: .status, requestData: Data(), timeout: 1)
                result.store(.success(data))
            } catch {
                result.store(.failure(error))
            }
        }

        let sendFinished = await value(of: send, timeout: 2) != nil
        precondition(
            sendFinished,
            "Synchronous lifecycle handler deadlocked connection configuration"
        )
        guard let storedResult = result.load() else {
            preconditionFailure("Expected the send to store a result")
        }
        await expectTransportError(.interrupted) {
            try storedResult.get()
        }
        precondition(firstConnection.activationCount == 0)

        let replacement = try await transport.send(command: .status, requestData: Data(), timeout: 1)
        precondition(replacement == Data("replacement".utf8))
        precondition(factory.creationCount == 2)
    }

    private static func verifiesInterruptionRetiresOnlyItsGeneration() async throws {
        var firstConnection: FakeConnection!
        let firstProxy = FakeProxy { _, _, _ in firstConnection.triggerInterruption() }
        firstConnection = FakeConnection(proxy: firstProxy)
        let response = Data("replacement".utf8)
        let secondProxy = FakeProxy { _, _, reply in reply(response, nil) }
        let secondConnection = FakeConnection(proxy: secondProxy)
        let factory = ConnectionFactory([firstConnection, secondConnection])
        let transport = XPCVPNHelperTransport(connectionFactory: { factory.make() })

        await expectTransportError(.interrupted) {
            try await transport.send(command: .startSession, requestData: Data(), timeout: 1)
        }
        let received = try await transport.send(command: .status, requestData: Data(), timeout: 1)
        precondition(received == response)
        firstConnection.triggerInvalidation()
        let receivedAgain = try await transport.send(command: .status, requestData: Data(), timeout: 1)
        precondition(receivedAgain == response)
        precondition(factory.creationCount == 2)
    }

    private static func verifiesInvalidationCreatesOneReplacement() async throws {
        var firstConnection: FakeConnection!
        let firstProxy = FakeProxy { _, _, _ in firstConnection.triggerInvalidation() }
        firstConnection = FakeConnection(proxy: firstProxy)
        let secondProxy = FakeProxy { _, _, reply in reply(Data("ok".utf8), nil) }
        let secondConnection = FakeConnection(proxy: secondProxy)
        let factory = ConnectionFactory([firstConnection, secondConnection])
        let transport = XPCVPNHelperTransport(connectionFactory: { factory.make() })

        await expectTransportError(.invalidated) {
            try await transport.send(command: .stopSession, requestData: Data(), timeout: 1)
        }
        let received = try await transport.send(command: .status, requestData: Data(), timeout: 1)
        precondition(received == Data("ok".utf8))
        precondition(factory.creationCount == 2)
    }

    private static func verifiesDeadlineAndIgnoresLateReply() async throws {
        let storedReply = StoredReply()
        let proxy = FakeProxy { _, _, reply in storedReply.store(reply) }
        let connection = FakeConnection(proxy: proxy)
        let factory = ConnectionFactory([connection])
        let transport = XPCVPNHelperTransport(connectionFactory: { factory.make() })

        await expectTransportError(.deadlineExceeded) {
            try await transport.send(command: .startSession, requestData: Data(), timeout: 0.01)
        }
        storedReply.take()?(Data("late".utf8), nil)
        proxy.handle = { _, _, reply in reply(Data("next".utf8), nil) }
        let received = try await transport.send(command: .status, requestData: Data(), timeout: 1)
        precondition(received == Data("next".utf8))
        precondition(factory.creationCount == 1)
    }

    private static func verifiesInvalidResponseMapping() async {
        let proxy = FakeProxy { _, _, reply in reply(nil, nil) }
        let connection = FakeConnection(proxy: proxy)
        let factory = ConnectionFactory([connection])
        let transport = XPCVPNHelperTransport(connectionFactory: { factory.make() })

        await expectTransportError(.invalidResponse("The privileged helper returned neither data nor an error")) {
            try await transport.send(command: .readDiagnostics, requestData: Data(), timeout: 1)
        }
    }
}

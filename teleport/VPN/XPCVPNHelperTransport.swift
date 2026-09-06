import Foundation
import Synchronization

nonisolated protocol VPNHelperXPCConnection: Sendable {
    func setRemoteObjectInterface(_ interface: NSXPCInterface)
    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void)
    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void)
    func remoteProxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> (any VPNHelperXPCProtocol)?
    func activate()
    func invalidate()
}

/// `NSXPCConnection` is not declared Sendable by Foundation, although it owns a
/// private serial queue for proxy calls and lifecycle handlers. The wrapped reference
/// is immutable; transport-owned connection replacement remains protected by `state`.
nonisolated final class FoundationVPNHelperXPCConnection: VPNHelperXPCConnection, @unchecked Sendable {
    private let connection: NSXPCConnection

    init(
        connection: NSXPCConnection = NSXPCConnection(
            machServiceName: VPNHelperProtocol.machServiceName,
            options: .privileged
        )
    ) {
        self.connection = connection
    }

    func setRemoteObjectInterface(_ interface: NSXPCInterface) {
        connection.remoteObjectInterface = interface
    }

    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {
        connection.interruptionHandler = handler
    }

    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        connection.invalidationHandler = handler
    }

    func remoteProxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> (any VPNHelperXPCProtocol)? {
        connection.remoteObjectProxyWithErrorHandler(errorHandler) as? VPNHelperXPCProtocol
    }

    func activate() {
        connection.activate()
    }

    func invalidate() {
        connection.invalidate()
    }
}

nonisolated final class XPCVPNHelperTransport: VPNHelperTransport {
    typealias ConnectionFactory = @Sendable () -> any VPNHelperXPCConnection

    private struct ConnectionRecord: Sendable {
        let connection: any VPNHelperXPCConnection
        let generation: UInt64
    }

    private struct ConnectionCreation: Sendable {
        let generation: UInt64
        var record: ConnectionRecord?
        var retirementError: VPNHelperTransportError?
    }

    private struct PendingRequest: Sendable {
        let generation: UInt64
        let completion: Completion
    }

    private struct State: Sendable {
        var connection: ConnectionRecord?
        var connectionCreation: ConnectionCreation?
        var nextGeneration: UInt64 = 0
        var pendingRequests: [UUID: PendingRequest] = [:]
    }

    private final class Completion: Sendable {
        private typealias Waiter = CheckedContinuation<Result<Data, VPNHelperTransportError>, Never>

        private struct Storage {
            var result: Result<Data, VPNHelperTransportError>?
            var waiter: Waiter?
        }

        private let state = Mutex(Storage())

        @discardableResult
        func resolve(_ result: Result<Data, VPNHelperTransportError>) -> Bool {
            let (didResolve, waiter) = state.withLock { storage -> (Bool, Waiter?) in
                guard storage.result == nil else { return (false, nil) }
                storage.result = result
                let waiter = storage.waiter
                storage.waiter = nil
                return (true, waiter)
            }
            waiter?.resume(returning: result)
            return didResolve
        }

        /// Suspends until the first `resolve`, failing with `.deadlineExceeded` when the
        /// deadline arrives first. The deadline is a racing task rather than a blocked
        /// thread, so no thread is parked for the duration of a helper command.
        func value(timeout: TimeInterval) async throws -> Data {
            let deadline = Task { [self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                resolve(.failure(.deadlineExceeded))
            }
            defer { deadline.cancel() }

            let result = await withCheckedContinuation { (continuation: Waiter) in
                let resolved = state.withLock { storage -> Result<Data, VPNHelperTransportError>? in
                    if let result = storage.result { return result }
                    storage.waiter = continuation
                    return nil
                }
                if let resolved {
                    continuation.resume(returning: resolved)
                }
            }
            return try result.get()
        }
    }

    private let connectionFactory: ConnectionFactory
    private let connectionCreationLock = Mutex<Void>(())
    private let state = Mutex(State())

    init(
        connectionFactory: @escaping ConnectionFactory = {
            FoundationVPNHelperXPCConnection()
        }
    ) {
        self.connectionFactory = connectionFactory
    }

    func send(
        command: VPNHelperCommand,
        requestData: Data,
        timeout: TimeInterval
    ) async throws -> Data {
        guard requestData.count <= VPNHelperProtocol.maximumRequestBytes else {
            throw VPNHelperTransportError.invalidResponse(
                "The privileged helper request exceeds the protocol limit"
            )
        }

        let record = try connectionRecord()
        let requestToken = UUID()
        let completion = Completion()
        let registered = state.withLock { state in
            guard state.connection?.generation == record.generation else {
                return false
            }
            state.pendingRequests[requestToken] = PendingRequest(
                generation: record.generation,
                completion: completion
            )
            return true
        }
        guard registered else {
            throw VPNHelperTransportError.invalidated
        }

        let proxy = record.connection.remoteProxy { [weak self, completion] error in
            let transportError = Self.proxyInvocationError(
                for: command,
                message: error.localizedDescription
            )
            completion.resolve(.failure(transportError))
            self?.retireConnection(
                generation: record.generation,
                error: transportError,
                invalidatingConnection: true
            )
        }

        guard let proxy else {
            completion.resolve(.failure(.invalidResponse(
                "The privileged helper did not provide an XPC proxy"
            )))
            retireConnection(
                generation: record.generation,
                error: .invalidated,
                invalidatingConnection: true
            )
            return try await finish(
                completion: completion,
                token: requestToken,
                timeout: timeout
            )
        }

        let reply: (Data?, NSError?) -> Void = { data, error in
            if let error {
                completion.resolve(.failure(Self.proxyInvocationError(
                    for: command,
                    message: error.localizedDescription
                )))
                return
            }
            guard let data else {
                completion.resolve(.failure(.invalidResponse(
                    "The privileged helper returned neither data nor an error"
                )))
                return
            }
            guard !data.isEmpty else {
                completion.resolve(.failure(.invalidResponse(
                    "The privileged helper returned an empty response"
                )))
                return
            }
            guard data.count <= VPNHelperProtocol.maximumResponseBytes else {
                completion.resolve(.failure(.invalidResponse(
                    "The privileged helper response exceeds the protocol limit"
                )))
                return
            }
            completion.resolve(.success(data))
        }

        switch command {
        case .status:
            proxy.getStatus(requestData, withReply: reply)
        case .startSession:
            proxy.startSession(requestData, withReply: reply)
        case .stopSession:
            proxy.stopSession(requestData, withReply: reply)
        case .readDiagnostics:
            proxy.readDiagnostics(requestData, withReply: reply)
        }

        return try await finish(
            completion: completion,
            token: requestToken,
            timeout: timeout
        )
    }

    func invalidate() {
        let retired = state.withLock {
            state -> (ConnectionRecord?, ConnectionRecord?, [Completion]) in
            let record = state.connection
            state.connection = nil

            var creatingRecord: ConnectionRecord?
            if var creation = state.connectionCreation {
                if creation.retirementError == nil {
                    creation.retirementError = .invalidated
                }
                creatingRecord = creation.record
                state.connectionCreation = creation
            }

            let completions = state.pendingRequests.values.map(\.completion)
            state.pendingRequests.removeAll()
            return (record, creatingRecord, completions)
        }

        retired.0?.connection.invalidate()
        retired.1?.connection.invalidate()
        for completion in retired.2 {
            completion.resolve(.failure(.invalidated))
        }
    }

    private func connectionRecord() throws -> ConnectionRecord {
        try connectionCreationLock.withLock { _ in
            if let record = state.withLock({ $0.connection }) {
                return record
            }

            let generation = state.withLock { state -> UInt64 in
                state.nextGeneration &+= 1
                state.connectionCreation = ConnectionCreation(
                    generation: state.nextGeneration,
                    record: nil,
                    retirementError: nil
                )
                return state.nextGeneration
            }
            let connection = connectionFactory()
            let record = ConnectionRecord(connection: connection, generation: generation)
            let initialError = state.withLock { state -> VPNHelperTransportError? in
                guard var creation = state.connectionCreation,
                      creation.generation == generation else {
                    return .invalidated
                }
                creation.record = record
                state.connectionCreation = creation
                return creation.retirementError
            }

            if initialError == nil {
                connection.setRemoteObjectInterface(Self.remoteInterface())
            }
            if connectionCreationError(for: generation) == nil {
                connection.setInterruptionHandler { [weak self] in
                    self?.retireConnection(
                        generation: generation,
                        error: .interrupted,
                        invalidatingConnection: true
                    )
                }
            }
            if connectionCreationError(for: generation) == nil {
                connection.setInvalidationHandler { [weak self] in
                    self?.retireConnection(
                        generation: generation,
                        error: .invalidated,
                        invalidatingConnection: false
                    )
                }
            }
            if connectionCreationError(for: generation) == nil {
                connection.activate()
            }

            let result = state.withLock {
                state -> Result<ConnectionRecord, VPNHelperTransportError> in
                guard let creation = state.connectionCreation,
                      creation.generation == generation else {
                    return .failure(.invalidated)
                }

                state.connectionCreation = nil
                if let error = creation.retirementError {
                    return .failure(error)
                }

                state.connection = record
                return .success(record)
            }
            if case .failure = result {
                connection.invalidate()
            }
            return try result.get()
        }
    }

    private func connectionCreationError(
        for generation: UInt64
    ) -> VPNHelperTransportError? {
        state.withLock { state in
            guard let creation = state.connectionCreation,
                  creation.generation == generation else {
                return .invalidated
            }
            return creation.retirementError
        }
    }

    private static func proxyInvocationError(
        for command: VPNHelperCommand,
        message: String
    ) -> VPNHelperTransportError {
        switch command {
        case .startSession, .stopSession:
            // A proxy/reply-channel error does not prove whether a mutating
            // message reached the helper, so the client must reconcile it.
            return .interrupted
        case .status, .readDiagnostics:
            return .unavailable(message)
        }
    }

    private static func remoteInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: VPNHelperXPCProtocol.self)
        let dataClasses = NSSet(object: NSData.self) as! Set<AnyHashable>
        let errorClasses = NSSet(object: NSError.self) as! Set<AnyHashable>
        let methods = [
            #selector(VPNHelperXPCProtocol.getStatus(_:withReply:)),
            #selector(VPNHelperXPCProtocol.startSession(_:withReply:)),
            #selector(VPNHelperXPCProtocol.stopSession(_:withReply:)),
            #selector(VPNHelperXPCProtocol.readDiagnostics(_:withReply:))
        ]

        for method in methods {
            interface.setClasses(dataClasses, for: method, argumentIndex: 0, ofReply: false)
            interface.setClasses(dataClasses, for: method, argumentIndex: 0, ofReply: true)
            interface.setClasses(errorClasses, for: method, argumentIndex: 1, ofReply: true)
        }
        return interface
    }

    private func finish(
        completion: Completion,
        token: UUID,
        timeout: TimeInterval
    ) async throws -> Data {
        defer {
            _ = state.withLock { state in
                state.pendingRequests.removeValue(forKey: token)
            }
        }
        return try await completion.value(timeout: timeout)
    }

    private func retireConnection(
        generation: UInt64,
        error: VPNHelperTransportError,
        invalidatingConnection: Bool
    ) {
        let retired = state.withLock { state -> (ConnectionRecord?, [Completion]) in
            let record: ConnectionRecord?
            if var creation = state.connectionCreation,
               creation.generation == generation {
                if creation.retirementError == nil {
                    creation.retirementError = error
                }
                record = creation.record
                state.connectionCreation = creation
            } else if state.connection?.generation == generation {
                record = state.connection
                state.connection = nil
            } else {
                record = nil
            }

            let matchingTokens = state.pendingRequests.compactMap { token, request in
                request.generation == generation ? token : nil
            }
            let completions = matchingTokens.compactMap { token in
                state.pendingRequests.removeValue(forKey: token)?.completion
            }
            return (record, completions)
        }

        if invalidatingConnection {
            retired.0?.connection.invalidate()
        }
        for completion in retired.1 {
            completion.resolve(.failure(error))
        }
    }
}

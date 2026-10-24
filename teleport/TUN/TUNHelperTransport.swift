import Foundation

nonisolated protocol TUNHelperTransport: Sendable {
    func send(
        command: TUNHelperCommand,
        requestData: Data,
        timeout: TimeInterval
    ) async throws -> Data

    func invalidate()
}

nonisolated enum TUNHelperTransportError: Error, Equatable {
    case unavailable(String)
    case interrupted
    case invalidated
    case deadlineExceeded
    case invalidResponse(String)
}

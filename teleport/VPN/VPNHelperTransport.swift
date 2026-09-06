import Foundation

nonisolated protocol VPNHelperTransport: Sendable {
    func send(
        command: VPNHelperCommand,
        requestData: Data,
        timeout: TimeInterval
    ) async throws -> Data

    func invalidate()
}

nonisolated enum VPNHelperTransportError: Error, Equatable {
    case unavailable(String)
    case interrupted
    case invalidated
    case deadlineExceeded
    case invalidResponse(String)
}

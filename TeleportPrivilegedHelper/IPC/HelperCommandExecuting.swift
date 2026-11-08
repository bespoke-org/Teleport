import Foundation

protocol HelperCommandExecuting: Sendable {
    func resolveEndpoint(request: ResolveEndpointRequest) throws -> ResolveEndpointResponse
    func status(request: StatusRequest) throws -> StatusResponse
    func start(request: StartSessionRequest, sessionID: UUID) throws -> StartSessionResponse
    func stop(request: StopSessionRequest, sessionID: UUID) throws -> StopSessionResponse
    func readDiagnostics(request: ReadDiagnosticsRequest) throws -> DiagnosticsResponse
    func engageLeakGuard(request: EngageLeakGuardRequest) throws -> LeakGuardResponse
    func releaseLeakGuard(request: ReleaseLeakGuardRequest) throws -> LeakGuardResponse
}

// Test executors that only exercise lifecycle commands need no network resolver.
extension HelperCommandExecuting {
    func resolveEndpoint(request: ResolveEndpointRequest) throws -> ResolveEndpointResponse {
        throw HelperError("Endpoint resolution is unavailable")
    }
}

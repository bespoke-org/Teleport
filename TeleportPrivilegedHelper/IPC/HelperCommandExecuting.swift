import Foundation

protocol HelperCommandExecuting: Sendable {
    func readProxyPreferences(request: ReadProxyPreferencesRequest) throws -> ProxyPreferencesSnapshot
    func applyProxyPreferences(request: ApplyProxyPreferencesRequest) throws -> ApplyProxyPreferencesResponse
    func status(request: StatusRequest) throws -> StatusResponse
    func start(request: StartSessionRequest, sessionID: UUID) throws -> StartSessionResponse
    func stop(request: StopSessionRequest, sessionID: UUID) throws -> StopSessionResponse
    func readDiagnostics(request: ReadDiagnosticsRequest) throws -> DiagnosticsResponse
    func engageLeakGuard(request: EngageLeakGuardRequest) throws -> LeakGuardResponse
    func releaseLeakGuard(request: ReleaseLeakGuardRequest) throws -> LeakGuardResponse
}

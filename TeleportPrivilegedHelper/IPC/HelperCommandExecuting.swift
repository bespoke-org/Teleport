import Foundation

protocol HelperCommandExecuting: Sendable {
    func status(request: StatusRequest) throws -> StatusResponse
    func start(request: StartSessionRequest, sessionID: UUID) throws -> StartSessionResponse
    func stop(request: StopSessionRequest, sessionID: UUID) throws -> StopSessionResponse
    func readDiagnostics(request: ReadDiagnosticsRequest) throws -> DiagnosticsResponse
}

import Foundation

/// Transitional synchronous adapter used only below `ConnectionProvider`.
/// Phase 2 serializes every call through `BackendConnectionProvider`.
nonisolated protocol ConnectionBackend: AnyObject, Sendable {
    func hasRestorableState() -> Bool
    func hasActiveRuntimeSession() -> Bool
    func restorePreviousState() throws
    func start(configuration: ConnectionConfiguration, endpoint: ProxyEndpoint, splitTunnelRules: [SplitTunnelRule], splitTunnelDefaultAction: SplitTunnelRuleAction) throws
    func reconnect(configuration: ConnectionConfiguration, endpoint: ProxyEndpoint, shouldDisableExistingProxy: Bool, splitTunnelRules: [SplitTunnelRule], splitTunnelDefaultAction: SplitTunnelRuleAction) throws
    func stop(shouldDisableProxy: Bool) throws
    func teardown()
}

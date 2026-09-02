import Foundation

protocol ConnectionBackend: AnyObject {
    func hasRestorableState() -> Bool
    func hasActiveRuntimeSession() -> Bool
    func restorePreviousState() throws
    func start(configuration: ConnectionConfiguration, endpoint: ProxyEndpoint, splitTunnelRules: [SplitTunnelRule], splitTunnelDefaultAction: SplitTunnelRuleAction) throws
    func reconnect(configuration: ConnectionConfiguration, endpoint: ProxyEndpoint, shouldDisableExistingProxy: Bool, splitTunnelRules: [SplitTunnelRule], splitTunnelDefaultAction: SplitTunnelRuleAction) throws
    func stop(shouldDisableProxy: Bool) throws
    func teardown()
}

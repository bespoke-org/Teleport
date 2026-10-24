import Foundation

@objc nonisolated protocol VPNHelperXPCProtocol {
    func getStatus(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func startSession(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func stopSession(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func readDiagnostics(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func engageLeakGuard(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func releaseLeakGuard(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
}

nonisolated enum VPNHelperProtocol {
    static let revision: UInt = 10
    static let machServiceName = "dev.x.teleport.helper"
    static let maximumRequestBytes = 1_048_576
    static let maximumConfigurationBytes = 524_288
    static let maximumResponseBytes = 1_048_576
    static let maximumDiagnosticsBytes = 262_144
    /// One protected host route per proxy server the session dials, plus the
    /// servers a health check holds open while it questions them — the probe queue
    /// runs several checks at once, so this has to cover a burst of them as well as
    /// the session itself. Bounded like every other payload field so a client
    /// cannot make the helper install an unbounded number of routes.
    static let maximumProtectedHosts = 64
    /// The client renews the leak-guard lease well inside this; the helper clamps
    /// anything longer so a client cannot ask for a guard it never has to renew.
    static let maximumLeakGuardLeaseSeconds: Double = 180
}

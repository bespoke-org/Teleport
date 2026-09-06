import Foundation

@objc nonisolated protocol VPNHelperXPCProtocol {
    func getStatus(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func startSession(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func stopSession(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func readDiagnostics(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
}

nonisolated enum VPNHelperProtocol {
    static let revision: UInt = 9
    static let machServiceName = "dev.x.teleport.helper"
    static let maximumRequestBytes = 1_048_576
    static let maximumConfigurationBytes = 524_288
    static let maximumResponseBytes = 1_048_576
    static let maximumDiagnosticsBytes = 262_144
    /// One protected host route per proxy server the session dials. Bounded like
    /// every other payload field so a client cannot make the helper install an
    /// unbounded number of routes.
    static let maximumProtectedHosts = 8
}

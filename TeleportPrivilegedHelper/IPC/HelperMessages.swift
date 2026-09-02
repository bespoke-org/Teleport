import Foundation

/// Helper-side mirror of `PrivilegedHelperRequest`. `Codable` maps the Swift
/// fields to the JSON object received over the Unix-domain socket.
struct HelperRequest: Codable {
    var command: String
    var stateDirectoryPath: String?
    var configPath: String?
    var configData: Data?
    var protectedHost: String?
    var tunnelInterfaceName: String?
    var outboundInterface: String?
    var pid: Int32?
    var logName: String?
    var maxBytes: Int?
}

struct HelperResponse: Codable {
    var success: Bool
    var version: String?
    var summary: String?
    var details: String?
}

struct HelperError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message.isEmpty ? "Privileged helper command failed" : message
    }

    var errorDescription: String? { message }
}

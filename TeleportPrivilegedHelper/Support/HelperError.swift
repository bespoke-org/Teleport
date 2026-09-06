import Foundation

struct HelperError: LocalizedError, VPNHelperClientPresentableError {
    let message: String

    init(_ message: String) {
        self.message = message.isEmpty ? "Privileged helper command failed" : message
    }

    var errorDescription: String? { message }
    var clientSummary: String { message }
}

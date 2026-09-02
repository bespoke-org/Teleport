import Foundation

/// Legacy installation bridge that asks macOS to execute one generated shell
/// script as an administrator. Normal connect/disconnect traffic does not use
/// AppleScript; it goes through the authenticated helper socket instead.
///
/// Every interpolated value crossing this boundary must be shell-quoted first.
struct PrivilegedShellRunner: Sendable {
    func runAdministratorShellScript(_ shellScript: String, prompt: String? = nil) throws {
        var appleScript = "do shell script \"\(Self.appleScriptQuote(shellScript))\" with administrator privileges"
        if let prompt, !prompt.isEmpty {
            appleScript += " with prompt \"\(Self.appleScriptQuote(prompt))\""
        }

        guard let script = NSAppleScript(source: appleScript) else {
            throw PrivilegedShellError.commandFailed("Failed to prepare administrator prompt")
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let message = [
                errorInfo[NSAppleScript.errorMessage] as? String,
                errorInfo[NSAppleScript.errorBriefMessage] as? String
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

            throw PrivilegedShellError.commandFailed(message)
        }
    }

    /// Produces one POSIX-shell single-quoted argument, including embedded quotes.
    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes the already-generated shell script for its AppleScript string literal.
    nonisolated static func appleScriptQuote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum PrivilegedShellError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(message):
            return message.isEmpty ? "Privileged command failed" : message
        }
    }
}

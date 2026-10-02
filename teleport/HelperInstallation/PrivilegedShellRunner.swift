import Foundation

/// Legacy installation bridge that asks macOS to execute one generated shell
/// script as an administrator. Normal connect/disconnect traffic does not use
/// AppleScript; it goes through the authenticated helper socket instead.
///
/// Every interpolated value crossing this boundary must be shell-quoted first.
nonisolated struct PrivilegedShellRunner: Sendable {
    /// Runs through `osascript` rather than `NSAppleScript`, which may only be used
    /// on the main thread: the prompt and the install behind it take seconds, and
    /// the app has to keep drawing meanwhile.
    func runAdministratorShellScript(_ shellScript: String, prompt: String? = nil) async throws {
        var appleScript = "do shell script \"\(Self.appleScriptQuote(shellScript))\" with administrator privileges"
        if let prompt, !prompt.isEmpty {
            appleScript += " with prompt \"\(Self.appleScriptQuote(prompt))\""
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: PrivilegedShellError.commandFailed("Failed to prepare administrator prompt"))
            }
        }

        guard status == 0 else {
            let output = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw PrivilegedShellError.commandFailed(Self.errorMessage(fromOSAScriptOutput: output))
        }
    }

    /// `osascript` reports "0:42: execution error: User canceled. (-128)"; the part
    /// between the prefix and the error number is what NSAppleScript used to return.
    nonisolated static func errorMessage(fromOSAScriptOutput output: String) -> String {
        var message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = message.range(of: "execution error: ") {
            message = String(message[range.upperBound...])
        }
        if let range = message.range(of: #" \(-?\d+\)$"#, options: .regularExpression) {
            message.removeSubrange(range)
        }
        return message
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

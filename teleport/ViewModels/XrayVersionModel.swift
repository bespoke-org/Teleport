import Combine
import Foundation

/// App-session metadata, loaded at launch independently of the About page.
@MainActor
final class XrayVersionModel: ObservableObject {
    @Published private(set) var version = "Checking\u{2026}"
    private let readVersion: @MainActor () async -> String
    private var loadTask: Task<String, Never>?

    init(readVersion: @escaping @MainActor () async -> String = { await XrayVersionModel.readXrayVersion() }) {
        self.readVersion = readVersion
    }

    func load() async {
        let task: Task<String, Never>
        if let loadTask {
            task = loadTask
        } else {
            task = Task { await readVersion() }
            loadTask = task
        }
        let result = await task.value
        if version != result { version = result }
    }

    var versionNumber: String {
        let parts = version.split(whereSeparator: \.isWhitespace)
        guard parts.count > 1, parts[0] == "Xray" else { return version }
        return String(parts[1])
    }

    private enum XrayVersionProbe: Sendable {
        case version(String)
        case failure(String)
    }

    private nonisolated static func readXrayVersion() async -> String {
        guard let xrayURL = Bundle.main.url(forResource: "xray", withExtension: nil) else {
            return "Bundled xray not found"
        }

        // Current Xray builds accept `version`, older ones only `--version`. Failures
        // must report themselves as failures so the second spelling is actually
        // tried, rather than surfacing "Timed out" as if it were a version string.
        var lastFailure: String?
        for arguments in [["version"], ["--version"]] {
            switch await runXrayVersionCommand(xrayURL, arguments: arguments) {
            case let .version(version):
                return version
            case let .failure(reason):
                lastFailure = reason
            }
        }
        return lastFailure ?? "Unavailable"
    }

    private nonisolated static func runXrayVersionCommand(
        _ xrayURL: URL,
        arguments: [String]
    ) async -> XrayVersionProbe {
        // Spawning a process and waiting for it to exit has no asynchronous form,
        // so it runs off the cooperative pool instead of on the main actor, where it
        // used to freeze the Settings window for up to two seconds per attempt.
        await BlockingWork.run {
            let process = Process()
            let outputPipe = Pipe()

            process.executableURL = xrayURL
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            do {
                try process.run()
            } catch {
                return .failure("Unavailable")
            }

            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }

            if process.isRunning {
                process.terminate()
                return .failure("Timed out")
            }

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard process.terminationStatus == 0 else {
                return .failure("Unavailable (xray exited with status \(process.terminationStatus))")
            }
            guard let firstLine = output.split(separator: "\n").first else {
                return .failure("Unavailable")
            }
            return .version(String(firstLine))
        }
    }
}

import AppKit
import Foundation
import SwiftUI

struct AboutSettingsView: View {
    @State private var xrayVersion = "Checking\u{2026}"

    private let sourceCodeURL = URL(string: "https://codeberg.org/chernigin/teleport")!
    private let issuesURL = URL(string: "https://codeberg.org/chernigin/teleport/issues")!

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Teleport")
                        .font(.largeTitle.weight(.semibold))
                    Text("A tiny Xray menu bar client.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                aboutRow("App version", appVersion)
                aboutRow("Helper version", PrivilegedHelperConstants.version)
                aboutRow("Xray version", xrayVersion)
                aboutRow("Copyright", copyrightText)
                aboutRow("License", "GPL-3.0-or-later")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 10) {
                Button("Source code") {
                    NSWorkspace.shared.open(sourceCodeURL)
                }

                Button("Report a Bug") {
                    NSWorkspace.shared.open(issuesURL)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            xrayVersion = await Self.readXrayVersion()
        }
    }

    private var appVersion: String {
        let dictionary = Bundle.main.infoDictionary
        return dictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
    }

    private var copyrightText: String {
        let year = Calendar.current.component(.year, from: Date())
        return "© \(year) Michael Chernigin"
    }

    private func aboutRow(_ title: String, _ value: String) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                Text(title)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                Text(value)
                    .textSelection(.enabled)
            }
        }
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

            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
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

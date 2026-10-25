import AppKit
import Foundation
import SwiftUI

struct AboutSettingsView: View {
    @State private var xrayVersion = "Checking\u{2026}"

    private let sourceCodeURL = URL(string: "https://github.com/bespoke-org/Teleport")!
    private let issuesURL = URL(string: "https://github.com/bespoke-org/Teleport/issues")!
    private let licenseURL = URL(string: "https://github.com/bespoke-org/Teleport/blob/develop/LICENSE")!
    private let thirdPartyNoticesURL = URL(string: "https://github.com/bespoke-org/Teleport/blob/develop/THIRD_PARTY_NOTICES.md")!

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Teleport")
                            .font(.title2.weight(.semibold))
                        Text("Tiny menu bar Xray client for your Mac")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section("Versions") {
                LabeledContent("App version", value: appVersion)
                LabeledContent("Xray version", value: xrayVersionNumber)
                    .help(xrayVersion)
                LabeledContent("Helper version", value: PrivilegedHelperConstants.version)
            }

            Section {
                Link("Source code", destination: sourceCodeURL)
                Link("Report a bug", destination: issuesURL)
            } header: {
                Text("Project links")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(copyrightText)
                    HStack(spacing: 12) {
                        Link("GPL-3.0-or-later", destination: licenseURL)
                        Link("Third-party notices", destination: thirdPartyNoticesURL)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
        .padding(.top, -20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            xrayVersion = await Self.readXrayVersion()
        }
    }

    private var appVersion: String {
        let dictionary = Bundle.main.infoDictionary
        return dictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    private var copyrightText: String {
        "© 2026 Michael Chernigin, Nikita Rydanov"
    }

    private var xrayVersionNumber: String {
        let parts = xrayVersion.split(whereSeparator: \.isWhitespace)
        guard parts.count > 1, parts[0] == "Xray" else { return xrayVersion }
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

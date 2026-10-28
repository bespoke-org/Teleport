import AppKit
import Foundation
import SwiftUI

struct AboutSettingsView: View {
    @EnvironmentObject private var xrayVersion: XrayVersionModel

    private let sourceCodeURL = URL(string: "https://github.com/bespoke-org/Teleport")!
    private let issuesURL = URL(string: "https://github.com/bespoke-org/Teleport/issues")!
    private let supportURL = URL(string: "https://github.com/bespoke-org/Teleport#buy-us-some-tokens")!
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
                LabeledContent("Xray version", value: xrayVersion.versionNumber)
                    .help(xrayVersion.version)
                LabeledContent("Helper version", value: PrivilegedHelperConstants.version)
            }

            Section {
                SourceCodeLink(destination: sourceCodeURL)
                Link(destination: issuesURL) {
                    Label("Report a bug", systemImage: "ladybug")
                }
                Link(destination: supportURL) {
                    Label("Support development", systemImage: "heart")
                }
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
    }

    private var appVersion: String {
        let dictionary = Bundle.main.infoDictionary
        return dictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    private var copyrightText: String {
        "© 2026 Michael Chernigin, Nikita Rydanov"
    }
}

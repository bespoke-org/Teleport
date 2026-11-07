import AppKit
import SwiftUI

struct SettingsIssue: Equatable {
    enum Kind: Equatable { case action, connection }
    let kind: Kind
    let failure: ConnectionFailure

    var title: String { kind == .connection ? "Connection failed" : "Action failed" }

    static func resolve(message: String?, details: String?, connection: ConnectionFailure?) -> SettingsIssue? {
        if let message, message != connection?.summary || details != connection?.details {
            return SettingsIssue(kind: .action, failure: ConnectionFailure(summary: message, details: details))
        }
        return connection.map { SettingsIssue(kind: .connection, failure: $0) }
    }
}

/// A persistent toolbar status. Opening or closing its details never acknowledges
/// the failure; only Dismiss clears it, and only if it is still the same failure.
struct SettingsErrorIndicator: View {
    @ObservedObject var viewModel: AppViewModel
    let onOpenLogs: () -> Void

    private var issue: SettingsIssue? {
        SettingsIssue.resolve(message: viewModel.lastError, details: viewModel.lastErrorDetails,
                              connection: viewModel.connectionError)
    }

    var body: some View {
        HStack(spacing: 8) {
            if viewModel.canAllowDirectTraffic {
                Button("Allow direct traffic", action: viewModel.allowDirectTraffic)
                    .help("Release leak guard and use the regular internet connection")
            }
            SettingsErrorControl(issue: issue, onDismiss: { displayedIssue in
            guard issue == displayedIssue else { return }
            switch displayedIssue.kind {
            case .action: viewModel.clearError()
            case .connection: viewModel.dismissConnectionError()
            }
            }, onOpenLogs: onOpenLogs)
        }
    }
}

struct SettingsErrorControl: View {
    let issue: SettingsIssue?
    let onDismiss: (SettingsIssue) -> Void
    let onOpenLogs: () -> Void
    @State private var presentation: Presentation?

    private struct Presentation: Identifiable {
        let id = UUID()
        let issue: SettingsIssue
    }

    var body: some View {
        Group {
            if let issue {
                Button {
                    presentation = Presentation(issue: issue)
                } label: {
                    Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.red)
                }
                .help(issue.failure.briefSummary)
                .accessibilityLabel(issue.title + ": " + issue.failure.briefSummary)
                .accessibilityIdentifier("settingsErrorIndicator")
            }
        }
        .popover(item: $presentation, arrowEdge: .top) { displayed in
            SettingsErrorDetails(issue: displayed.issue, onClose: { presentation = nil }, onDismiss: {
                presentation = nil
                onDismiss(displayed.issue)
            }, onOpenLogs: {
                presentation = nil
                onOpenLogs()
            })
        }
        .onChange(of: issue) { _, updated in
            if presentation != nil { presentation = updated.map { Presentation(issue: $0) } }
        }
    }
}

private struct SettingsErrorDetails: View {
    let issue: SettingsIssue
    let onClose: () -> Void
    let onDismiss: () -> Void
    let onOpenLogs: () -> Void
    @State private var showsDetails = false
    @State private var contentHeight: CGFloat = 80
    @FocusState private var hasKeyboardFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Close error details")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(issue.failure.briefSummary)
                        .textSelection(.enabled)
                    if let recovery = issue.failure.recoveryInstructions {
                        Text(recovery).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let details = issue.failure.details, !details.isEmpty, details != issue.failure.summary {
                        DisclosureGroup("Technical details", isExpanded: $showsDetails) {
                            Text(details).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(max(contentHeight, 24), 240))
            Divider()
            HStack {
                Button("Copy error") {
                    let text = [issue.failure.summary, issue.failure.details].compactMap { $0 }.joined(separator: "\n\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Show logs", action: onOpenLogs)
                Spacer()
                Button("Dismiss", action: onDismiss)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 420)
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboardFocus)
        .onAppear { hasKeyboardFocus = true }
        .onExitCommand(perform: onClose)
    }
}

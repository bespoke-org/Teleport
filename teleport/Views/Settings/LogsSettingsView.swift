import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LogsSettingsView: View {
    @StateObject private var reader = LogReaderModel()
    @State private var selectedLog: SettingsLogFile = .app
    @State private var isLive = true
    @State private var refreshID = 0
    @State private var findID = 0
    @State private var jumpID = 0
    @State private var exportError: String?

    private var text: String { reader.snapshot?.text ?? "" }
    private var hasText: Bool { !text.isEmpty }
    private var liveUpdates: Bool { isLive && !selectedLog.isConfiguration }

    private struct RefreshRequest: Equatable {
        let source: SettingsLogFile
        let live: Bool
        let revision: Int
    }

    var body: some View {
        VStack(spacing: 10) {
            if let error = reader.error, hasText {
                Label("Couldn’t refresh: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ZStack {
                LogTextViewer(text: text, source: selectedLog, findID: findID, jumpID: jumpID)
                    .opacity(hasText ? 1 : 0)
                if !hasText { emptyState }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            }

            statusBar
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { controls }
        .onChange(of: selectedLog) { _, source in reader.select(source) }
        .task(id: RefreshRequest(source: selectedLog, live: liveUpdates, revision: refreshID)) {
            let source = selectedLog
            let live = liveUpdates
            repeat {
                await reader.refresh(source)
                guard live, !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            } while !Task.isCancelled
        }
        .alert("Couldn’t save file", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var sourcePicker: some View {
        LogSourcePicker(selection: $selectedLog)
            .fixedSize()
    }

    @ToolbarContentBuilder private var controls: some ToolbarContent {
        if !selectedLog.isConfiguration {
            ToolbarItem(id: "logs.live", placement: .primaryAction) {
                Button {
                    isLive.toggle()
                } label: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 14))
                        .foregroundStyle(isLive ? Color.accentColor : Color.primary)
                }
                .accessibilityLabel(isLive ? "Pause live updates" : "Resume live updates")
                .accessibilityValue(isLive ? "On" : "Off")
                .help(isLive ? "Pause live updates" : "Resume live updates")
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
        }

        ToolbarItem(id: "logs.find", placement: .primaryAction) {
            Button("Find", systemImage: "magnifyingglass") { findID += 1 }
                .labelStyle(.iconOnly)
                .help("Find in output")
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!hasText)
        }
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(id: "logs.refresh", placement: .primaryAction) {
            Button("Refresh", systemImage: "arrow.clockwise") { refreshID += 1 }
                .labelStyle(.iconOnly)
                .help("Refresh")
                .disabled(reader.isLoading)
        }
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(id: "logs.actions", placement: .primaryAction) {
            LogActionsMenu(items: menuItems)
                .frame(width: 36, height: 36)
        }
    }

    private var menuItems: [LogActionsMenu.Item] {
        let output = text
        let source = selectedLog
        var items: [LogActionsMenu.Item] = [
            .init(title: "Copy", symbol: "doc.on.doc", isEnabled: hasText) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(output, forType: .string)
            },
            .init(title: "Save to file…", symbol: "square.and.arrow.down", isEnabled: hasText) {
                saveOutput(output, source: source)
            }
        ]
        if source.helperLogName == nil {
            items.append(.init(title: "Show in Finder", symbol: "folder",
                               isEnabled: reader.snapshot != nil && reader.snapshot?.isMissing == false) {
                NSWorkspace.shared.activateFileViewerSelecting([source.url])
            })
        }
        return items
    }

    @ViewBuilder private var emptyState: some View {
        if let error = reader.error {
            ContentUnavailableView {
                Label("Couldn’t read \(selectedLog.title)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { refreshID += 1 }
                    .disabled(reader.isLoading)
            }
        } else if reader.snapshot == nil {
            ProgressView("Loading…")
        } else if reader.snapshot?.isMissing == true {
            ContentUnavailableView("File not created yet", systemImage: "doc",
                                   description: Text(selectedLog.missingExplanation))
        } else {
            ContentUnavailableView(selectedLog.isConfiguration ? "Configuration is empty" : "No log output yet",
                                   systemImage: "text.alignleft",
                                   description: Text(liveUpdates ? "New output will appear here automatically." : "Refresh to check for new output."))
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            sourcePicker
                .controlSize(.small)

            if let snapshot = reader.snapshot {
                Text("Updated \(snapshot.refreshedAt.formatted(date: .omitted, time: .standard))")
                    .monospacedDigit()
            } else if reader.isLoading {
                Text("Loading…")
            }
            if reader.snapshot?.isTruncated == true {
                Text("· Latest \(ByteCountFormatter.string(fromByteCount: Int64(LogReader.maximumBytes), countStyle: .file))")
                    .help("Only the displayed output is copied or saved.")
            }
            Spacer(minLength: 0)
            if !selectedLog.isConfiguration {
                Button("Scroll to bottom", systemImage: "arrow.down.to.line") { jumpID += 1 }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!hasText)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(minHeight: 24)
    }

    private func saveOutput(_ output: String, source: SettingsLogFile) {
        let panel = NSSavePanel()
        panel.preventsApplicationTerminationWhenModal = false
        panel.nameFieldStringValue = source.url.lastPathComponent
        panel.allowedContentTypes = source.isConfiguration ? [.json] : [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try output.write(to: url, atomically: true, encoding: .utf8) }
        catch { exportError = error.localizedDescription }
    }
}

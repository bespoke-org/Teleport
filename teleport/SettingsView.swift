import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var selectedSection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section as SettingsSection?)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200, maxHeight: .infinity)
            .navigationSplitViewColumnWidth(200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            selectedSectionView
                .navigationTitle((selectedSection ?? .general).title)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 500)
        .onAppear {
            if selectedSection == nil {
                selectedSection = .general
            }
        }
    }

    @ViewBuilder
    private var selectedSectionView: some View {
        switch selectedSection ?? .general {
        case .general:
            GeneralSettingsView(viewModel: viewModel)
        case .connections:
            ConnectionsSettingsView(viewModel: viewModel)
        case .splitTunneling:
            SplitTunnelingSettingsView(viewModel: viewModel, onOpenGeodata: { selectedSection = .geodata })
        case .geodata:
            GeodataSettingsView()
        case .nerdShit:
            NerdShitSettingsView(viewModel: viewModel)
        case .about:
            AboutSettingsView()
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Form {
            Section {
                Picker(
                    selection: Binding(
                        get: { viewModel.connectionMode },
                        set: { viewModel.selectConnectionMode($0) }
                    )
                ) {
                    ForEach(ConnectionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: {
                    Text("Teleport mode")
                    Text("System Proxy routes apps that respect macOS proxy settings. VPN routes the whole device through Xray TUN and requires administrator approval. Disconnect before changing modes.")
                }
                .disabled(!viewModel.canChangeSelection || viewModel.hasActiveConnectionSession)
            }

            Section {
                Picker(
                    selection: Binding(
                        get: { viewModel.subscriptionConnectionSort },
                        set: { viewModel.selectSubscriptionConnectionSort($0) }
                    )
                ) {
                    ForEach(SubscriptionConnectionSort.allCases) { sort in
                        Text(sort.displayName).tag(sort)
                    }
                } label: {
                    Text("Configs order")
                    Text("Choose how imported subscription configs are ordered in Settings and the menu bar picker.")
                }

                Toggle(
                    isOn: Binding(
                        get: { viewModel.showsLatencyInMenuBarPicker },
                        set: { viewModel.setShowsLatencyInMenuBarPicker($0) }
                    )
                ) {
                    Text("Show latency in menu bar picker")
                    Text("Include latest health check latency next to connection names.")
                }

                Toggle(
                    isOn: Binding(
                        get: { viewModel.animatesMenuBarIcon },
                        set: { viewModel.setAnimatesMenuBarIcon($0) }
                    )
                ) {
                    Text("Animate menu bar icon")
                    Text("Show subtle portal particles while Teleport is active. May impact performance.")
                }
            }

            Section {
                Toggle(
                    isOn: Binding(
                        get: { viewModel.startsAtLogin },
                        set: { viewModel.setStartsAtLogin($0) }
                    )
                ) {
                    Text("Launch at login")
                    Text("Start Teleport automatically when you sign in.")
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, -20)
        .padding(.leading, -8)
        .padding(.trailing, -6)
        .navigationTitle("General")
        .onAppear {
            viewModel.refreshStartsAtLoginStatus()
        }
    }
}

private struct NerdShitSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var selectedLog: NerdLogFile = .systemProxy
    @State private var logText = ""
    @State private var logMetadata = ""

    private let maxLogBytes: UInt64 = 256 * 1024

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            logSection
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            selectedLog = viewModel.connectionMode == .vpn ? .vpn : .systemProxy
            refreshLog()
        }
        .onChange(of: selectedLog) { _, _ in
            refreshLog()
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Xray logs")
                .font(.headline)

            HStack(spacing: 10) {
                Picker("Log", selection: $selectedLog) {
                    ForEach(NerdLogFile.allCases) { logFile in
                        Text(logFile.title).tag(logFile)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180, alignment: .leading)

                Spacer(minLength: 8)

                Button("Refresh", systemImage: "arrow.clockwise") {
                    refreshLog()
                }

                Button("Copy Log", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText, forType: .string)
                }
                .disabled(logText.isEmpty)
            }

            Text(logMetadata)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            LogTextViewer(text: logText)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func refreshLog() {
        if let helperLogName = selectedLog.helperLogName {
            do {
                let response = try PrivilegedHelperClient().readLog(logName: helperLogName, maxBytes: Int(maxLogBytes))
                try response.validate()
                logText = response.details ?? ""
                logMetadata = response.summary ?? "Private helper log: \(helperLogName)"
            } catch {
                logText = ""
                logMetadata = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            return
        }

        let url = selectedLog.url
        logText = readTail(from: url)
        logMetadata = metadata(for: url)
    }

    private func readTail(from url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let offset = fileSize > maxLogBytes ? fileSize - maxLogBytes : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? ""

        if offset > 0 {
            return "… showing last \(ByteCountFormatter.string(fromByteCount: Int64(maxLogBytes), countStyle: .file)) …\n" + text
        }
        return text
    }

    private func metadata(for url: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return "Missing: \(url.path)"
        }

        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes[.modificationDate] as? Date
        let modifiedText = modified.map { Self.metadataDateFormatter.string(from: $0) } ?? "unknown"
        return "\(url.path) • \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) • modified \(modifiedText)"
    }

    private static let metadataDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

private struct LogTextViewer: NSViewRepresentable {
    let text: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = displayText

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        let nextText = displayText
        guard textView.string != nextText else { return }

        let visibleRect = scrollView.contentView.bounds
        textView.string = nextText
        textView.scrollToVisible(visibleRect)
    }

    private var displayText: String {
        text.isEmpty ? "No log output yet." : text
    }

    final class Coordinator {
        weak var textView: NSTextView?
    }
}

private enum NerdLogFile: String, CaseIterable, Identifiable, Hashable {
    case systemProxy
    case vpn
    case vpnControl

    var id: Self { self }

    var title: String {
        switch self {
        case .systemProxy:
            return "System Proxy"
        case .vpn:
            return "VPN"
        case .vpnControl:
            return "VPN Control"
        }
    }

    var helperLogName: String? {
        switch self {
        case .systemProxy:
            return nil
        case .vpn:
            return "xray-tun.log"
        case .vpnControl:
            return "xray-tun-control.log"
        }
    }

    var url: URL {
        switch self {
        case .systemProxy:
            return Self.applicationSupportDirectoryURL.appendingPathComponent("xray.log")
        case .vpn:
            return Self.helperStateDirectoryURL.appendingPathComponent("xray-tun.log")
        case .vpnControl:
            return Self.helperStateDirectoryURL.appendingPathComponent("xray-tun-control.log")
        }
    }

    static var applicationSupportDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("teleport", isDirectory: true)
    }

    static var helperStateDirectoryURL: URL {
        URL(fileURLWithPath: PrivilegedHelperConstants.helperStateDirectoryPath, isDirectory: true)
    }
}

private struct GeodataSettingsView: View {
    var body: some View {
        ContentUnavailableView(
            "Coming soon",
            systemImage: "globe",
            description: Text("Geosite category rules already work in Split Tunneling. Browsing available categories and updating the bundled geosite/geoip data will live here.")
        )
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case connections
    case splitTunneling
    case geodata
    case nerdShit
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .connections:
            return "Connections"
        case .splitTunneling:
            return "Split Tunneling"
        case .geodata:
            return "Geodata"
        case .nerdShit:
            return "Nerd shit"
        case .about:
            return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .connections:
            return "link"
        case .splitTunneling:
            return "point.topleft.down.curvedto.point.bottomright.up"
        case .geodata:
            return "globe"
        case .nerdShit:
            return "terminal"
        case .about:
            return "info.circle"
        }
    }
}

#Preview {
    SettingsView(viewModel: AppViewModel())
}

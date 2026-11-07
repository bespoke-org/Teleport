import SwiftUI

struct GeodataSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var draft = GeodataSourceDraft(settings: GeodataSourceSettings())
    @State private var showsValidation = false
    @State private var draftProfileID: UUID?

    private static let intervalOptions: [Int?] = [nil, 60, 360, 1440, 10080]

    private var isUpdating: Bool { !viewModel.updatingGeodataKinds.isEmpty || viewModel.isOperationPending }
    private var savedURLs: GeodataSourceDraft.URLs {
        let sources = viewModel.selectedProfileGeodataSources
        return .init(geosite: sources.geositeURLString, geoip: sources.geoipURLString)
    }
    private var hasChanges: Bool {
        draft.urls != savedURLs || GeodataKind.allCases.contains {
            draft.urls[$0] == nil && viewModel.hasCustomGeodata(kind: $0)
        }
    }
    private var actionTitle: String {
        if draft.choice == .bundled { return "Use bundled data" }
        if !draft.urls.usesDownloads { return "Download and apply" }
        return hasChanges ? "Download and apply" : "Update now"
    }

    var body: some View {
        Group {
            Section("Geodata") {
                Picker("Source", selection: Binding(
                    get: { draft.choice },
                    set: { choice in
                        draft.choice = choice
                        showsValidation = false
                        if GeodataKind.allCases.allSatisfy({ draft.validationError(for: $0) == nil }) {
                            applySource(forceDownload: false)
                        }
                    }
                )) {
                    Text("Bundled with Teleport").tag(GeodataSourceDraft.Choice.bundled)
                    ForEach(GeodataSourceDraft.presets) { provider in
                        Text(provider.name).tag(GeodataSourceDraft.Choice.provider(provider.id))
                    }
                    Text("Custom URLs").tag(GeodataSourceDraft.Choice.custom)
                }
                .disabled(isUpdating)

                if draft.choice == .custom {
                    Text("Leave a URL empty to use Teleport's bundled data for that kind.")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(spacing: 12) {
                        urlField("Geosite URL", kind: .geosite, text: $draft.geositeURL)
                        urlField("GeoIP URL", kind: .geoip, text: $draft.geoipURL)
                    }
                }

            }

            Section("Geodata updates") {
                Picker("Automatic updates", selection: Binding(
                    get: { savedURLs.usesDownloads ? viewModel.selectedSplitTunnelProfile?.geodataUpdateIntervalMinutes : nil },
                    set: { viewModel.setGeodataAutoUpdateIntervalMinutes($0) }
                )) {
                    ForEach(Self.intervalOptions, id: \.self) { option in
                        Text(intervalLabel(option)).tag(option)
                    }
                }
                .disabled(!savedURLs.usesDownloads)

                if hasChanges || draft.choice == .custom || draft.urls.usesDownloads || isUpdating {
                    HStack(spacing: 10) {
                        Button(actionTitle) { applySource(forceDownload: !hasChanges) }
                            .disabled(isUpdating)
                        if isUpdating {
                            Button("Cancel") { viewModel.cancelGeodataUpdates() }
                        }
                        Spacer()
                    }
                }
            }

            Section("Data") {
                datasetRow(.geosite)
                datasetRow(.geoip)
            }
        }
        .onAppear {
            if draftProfileID != viewModel.selectedSplitTunnelProfileID { syncDraft() }
        }
        .onChange(of: viewModel.selectedSplitTunnelProfileID) { _, _ in syncDraft() }
        .onChange(of: viewModel.selectedProfileGeodataSources) { _, _ in syncDraft() }
    }

    private func syncDraft() {
        draftProfileID = viewModel.selectedSplitTunnelProfileID
        let sources = viewModel.selectedProfileGeodataSources
        draft = GeodataSourceDraft(settings: GeodataSourceSettings(
            geositeURLString: sources.geositeURLString, geoipURLString: sources.geoipURLString))
    }

    private func urlField(_ title: String, kind: GeodataKind, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .frame(width: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                TextField(title, text: text, prompt: Text("https://…/\(kind.fileName)"))
                    .labelsHidden()
                    .accessibilityLabel(title)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isUpdating)
                    .onSubmit { applySource(forceDownload: false) }
                if showsValidation, let error = draft.validationError(for: kind) {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func datasetRow(_ kind: GeodataKind) -> some View {
        let settings = viewModel.geodataSettings
        let sameAttempt = viewModel.geodataLastAttemptSources == viewModel.selectedProfileGeodataSources
        let lastError = sameAttempt ? (kind == .geosite ? settings.geositeLastError : settings.geoipLastError) : nil
        let activeSource = kind == .geosite ? settings.geositeURLString : settings.geoipURLString
        let isActive = savedURLs[kind] == activeSource
        let lastUpdated = isActive ? (kind == .geosite ? settings.geositeLastUpdatedAt : settings.geoipLastUpdatedAt) : nil
        let downloaded = isActive && savedURLs[kind] != nil && viewModel.hasCustomGeodata(kind: kind)
        let updating = sameAttempt && viewModel.updatingGeodataKinds.contains(kind)

        return VStack(alignment: .leading, spacing: 6) {
            datasetStatus(kind, lastUpdated: lastUpdated, downloaded: downloaded, updating: updating, lastError: lastError)
            if let lastError, !updating {
                Text(lastError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    private func datasetStatus(_ kind: GeodataKind, lastUpdated: Date?, downloaded: Bool, updating: Bool, lastError: String?) -> some View {
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(kind.displayName)
                Text(kind == .geosite ? "Domains" : "IP ranges")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            Spacer(minLength: 16)
            if updating {
                ProgressView().controlSize(.mini)
                Text("Updating…").foregroundStyle(.secondary)
            } else {
                if downloaded, let lastUpdated {
                    Text("Updated \(Self.relativeFormatter.localizedString(for: lastUpdated, relativeTo: Date()))")
                        .foregroundStyle(.secondary)
                } else {
                    Text(downloaded ? "Updated previously" : (savedURLs[kind] == nil ? "Bundled" : "Downloads before connecting"))
                        .foregroundStyle(.secondary)
                }
                if let lastError {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .help(lastError)
                        .accessibilityLabel("Update failed: \(lastError)")
                }
            }
        }
        .lineLimit(1)
    }

    private func applySource(forceDownload: Bool) {
        guard !isUpdating else { return }
        showsValidation = true
        guard GeodataKind.allCases.allSatisfy({ draft.validationError(for: $0) == nil }) else { return }
        let urls = draft.urls
        if urls == savedURLs {
            viewModel.downloadSelectedProfileGeodata(forceDownload: forceDownload)
        } else {
            viewModel.applyGeodataSources(geositeURLString: urls.geosite, geoipURLString: urls.geoip,
                                         forceDownload: forceDownload)
        }
        showsValidation = false
    }

    private func intervalLabel(_ minutes: Int?) -> String {
        guard let minutes else { return "Off" }
        switch minutes {
        case 60: return "Every hour"
        case 360: return "Every 6 hours"
        case 1440: return "Every day"
        case 10080: return "Every week"
        default: return "Every \(minutes) minutes"
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

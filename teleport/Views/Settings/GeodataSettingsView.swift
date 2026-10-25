import SwiftUI

struct GeodataSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var draft = GeodataSourceDraft(settings: GeodataSourceSettings())
    @State private var showsValidation = false

    private static let intervalOptions: [Int?] = [nil, 60, 360, 1440, 10080]

    private var isUpdating: Bool { !viewModel.updatingGeodataKinds.isEmpty }
    private var savedURLs: GeodataSourceDraft.URLs { GeodataSourceDraft.savedURLs(viewModel.geodataSettings) }
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
        Form {
            Section {
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
                    VStack(spacing: 12) {
                        urlField("Geosite URL", kind: .geosite, text: $draft.geositeURL)
                        urlField("GeoIP URL", kind: .geoip, text: $draft.geoipURL)
                    }
                }

            } header: {
                Text("Domain and IP lists used by split-tunneling rules.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Picker("Automatic updates", selection: Binding(
                    get: { savedURLs.usesDownloads ? viewModel.geodataSettings.autoUpdateIntervalMinutes : nil },
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
        .formStyle(.grouped)
        .padding(.top, -20)
        .navigationTitle("Geodata")
        .onAppear { draft = GeodataSourceDraft(settings: viewModel.geodataSettings) }
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
        let lastError = kind == .geosite ? settings.geositeLastError : settings.geoipLastError
        let lastUpdated = kind == .geosite ? settings.geositeLastUpdatedAt : settings.geoipLastUpdatedAt
        let downloaded = viewModel.hasCustomGeodata(kind: kind)
        let updating = viewModel.updatingGeodataKinds.contains(kind)

        return HStack(spacing: 8) {
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
                    Text(downloaded ? "Updated previously" : "Bundled")
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
        viewModel.applyGeodataSources(geositeURLString: urls.geosite, geoipURLString: urls.geoip,
                                     forceDownload: forceDownload)
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

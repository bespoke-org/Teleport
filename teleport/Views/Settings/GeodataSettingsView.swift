import SwiftUI

struct GeodataSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    var horizontalInset: CGFloat = 20
    @State private var draft = GeodataSourceDraft(settings: GeodataSourceSettings())
    @State private var showsValidation = false
    @State private var draftProfileID: UUID?

    private static let intervalOptions: [Int?] = [nil, 60, 360, 1440, 10080]

    private var isUpdating: Bool { !viewModel.updatingSelectedProfileGeodataKinds.isEmpty || viewModel.isOperationPending }
    private var savedURLs: GeodataSourceDraft.URLs {
        let sources = viewModel.selectedProfileGeodataSources
        return .init(geosite: sources.geositeURLString, geoip: sources.geoipURLString)
    }
    private var hasChanges: Bool {
        draft.urls != savedURLs
    }
    private var actionTitle: String {
        if draft.choice == .bundled { return "Use bundled data" }
        if !draft.urls.usesDownloads { return "Download and apply" }
        return hasChanges ? "Download and apply" : "Update now"
    }

    var body: some View {
        Section {
            heading("Geodata")
            card {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Text("Source").foregroundStyle(.secondary)
                        SettingsChoicePicker(title: sourceTitle, selection: Binding(
                            get: { draft.choice }, set: selectSource
                        ), choices: sourceChoices)
                        .disabled(isUpdating)
                        .accessibilityLabel("Geodata source")
                        Spacer(minLength: 0)
                    }
                    if draft.choice == .custom {
                        urlField("Geosite URL", kind: .geosite, text: $draft.geositeURL)
                        urlField("GeoIP URL", kind: .geoip, text: $draft.geoipURL)
                        Text("An empty URL uses Teleport's bundled data.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 24) {
                        datasetRow(.geosite)
                        datasetRow(.geoip)
                    }
                    .font(.callout)
                    Divider().opacity(0.5)
                    HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            Text("Updates").foregroundStyle(.secondary)
                            SettingsChoicePicker(
                                title: intervalLabel(updateInterval),
                                selection: Binding(get: { updateInterval }, set: viewModel.setGeodataAutoUpdateIntervalMinutes),
                                choices: Self.intervalOptions.map { SettingsChoice(value: $0, title: intervalLabel($0)) },
                                font: .callout
                            )
                            .disabled(!savedURLs.usesDownloads)
                            .accessibilityLabel("Automatic geodata updates")
                        }
                        .font(.callout)
                        Spacer(minLength: 8)
                        if hasChanges || draft.choice == .custom || draft.urls.usesDownloads || isUpdating {
                            if isUpdating {
                                ProgressView().controlSize(.mini)
                                Button("Cancel") { viewModel.cancelGeodataUpdates() }
                            } else {
                                Button { applySource(forceDownload: !hasChanges) } label: {
                                    Label(actionTitle, systemImage: "arrow.clockwise")
                                }
                            }
                        }
                    }
                    .font(.callout)
                    .buttonStyle(.borderless)
                }
            }
        }
        .listSectionSeparator(.hidden)
        .onAppear {
            if draftProfileID != viewModel.selectedSplitTunnelProfileID { syncDraft() }
        }
        .onChange(of: viewModel.selectedSplitTunnelProfileID) { _, _ in syncDraft() }
        .onChange(of: viewModel.selectedProfileGeodataSources) { _, _ in syncDraft() }
    }

    private var sourceTitle: String {
        switch draft.choice {
        case .bundled: return "Bundled with Teleport"
        case .custom: return "Custom URLs"
        case .provider(let id): return GeodataSourceDraft.presets.first { $0.id == id }?.name ?? "Custom URLs"
        }
    }

    private var updateInterval: Int? {
        savedURLs.usesDownloads ? viewModel.selectedSplitTunnelProfile?.geodataUpdateIntervalMinutes : nil
    }

    private var sourceChoices: [SettingsChoice<GeodataSourceDraft.Choice>] {
        [SettingsChoice(value: .bundled, title: "Bundled with Teleport")]
            + GeodataSourceDraft.presets.map { SettingsChoice(value: .provider($0.id), title: $0.name) }
            + [SettingsChoice(value: .custom, title: "Custom URLs")]
    }

    private func selectSource(_ choice: GeodataSourceDraft.Choice) {
        draft.choice = choice
        showsValidation = false
        if GeodataKind.allCases.allSatisfy({ draft.validationError(for: $0) == nil }) {
            applySource(forceDownload: false)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: horizontalInset, bottom: 0, trailing: horizontalInset))
            .listRowBackground(
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035))
                    .padding(.horizontal, horizontalInset)
            )
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 20)
            .padding(.bottom, 8)
            // Match grouped Form headings after List's 16-point content inset.
            .listRowInsets(EdgeInsets(top: 0, leading: horizontalInset - 6, bottom: 0, trailing: horizontalInset))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
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
        let status = viewModel.profileGeodataStatus(kind: kind)
        let lastError: String? = { if case let .failed(message) = status { return message }; return nil }()
        let lastUpdated: Date? = { if case let .ready(date) = status { return date }; return nil }()
        let downloaded: Bool = { if case .ready = status { return true }; return false }()
        let updating = viewModel.updatingSelectedProfileGeodataKinds.contains(kind)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: kind == .geosite ? InterfaceSymbol.domainList : InterfaceSymbol.ipRanges)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(kind.displayName).fontWeight(.medium)
            }
            .help(kind == .geosite ? "Domain lists" : "IP ranges")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(kind.displayName + (kind == .geosite ? ", domain lists" : ", IP ranges"))
            VStack(alignment: .leading, spacing: 4) {
                datasetStatus(kind, lastUpdated: lastUpdated, downloaded: downloaded, updating: updating, lastError: lastError)
                if let lastError, !updating {
                    Text(lastError).foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
            .padding(.leading, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func datasetStatus(_ kind: GeodataKind, lastUpdated: Date?, downloaded: Bool, updating: Bool, lastError: String?) -> some View {
        if updating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Updating…").foregroundStyle(.secondary)
            }
        } else if lastError != nil {
            Text("Update failed").foregroundStyle(.red)
        } else if downloaded, let lastUpdated {
            Text("Updated \(Self.relativeFormatter.localizedString(for: lastUpdated, relativeTo: Date()))")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(downloaded ? "Downloaded" : (savedURLs[kind] == nil ? "Bundled" : "Waiting to download"))
                .foregroundStyle(.secondary)
        }
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
        guard let minutes else { return "Manual" }
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

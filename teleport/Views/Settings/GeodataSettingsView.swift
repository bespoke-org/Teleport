import SwiftUI

struct GeodataSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var configMode: ConfigMode = .preset
    @State private var selectedPresetID: String?
    @State private var geositeURLText: String = ""
    @State private var geoipURLText: String = ""

    private enum ConfigMode: Hashable {
        case preset
        case manual
    }

    private struct GeodataProviderPreset: Identifiable {
        let name: String
        let geositeURLString: String
        let geoipURLString: String
        var id: String { name }
    }

    private static let intervalOptions: [Int?] = [nil, 60, 360, 1440, 10080]

    private static let presets: [GeodataProviderPreset] = [
        GeodataProviderPreset(
            name: "V2Fly (official)",
            geositeURLString: "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat",
            geoipURLString: "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat"
        ),
        GeodataProviderPreset(
            name: "Loyalsoldier",
            geositeURLString: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat",
            geoipURLString: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
        ),
        GeodataProviderPreset(
            name: "Rulite",
            geositeURLString: "https://cdn.jsdelivr.net/gh/sendmiche/rulite@latest/geosite.dat",
            geoipURLString: "https://github.com/sendmiche/rulite/releases/latest/download/geoip.dat"
        ),
        GeodataProviderPreset(
            name: "RuNet Freedom (Russia)",
            geositeURLString: "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geosite.dat",
            geoipURLString: "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geoip.dat"
        )
    ]

    private var isUpdatingEither: Bool {
        !viewModel.updatingGeodataKinds.isEmpty
    }

    var body: some View {
        Form {
            Section {
                Text("Geosite and geoip data power `geosite:`/`geoip:` split-tunnel rules. Custom sources override Teleport's bundled defaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $configMode) {
                    Text("Preset").tag(ConfigMode.preset)
                    Text("Manual").tag(ConfigMode.manual)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            if configMode == .preset {
                presetSection
            } else {
                manualSection
            }

            Section {
                Picker(
                    selection: Binding(
                        get: { viewModel.geodataSettings.autoUpdateIntervalMinutes },
                        set: { viewModel.setGeodataAutoUpdateIntervalMinutes($0) }
                    )
                ) {
                    ForEach(Self.intervalOptions, id: \.self) { option in
                        Text(intervalLabel(option)).tag(option)
                    }
                } label: {
                    Text("Auto update")
                    Text("Applies to whichever source is configured above.")
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, -20)
        .navigationTitle("Geodata")
        .onAppear {
            geositeURLText = viewModel.geodataSettings.geositeURLString ?? ""
            geoipURLText = viewModel.geodataSettings.geoipURLString ?? ""

            if let matchedPreset = Self.presets.first(where: {
                $0.geositeURLString == viewModel.geodataSettings.geositeURLString
                    && $0.geoipURLString == viewModel.geodataSettings.geoipURLString
            }) {
                configMode = .preset
                selectedPresetID = matchedPreset.id
            } else if viewModel.geodataSettings.geositeURLString != nil || viewModel.geodataSettings.geoipURLString != nil {
                configMode = .manual
            } else {
                configMode = .preset
                selectedPresetID = nil
            }
        }
    }

    private var presetSection: some View {
        Section("Preset") {
            Picker(
                "Provider",
                selection: Binding(
                    get: { selectedPresetID },
                    set: { newValue in
                        if newValue != selectedPresetID {
                            viewModel.cancelGeodataUpdates()
                        }
                        selectedPresetID = newValue
                    }
                )
            ) {
                Text("Select a provider").tag(String?.none)
                ForEach(Self.presets) { preset in
                    Text(preset.name).tag(Optional(preset.id))
                }
            }

            HStack(spacing: 10) {
                Button("Update Now", action: applySelectedPreset)
                    .disabled(selectedPresetID == nil || isUpdatingEither)

                if isUpdatingEither {
                    ProgressView()
                        .controlSize(.small)

                    Button("Cancel") {
                        viewModel.cancelGeodataUpdates()
                    }
                }

                Spacer()
            }

            statusText(for: .geosite, label: "Geosite")
            statusText(for: .geoip, label: "Geoip")
        }
    }

    private var manualSection: some View {
        Group {
            Section("Geosite") {
                geodataRow(kind: .geosite, urlText: $geositeURLText, onCommit: { viewModel.setGeositeURL($0) })
            }

            Section("GeoIP") {
                geodataRow(kind: .geoip, urlText: $geoipURLText, onCommit: { viewModel.setGeoipURL($0) })
            }
        }
    }

    private func applySelectedPreset() {
        guard let selectedPresetID, let preset = Self.presets.first(where: { $0.id == selectedPresetID }) else { return }
        viewModel.setGeositeURL(preset.geositeURLString)
        viewModel.setGeoipURL(preset.geoipURLString)
        geositeURLText = preset.geositeURLString
        geoipURLText = preset.geoipURLString
        viewModel.updateGeodataNow(kind: .geosite)
        viewModel.updateGeodataNow(kind: .geoip)
    }

    @ViewBuilder
    private func geodataRow(kind: GeodataKind, urlText: Binding<String>, onCommit: @escaping (String?) -> Void) -> some View {
        TextField("https://…/\(kind.fileName)", text: urlText)
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospaced())
            .onSubmit { onCommit(urlText.wrappedValue) }
            .onChange(of: urlText.wrappedValue) { _, newValue in
                onCommit(newValue)
            }

        HStack(spacing: 10) {
            Button("Update Now") {
                onCommit(urlText.wrappedValue)
                viewModel.updateGeodataNow(kind: kind)
            }
            .disabled(urlText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.updatingGeodataKinds.contains(kind))

            if viewModel.updatingGeodataKinds.contains(kind) {
                ProgressView()
                    .controlSize(.small)

                Button("Cancel") {
                    viewModel.cancelGeodataUpdate(kind: kind)
                }
            }

            if viewModel.hasCustomGeodata(kind: kind) {
                Button("Reset to Bundled") {
                    urlText.wrappedValue = ""
                    viewModel.resetGeodataToBundled(kind: kind)
                }
                .disabled(viewModel.updatingGeodataKinds.contains(kind))
            }

            Spacer()
        }

        statusText(for: kind, label: nil)
    }

    @ViewBuilder
    private func statusText(for kind: GeodataKind, label: String?) -> some View {
        let settings = viewModel.geodataSettings
        let lastError = kind == .geosite ? settings.geositeLastError : settings.geoipLastError
        let lastUpdatedAt = kind == .geosite ? settings.geositeLastUpdatedAt : settings.geoipLastUpdatedAt
        let prefix = label.map { "\($0): " } ?? ""

        if let lastError {
            Text(prefix + lastError)
                .font(.caption)
                .foregroundStyle(.red)
        } else if let lastUpdatedAt {
            Text(prefix + "Updated \(Self.relativeFormatter.localizedString(for: lastUpdatedAt, relativeTo: Date()))")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if viewModel.hasCustomGeodata(kind: kind) {
            Text(prefix + "Using a previously downloaded file.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(prefix + "Using Teleport's bundled default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

import SwiftUI

/// The library opens documents for editing. Assignment lives in Portals.
struct RoutingProfileLibrary: View {
    @ObservedObject var viewModel: AppViewModel
    var onOpenProfile: () -> Void = {}
    let onNewProfile: () -> Void
    @State private var renamingID: UUID?
    @State private var name = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Profiles").font(.headline)
                .padding(.horizontal, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    group("Personal", profiles: viewModel.personalTunnelProfiles)
                    group("From subscriptions", profiles: viewModel.splitTunnelProfiles.filter { $0.subscriptionSourceID != nil })
                }
            }
            Divider()
            Button("New profile", systemImage: "plus", action: onNewProfile)
                .keyboardShortcut("n", modifiers: .command)
        }
        .padding(12)
    }

    @ViewBuilder
    private func group(_ title: String, profiles: [SplitTunnelProfile]) -> some View {
        if !profiles.isEmpty {
            Text(title).font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.top, 6)
            ForEach(profiles) { profile in
                if renamingID == profile.id { nameEditor }
                else { row(profile) }
            }
        }
    }

    private func row(_ profile: SplitTunnelProfile) -> some View {
        let selected = profile.id == viewModel.selectedSplitTunnelProfileID
        let sourceName = profile.subscriptionSourceID.map { viewModel.tunnelTargetName(.subscription($0)) }
        return HStack(spacing: 4) {
            Button {
                viewModel.openSplitTunnelProfile(id: profile.id)
                onOpenProfile()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name).fontWeight(selected ? .semibold : .regular)
                        .lineLimit(2)
                    if let sourceName {
                        Text(sourceName)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(viewModel.tunnelProfileUsageDescription(id: profile.id))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open profile \(profile.name)" + (sourceName.map { " from " + $0 } ?? ""))
            .accessibilityAddTraits(selected ? .isSelected : [])
            Menu {
                if profile.subscriptionSourceID == nil {
                    Button("Rename", systemImage: "pencil") {
                        renamingID = profile.id
                        name = profile.name
                        isNameFocused = true
                    }
                }
                Button(profile.subscriptionSourceID == nil ? "Duplicate" : "Create personal copy", systemImage: "doc.on.doc") {
                    viewModel.copySplitTunnelProfile(id: profile.id)
                    onOpenProfile()
                }
                if profile.subscriptionSourceID == nil {
                    Button("Delete profile", systemImage: "trash", role: .destructive) {
                        viewModel.removeSplitTunnelProfile(id: profile.id)
                    }
                    .disabled(viewModel.personalTunnelProfiles.count <= 1)
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 20, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for profile \(profile.name)")
            .padding(.trailing, 6)
        }
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private var nameEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Profile name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(saveName)
                .onExitCommand(perform: cancelName)
            HStack {
                Button("Cancel", action: cancelName)
                Spacer()
                Button("Rename", action: saveName)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(8)
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let id = renamingID {
            viewModel.renameSplitTunnelProfile(id: id, name: trimmed)
        }
        cancelName()
    }

    private func cancelName() {
        renamingID = nil
        name = ""
    }
}

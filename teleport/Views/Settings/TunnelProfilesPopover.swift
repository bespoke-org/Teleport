import SwiftUI

struct TunnelProfilesPopover: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: AppViewModel
    @State private var editingProfileID: UUID?
    @State private var isCreatingProfile = false
    @State private var profileName = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Personal profiles")
                    .font(.headline)
                Spacer()
                Button { finishNameEdit(); dismiss() } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close profiles")
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(viewModel.personalTunnelProfiles) { profile in
                            profileRow(profile)
                        }
                        if isCreatingProfile { newProfileRow.id("new-profile") }
                    }
                }
                .onChange(of: isCreatingProfile) { _, creating in
                    if creating { proxy.scrollTo("new-profile", anchor: .bottom) }
                }
            }
            .frame(height: min(CGFloat(viewModel.personalTunnelProfiles.count + (isCreatingProfile ? 1 : 0)) * 74, 296))

            HStack {
                Button("New profile", systemImage: "plus") {
                    finishNameEdit()
                    isCreatingProfile = true
                    profileName = ""
                    isNameFocused = true
                }
                .disabled(isCreatingProfile)
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 380)
        .onDisappear { finishNameEdit() }
    }

    private func profileRow(_ profile: SplitTunnelProfile) -> some View {
        let isSelected = profile.id == viewModel.selectedSplitTunnelProfileID
        let users = viewModel.tunnelProfileUsers(id: profile.id)
        return HStack(spacing: 12) {
            Button { select(profile) } label: {
                profileIcon(isSelected: isSelected)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use \(profile.name)")
            VStack(alignment: .leading, spacing: 4) {
                if editingProfileID == profile.id {
                    nameField
                } else {
                    Button {
                        finishNameEdit()
                        editingProfileID = profile.id
                        profileName = profile.name
                        isNameFocused = true
                    } label: {
                        Text(profile.name).font(.body.weight(.medium))
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Click to rename")
                    .accessibilityLabel("Rename \(profile.name)")
                }
                Text("\(profile.rules.count) \(profile.rules.count == 1 ? "rule" : "rules") · \(users.count) \(users.count == 1 ? "tunnel" : "tunnels")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { select(profile) } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use \(profile.name)")
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            Menu {
                Button("Delete profile", systemImage: "trash", role: .destructive) {
                    if editingProfileID == profile.id { cancelNameEdit() }
                    viewModel.removeSplitTunnelProfile(id: profile.id)
                }
                .disabled(viewModel.personalTunnelProfiles.count <= 1)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Actions for \(profile.name)")
        }
        .padding(12)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private var newProfileRow: some View {
        HStack(spacing: 12) {
            profileIcon(isSelected: false)
            nameField
            Button { finishNameEdit() } label: {
                Image(systemName: "checkmark").frame(width: 24, height: 28)
            }
            .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Create profile")
            Button { cancelNameEdit() } label: {
                Image(systemName: "xmark").frame(width: 24, height: 28)
            }
            .accessibilityLabel("Cancel new profile")
        }
        .buttonStyle(.plain)
        .padding(12)
        .frame(minHeight: 68)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func profileIcon(isSelected: Bool) -> some View {
        Image(systemName: InterfaceSymbol.tunnelProfile)
            .font(.system(size: 17))
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: 34, height: 34)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var nameField: some View {
        TextField("Profile name", text: $profileName)
            .textFieldStyle(.roundedBorder)
            .focused($isNameFocused)
            .onSubmit { finishNameEdit() }
            .onExitCommand { cancelNameEdit() }
    }

    private func select(_ profile: SplitTunnelProfile) {
        finishNameEdit()
        viewModel.selectSplitTunnelProfile(id: profile.id)
    }

    private func finishNameEdit() {
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            if let id = editingProfileID {
                viewModel.renameSplitTunnelProfile(id: id, name: name)
            } else if isCreatingProfile {
                viewModel.addSplitTunnelProfile(name: name)
            }
        }
        cancelNameEdit()
    }

    private func cancelNameEdit() {
        editingProfileID = nil
        isCreatingProfile = false
        profileName = ""
        isNameFocused = false
    }
}

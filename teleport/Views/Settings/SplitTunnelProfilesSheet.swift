import SwiftUI

struct SplitTunnelProfilesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: AppViewModel
    @State private var editedNamesByID: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Manage profiles")
                .font(.headline)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(viewModel.splitTunnelProfiles) { profile in
                        profileRow(profile)
                            .frame(height: 28)
                    }
                }
                .padding(2)
            }
            .frame(height: min(CGFloat(viewModel.splitTunnelProfiles.count) * 36, 252))

            HStack {
                Button("Add profile", systemImage: "plus") {
                    let newID = viewModel.addSplitTunnelProfile(name: "New profile")
                    editedNamesByID[newID] = "New profile"
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func profileRow(_ profile: SplitTunnelProfile) -> some View {
        HStack(spacing: 10) {
            Button {
                viewModel.selectSplitTunnelProfile(id: profile.id)
            } label: {
                Image(systemName: profile.id == viewModel.selectedSplitTunnelProfileID ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(profile.id == viewModel.selectedSplitTunnelProfileID ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use \(profile.name)")
            .accessibilityValue(profile.id == viewModel.selectedSplitTunnelProfileID ? "Selected" : "Not selected")

            TextField(
                "Profile name",
                text: Binding(
                    get: { editedNamesByID[profile.id] ?? profile.name },
                    set: { editedNamesByID[profile.id] = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                commitRename(profile)
            }
            .onChange(of: editedNamesByID[profile.id]) { _, _ in
                commitRename(profile)
            }

            Text("\(profile.rules.count) rule\(profile.rules.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()

            Button(role: .destructive) {
                viewModel.removeSplitTunnelProfile(id: profile.id)
                editedNamesByID[profile.id] = nil
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(profile.name)")
            .disabled(viewModel.splitTunnelProfiles.count <= 1)
        }
    }

    private func commitRename(_ profile: SplitTunnelProfile) {
        guard let editedName = editedNamesByID[profile.id] else { return }
        viewModel.renameSplitTunnelProfile(id: profile.id, name: editedName)
    }
}

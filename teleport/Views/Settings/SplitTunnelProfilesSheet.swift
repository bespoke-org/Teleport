import SwiftUI

struct SplitTunnelProfilesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: AppViewModel
    @State private var editedNamesByID: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Split-tunnel profiles")
                .font(.headline)

            Text("Each profile keeps its own rule list. Only one profile is active at a time.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(viewModel.splitTunnelProfiles) { profile in
                    profileRow(profile)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 160, maxHeight: 260)

            Button("Add Profile", systemImage: "plus") {
                let newID = viewModel.addSplitTunnelProfile(name: "New Profile")
                editedNamesByID[newID] = "New Profile"
            }

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func profileRow(_ profile: SplitTunnelProfile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: profile.id == viewModel.selectedSplitTunnelProfileID ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(profile.id == viewModel.selectedSplitTunnelProfileID ? Color.accentColor : Color.secondary)
                .onTapGesture {
                    viewModel.selectSplitTunnelProfile(id: profile.id)
                }

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

            Button(role: .destructive) {
                viewModel.removeSplitTunnelProfile(id: profile.id)
                editedNamesByID[profile.id] = nil
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.splitTunnelProfiles.count <= 1)
        }
    }

    private func commitRename(_ profile: SplitTunnelProfile) {
        guard let editedName = editedNamesByID[profile.id] else { return }
        viewModel.renameSplitTunnelProfile(id: profile.id, name: editedName)
    }
}

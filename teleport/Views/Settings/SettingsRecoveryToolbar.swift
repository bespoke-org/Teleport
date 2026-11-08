import SwiftUI

struct SettingsRecoveryToolbar: ToolbarContent {
    @ObservedObject var viewModel: AppViewModel

    var body: some ToolbarContent {
        if viewModel.canAllowDirectTraffic {
            ToolbarItem(id: "settings.recovery", placement: .primaryAction) {
                Button("Allow direct traffic", action: viewModel.allowDirectTraffic)
                    .help("Release leak guard and use the regular internet connection")
            }
        }
    }
}

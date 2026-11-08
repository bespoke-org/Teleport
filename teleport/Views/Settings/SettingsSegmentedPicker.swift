import AppKit
import SwiftUI

/// Equal-width native segments for the short, top-level settings choices.
/// SwiftUI's segmented Picker otherwise sizes the visible control to its labels,
/// even when the Picker's outer frame is fixed.
struct SettingsSegmentedPicker<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let choices: [SettingsChoice<Value>]
    // A brief data refresh can block input without flashing the disabled style.
    var acceptsSelection = true
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.segmentStyle = .texturedRounded
        control.controlSize = .regular
        control.font = .systemFont(ofSize: 13)
        if #available(macOS 26.0, *) {
            control.borderShape = .capsule
        }
        if #available(macOS 27.0, *), control.responds(to: NSSelectorFromString("setRole:")) {
            // NSSegmentedControl.Role.tabs keeps the neutral glass selection.
            // Use KVC so builds with the macOS 26 SDK also adopt it on macOS 27.
            control.setValue(1, forKey: "role")
        }
        control.target = context.coordinator
        control.action = #selector(SettingsSegmentedPickerCoordinator.select(_:))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        let selectedIndex = choices.firstIndex { $0.value == selection } ?? -1
        context.coordinator.selectIndex = { [weak control] index in
            guard isEnabled, acceptsSelection, choices.indices.contains(index) else {
                control?.selectedSegment = selectedIndex
                return
            }
            let value = choices[index].value
            if value != selection { selection = value }
        }
        control.segmentCount = choices.count
        for (index, choice) in choices.enumerated() {
            control.setLabel(choice.title, forSegment: index)
            control.setWidth(216 / CGFloat(max(choices.count, 1)), forSegment: index)
        }
        control.selectedSegment = selectedIndex
        control.isEnabled = isEnabled
        control.alphaValue = isEnabled ? 1 : 0.5
        control.setAccessibilityLabel(title)
        control.setAccessibilityEnabled(isEnabled && acceptsSelection)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: 220, height: 28)
    }

    func makeCoordinator() -> SettingsSegmentedPickerCoordinator { SettingsSegmentedPickerCoordinator() }
}

final class SettingsSegmentedPickerCoordinator: NSObject {
    var selectIndex: (Int) -> Void = { _ in }

    @objc func select(_ sender: NSSegmentedControl) {
        selectIndex(sender.selectedSegment)
    }
}

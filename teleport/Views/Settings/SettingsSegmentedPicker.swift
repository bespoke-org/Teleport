import AppKit
import SwiftUI

/// Equal-width native segments for the short, top-level settings choices.
/// SwiftUI's segmented Picker otherwise sizes the visible control to its labels,
/// even when the Picker's outer frame is fixed.
struct SettingsSegmentedPicker<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let choices: [SettingsChoice<Value>]
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.controlSize = .regular
        control.font = .systemFont(ofSize: 13)
        control.target = context.coordinator
        control.action = #selector(SettingsSegmentedPickerCoordinator.select(_:))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selectIndex = { index in
            guard choices.indices.contains(index) else { return }
            let value = choices[index].value
            if value != selection { selection = value }
        }
        control.segmentCount = choices.count
        for (index, choice) in choices.enumerated() {
            control.setLabel(choice.title, forSegment: index)
            control.setWidth(216 / CGFloat(max(choices.count, 1)), forSegment: index)
        }
        control.selectedSegment = choices.firstIndex { $0.value == selection } ?? -1
        control.isEnabled = isEnabled
        control.setAccessibilityLabel(title)
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

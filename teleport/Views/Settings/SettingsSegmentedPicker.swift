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

    func makeNSView(context: Context) -> SettingsSegmentedControl {
        let control = SettingsSegmentedControl()
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

    func updateNSView(_ control: SettingsSegmentedControl, context: Context) {
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
            // Reapplying an unchanged label during a SwiftUI update cancels
            // AppKit's glass selection animation.
            if control.label(forSegment: index) != choice.title {
                control.setLabel(choice.title, forSegment: index)
            }
            control.setWidth(216 / CGFloat(max(choices.count, 1)), forSegment: index)
        }
        control.selectedSegment = selectedIndex
        control.isEnabled = isEnabled
        control.alphaValue = isEnabled ? 1 : 0.5
        control.acceptsSelection = acceptsSelection
        control.setAccessibilityLabel(title)
        control.setAccessibilityEnabled(isEnabled && acceptsSelection)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SettingsSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: 220, height: 28)
    }

    func makeCoordinator() -> SettingsSegmentedPickerCoordinator { SettingsSegmentedPickerCoordinator() }
}

final class SettingsSegmentedControl: NSSegmentedControl {
    var acceptsSelection = true

    // Changing SwiftUI's allowsHitTesting while the glass pill is moving
    // cancels the animation. Gate events without changing its presentation.
    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsSelection ? super.hitTest(point) : nil
    }

    override func keyDown(with event: NSEvent) {
        guard acceptsSelection else { return }
        super.keyDown(with: event)
    }
}

final class SettingsSegmentedPickerCoordinator: NSObject {
    var selectIndex: (Int) -> Void = { _ in }

    @objc func select(_ sender: NSSegmentedControl) {
        selectIndex(sender.selectedSegment)
    }
}

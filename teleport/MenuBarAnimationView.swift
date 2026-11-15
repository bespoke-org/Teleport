import AppKit
import QuartzCore

/// The compositor advances the masks without waking the app or changing button.image.
@MainActor
final class MenuBarAnimationView: NSView {
    static let animationKey = "portalFrames"
    let iconLayer = CALayer()
    let maskLayer = CALayer()
    private weak var button: NSStatusBarButton?

    init?(button: NSStatusBarButton, phase: ConnectionPhase, proxyPhase: ProxyPhase) {
        self.button = button
        super.init(frame: button.bounds)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        setAccessibilityElement(false)
        layer?.addSublayer(iconLayer)
        iconLayer.mask = maskLayer
        maskLayer.contentsScale = 2

        let frames = (0..<MenuBarIconImageFactory.animationFrameCount).compactMap {
            let image = MenuBarIconImageFactory.image(for: phase, proxyPhase: proxyPhase,
                                                      frame: $0, isAnimated: true)
            return (image.representations.last as? NSBitmapImageRep)?.cgImage
        }
        guard frames.count == MenuBarIconImageFactory.animationFrameCount else { return nil }
        maskLayer.contents = frames.first
        let animation = CAKeyframeAnimation(keyPath: "contents")
        // Include the endpoint explicitly so every frame lasts exactly 1 / FPS.
        animation.values = frames + Array(frames.prefix(1))
        animation.keyTimes = (0...frames.count).map { NSNumber(value: Double($0) / Double(frames.count)) }
        animation.duration = Double(frames.count) / MenuBarIconImageFactory.animationFPS
        animation.calculationMode = .discrete
        animation.repeatCount = .infinity
        maskLayer.add(animation, forKey: Self.animationKey)

        layout()
        updateTint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // All clicks, including control/right clicks, continue to reach the status button.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = MenuBarIconImageFactory.size
        iconLayer.frame = NSRect(x: (bounds.width - size.width) / 2,
                                y: (bounds.height - size.height) / 2,
                                width: size.width, height: size.height)
        maskLayer.frame = iconLayer.bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }

    override func viewWillDraw() {
        // NSCell.highlight does not emit KVO changes. Read the native button state
        // when AppKit redraws it (presses, menu tracking and popover highlighting).
        updateTint()
        super.viewWillDraw()
    }

    private func updateTint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = (button?.isHighlighted == true
                ? NSColor.selectedMenuItemTextColor : NSColor.labelColor).cgColor
            guard iconLayer.backgroundColor != color else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            iconLayer.backgroundColor = color
            CATransaction.commit()
        }
    }

    func stop() {
        maskLayer.removeAllAnimations()
    }
}

import AppKit
import SwiftUI

struct LogTextViewer: NSViewRepresentable {
    let text: String
    let source: SettingsLogFile
    let findID: Int
    let jumpID: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        let coordinator = context.coordinator
        let sourceChanged = coordinator.source != source
        let oldText = textView.string
        let visibleRect = scrollView.contentView.bounds
        let wasAtBottom = visibleRect.maxY >= textView.bounds.maxY - 4
        let selection = textView.selectedRange()
        let shouldFollow = !source.isConfiguration && (sourceChanged || oldText.isEmpty ||
            (wasAtBottom && selection.length == 0 && !scrollView.isFindBarVisible))

        // Once a log reaches the read limit, its oldest bytes fall out of the
        // snapshot. Anchor the viewport to its first visible line when possible.
        let anchor = !sourceChanged && !shouldFollow && !text.hasPrefix(oldText)
            ? ReadingAnchor.capture(in: textView, visibleRect: visibleRect) : nil

        if sourceChanged || oldText != text {
            coordinator.source = source
            if sourceChanged { scrollView.isFindBarVisible = false }
            // Preserve the selection and scroll position when new output is appended.
            // Replacing the entire string would reset both on every live refresh.
            if !sourceChanged, text.hasPrefix(oldText) {
                textView.textStorage?.append(NSAttributedString(string: String(text.dropFirst(oldText.count)), attributes: textView.typingAttributes))
            } else {
                textView.string = text
            }
            textView.minSize = NSSize(width: scrollView.contentSize.width, height: scrollView.contentSize.height)
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            textView.sizeToFit()
            if shouldFollow {
                textView.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0))
            } else if sourceChanged {
                textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            } else {
                let length = (text as NSString).length
                let restored = anchor?.restore(in: textView)
                let shiftedLocation = selection.location + (restored?.characterDelta ?? 0)
                if shiftedLocation >= 0, shiftedLocation + selection.length <= length {
                    textView.setSelectedRange(NSRange(location: shiftedLocation, length: selection.length))
                }
                scrollView.contentView.scroll(to: NSPoint(x: visibleRect.minX, y: restored?.y ?? visibleRect.minY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        if coordinator.findID != findID {
            coordinator.findID = findID
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
                let item = NSMenuItem()
                item.tag = NSTextFinder.Action.showFindInterface.rawValue
                textView.performFindPanelAction(item)
            }
        }
        if coordinator.jumpID != jumpID {
            coordinator.jumpID = jumpID
            scrollView.isFindBarVisible = false
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }

    private struct ReadingAnchor {
        let line: String
        let characterIndex: Int
        let offsetY: CGFloat

        static func capture(in view: NSTextView, visibleRect: NSRect) -> Self? {
            guard let layout = view.layoutManager, let container = view.textContainer,
                  layout.numberOfGlyphs > 0 else { return nil }
            let point = NSPoint(x: 0, y: max(0, visibleRect.minY - view.textContainerOrigin.y))
            let glyph = layout.glyphIndex(for: point, in: container)
            let index = layout.characterIndexForGlyph(at: min(glyph, layout.numberOfGlyphs - 1))
            let content = view.string as NSString
            let range = content.lineRange(for: NSRange(location: index, length: 0))
            guard range.length > 1 else { return nil }
            let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let y = layout.boundingRect(forGlyphRange: glyphRange, in: container).minY + view.textContainerOrigin.y
            return Self(line: content.substring(with: range), characterIndex: range.location, offsetY: visibleRect.minY - y)
        }

        func restore(in view: NSTextView) -> (y: CGFloat, characterDelta: Int)? {
            guard let layout = view.layoutManager, let container = view.textContainer else { return nil }
            let range = (view.string as NSString).range(of: line, options: .literal)
            guard range.location != NSNotFound else { return nil }
            let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let y = layout.boundingRect(forGlyphRange: glyphRange, in: container).minY + view.textContainerOrigin.y
            return (y + offsetY, range.location - characterIndex)
        }
    }

    final class Coordinator {
        weak var textView: NSTextView?
        var source: SettingsLogFile?
        var findID = 0
        var jumpID = 0
    }
}

import SwiftUI
import AppKit

/// A bounded log uses AppKit's text layout and selection rather than rebuilding
/// SwiftUI text geometry for every arriving chunk.
struct RunLogView: NSViewRepresentable {
    let output: String
    let followsOutput: Bool
    let sessionID: UUID
    var accessibilityLabel = "运行日志 / Run log"

    final class Coordinator {
        var sessionID: UUID?
        var followed = true
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let view = NSTextView(frame: scroll.contentView.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 10, height: 8)
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textColor = .textColor
        view.backgroundColor = .textBackgroundColor
        view.setAccessibilityLabel(accessibilityLabel)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let changedSession = context.coordinator.sessionID != sessionID
        let changedText = view.string != output
        let shouldFollow = followsOutput && (changedText || changedSession || !context.coordinator.followed)
        let selection = view.selectedRange()
        let origin = scroll.contentView.bounds.origin
        if changedText {
            view.string = output
            let count = (output as NSString).length
            if !changedSession {
                view.setSelectedRange(NSRange(location: min(selection.location, count), length: min(selection.length, max(0, count - selection.location))))
            }
        }
        if shouldFollow && (selection.length == 0 || changedSession) {
            view.scrollToEndOfDocument(nil)
        } else if changedText && !changedSession {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        context.coordinator.sessionID = sessionID
        context.coordinator.followed = followsOutput
    }
}

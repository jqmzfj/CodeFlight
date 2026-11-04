import SwiftUI
import AppKit

@MainActor
enum RunLogHighlighter {
    private static let infoColor = NSColor(red: 0.30, green: 0.65, blue: 1.0, alpha: 1.0) // cyan-blue
    private static let warnColor = NSColor(red: 0.95, green: 0.72, blue: 0.20, alpha: 1.0) // golden yellow
    private static let errorColor = NSColor(red: 0.96, green: 0.35, blue: 0.35, alpha: 1.0) // soft red
    private static let successColor = NSColor(red: 0.28, green: 0.82, blue: 0.45, alpha: 1.0) // spring green
    private static let dimColor = NSColor.secondaryLabelColor
    private static let regularFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)

    static func highlight(_ text: String) -> NSAttributedString {
        guard !text.isEmpty else { return NSAttributedString() }
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: regularFont,
                .foregroundColor: NSColor.textColor
            ]
        )
        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        nsString.enumerateSubstrings(in: fullRange, options: .byLines) { lineOpt, range, _, _ in
            guard let line = lineOpt else { return }
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 1. Spring Boot ASCII Banner
            if line.contains(":: Spring Boot ::") || line.contains("/\\\\ / ___'_ __ _ _(_)_ __") || line.contains("( ( )\\___ | '_ | '_|") || line.contains("=========|_|==============") {
                attributed.addAttribute(.foregroundColor, value: successColor, range: range)
                attributed.addAttribute(.font, value: boldFont, range: range)
                return
            }

            // 2. Build Success
            if line.contains("BUILD SUCCESS") || (line.contains("SUCCESS") && line.contains("[INFO]")) {
                attributed.addAttribute(.foregroundColor, value: successColor, range: range)
                attributed.addAttribute(.font, value: boldFont, range: range)
                return
            }

            // 3. Build Failure
            if line.contains("BUILD FAILURE") || (line.contains("FAILURE") && line.contains("[INFO]")) {
                attributed.addAttribute(.foregroundColor, value: errorColor, range: range)
                attributed.addAttribute(.font, value: boldFont, range: range)
                return
            }

            // 4. Error lines: [ERROR] or ERROR
            if trimmed.hasPrefix("[ERROR]") || trimmed.hasPrefix("ERROR") || line.contains(" ERROR ") || line.contains(" FATAL ") {
                attributed.addAttribute(.foregroundColor, value: errorColor, range: range)
                return
            }

            // 5. Warning lines: [WARNING] or WARN
            if trimmed.hasPrefix("[WARNING]") || trimmed.hasPrefix("WARNING") || line.contains(" WARN ") {
                attributed.addAttribute(.foregroundColor, value: warnColor, range: range)
                return
            }

            // 6. Info tag highlight: [INFO] or INFO
            if trimmed.hasPrefix("[INFO]") {
                if let tagRange = line.range(of: "[INFO]") {
                    let nsTagRange = NSRange(tagRange, in: line)
                    attributed.addAttribute(.foregroundColor, value: infoColor, range: NSRange(location: range.location + nsTagRange.location, length: nsTagRange.length))
                    attributed.addAttribute(.font, value: boldFont, range: NSRange(location: range.location + nsTagRange.location, length: nsTagRange.length))
                }
            } else if line.contains(" INFO ") {
                if let tagRange = line.range(of: " INFO ") {
                    let nsTagRange = NSRange(tagRange, in: line)
                    attributed.addAttribute(.foregroundColor, value: infoColor, range: NSRange(location: range.location + nsTagRange.location, length: nsTagRange.length))
                    attributed.addAttribute(.font, value: boldFont, range: NSRange(location: range.location + nsTagRange.location, length: nsTagRange.length))
                }
            }

            // 7. Stack trace Exception or Caused by
            if line.contains("Exception") || line.contains("Caused by:") {
                attributed.addAttribute(.foregroundColor, value: errorColor, range: range)
            } else if trimmed.hasPrefix("at ") && line.contains("(") && line.contains(")") {
                attributed.addAttribute(.foregroundColor, value: dimColor, range: range)
            }
        }

        return attributed
    }
}

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
        view.isRichText = true
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
            let attr = RunLogHighlighter.highlight(output)
            view.textStorage?.setAttributedString(attr)
            let count = attr.length
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

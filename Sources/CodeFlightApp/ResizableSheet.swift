import SwiftUI
import AppKit

/// SwiftUI's flexible content frame does not make a macOS sheet resizable.
/// Configure only the window hosting this sheet, preserving its native style.
struct SheetWindowSizing: NSViewRepresentable {
    let minimum: NSSize
    let language: AppLanguage
    func makeNSView(context: Context) -> SizingView { SizingView(minimum: minimum) }
    func updateNSView(_ view: SizingView, context: Context) {
        view.minimum = minimum
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityLabel(Copy.t("调整窗口大小", "Resize window", language: language))
        view.toolTip = Copy.t("拖动调整窗口大小，或聚焦后使用方向键；Shift 可加速。", "Drag to resize, or focus and use arrow keys. Hold Shift for larger steps.", language: language)
        view.setAccessibilityHelp(view.toolTip)
        view.scheduleSizing()
    }

    final class SizingView: NSView {
        var minimum: NSSize
        private var start: (point: NSPoint, frame: NSRect)?
        private weak var keyboardWindow: NSWindow?
        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { window?.isSheet == true && !isHiddenOrHasHiddenAncestor }
        init(minimum: NSSize) { self.minimum = minimum; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: nil)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(windowResized(_:)), name: NSWindow.didResizeNotification, object: window)
            }
            scheduleSizing()
        }
        deinit { NotificationCenter.default.removeObserver(self) }

        // Read the live content size: native edge dragging bypasses resize().
        // Do not retain a value that becomes stale or report title-bar height.
        override func accessibilityValue() -> Any? {
            guard let window, window.isSheet else { return nil }
            let size = window.contentRect(forFrameRect: window.frame).size
            return "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
        }
        override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
        override func setAccessibilityFocused(_ focused: Bool) {
            if focused { _ = accessibilityPerformPress() }
        }
        override func accessibilityPerformPress() -> Bool {
            guard let window, window.isSheet else { return false }
            return window.makeFirstResponder(self)
        }
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            needsDisplay = true
            return accepted
        }
        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            needsDisplay = true
            return accepted
        }

        /// SwiftUI can replace a sheet's native constraints during layout.
        /// Cover native edge resizing as well as our explicit resize grip.
        @objc private func windowResized(_ notification: Notification) {
            guard let window, window.isSheet else { return }
            let frame = window.frame
            let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: minimum)).size
            guard frame.width < size.width - 0.5 || frame.height < size.height - 0.5 else { return }
            let height = max(frame.height, size.height)
            window.setFrame(NSRect(x: frame.minX, y: frame.maxY - height,
                                   width: max(frame.width, size.width), height: height), display: true)
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.tertiaryLabelColor.setStroke()
            let path = NSBezierPath()
            for inset: CGFloat in [5, 9, 13] {
                path.move(to: NSPoint(x: bounds.maxX - inset, y: 3))
                path.line(to: NSPoint(x: bounds.maxX - 3, y: inset))
            }
            path.lineWidth = 1
            path.stroke()
            if window?.firstResponder === self {
                NSGraphicsContext.saveGraphicsState()
                NSFocusRingPlacement.only.set()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 3, yRadius: 3).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        override func mouseDown(with event: NSEvent) {
            guard let window, window.isSheet else { return }
            window.makeFirstResponder(self)
            start = (window.convertPoint(toScreen: event.locationInWindow), window.frame)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start, let window else { return }
            let point = window.convertPoint(toScreen: event.locationInWindow)
            resize(from: start.frame, delta: NSSize(width: point.x - start.point.x, height: start.point.y - point.y))
        }
        override func mouseUp(with event: NSEvent) { start = nil }
        override func keyDown(with event: NSEvent) {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 24 : 4
            let delta: NSSize
            switch event.keyCode {
            case 48:
                if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
                else { window?.selectNextKeyView(self) }
                // With macOS keyboard navigation off, a SwiftUI sheet may
                // expose no other native key view. Release focus instead of
                // cycling back to this grip indefinitely.
                if window?.firstResponder === self { window?.makeFirstResponder(nil) }
                return
            case 123: delta = NSSize(width: -step, height: 0)
            case 124: delta = NSSize(width: step, height: 0)
            case 125: delta = NSSize(width: 0, height: step)
            case 126: delta = NSSize(width: 0, height: -step)
            default: super.keyDown(with: event); return
            }
            if let window { resize(from: window.frame, delta: delta) }
        }
        override func accessibilityPerformIncrement() -> Bool { adjust(24) }
        override func accessibilityPerformDecrement() -> Bool { adjust(-24) }
        private func adjust(_ amount: CGFloat) -> Bool {
            guard let window, window.isSheet else { return false }
            resize(from: window.frame, delta: NSSize(width: amount, height: amount))
            return true
        }
        private func resize(from frame: NSRect, delta: NSSize) {
            guard let window, window.isSheet else { return }
            let minimumFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: minimum)).size
            let screen = window.screen?.visibleFrame ?? frame.insetBy(dx: -1000, dy: -1000)
            let width = min(max(minimumFrame.width, screen.maxX - frame.minX), max(minimumFrame.width, frame.width + delta.width))
            let height = min(max(minimumFrame.height, frame.maxY - screen.minY), max(minimumFrame.height, frame.height + delta.height))
            window.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: width, height: height), display: true)
        }
        func scheduleSizing() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, window.isSheet else { return }
                if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
                if window.contentMinSize != self.minimum { window.contentMinSize = self.minimum }
                if self.keyboardWindow !== window {
                    window.recalculateKeyViewLoop()
                    self.keyboardWindow = window
                }
            }
        }
    }
}

extension View {
    func resizableSheet(minimumWidth: CGFloat, minimumHeight: CGFloat, language: AppLanguage) -> some View {
        overlay(alignment: .bottomTrailing) {
            SheetWindowSizing(minimum: NSSize(width: minimumWidth, height: minimumHeight), language: language)
                .frame(width: 16, height: 16).padding(2)
        }
    }
}

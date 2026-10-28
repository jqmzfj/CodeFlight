import SwiftUI
import AppKit

enum GitDiffSide: Hashable { case old, new }

/// Only two widths/positions are retained; glyphs and attributed lines are not cached.
struct GitDiffHorizontalState {
    static let gutter: CGFloat = 50
    private(set) var widths: [GitDiffSide: CGFloat] = [:]
    private var positions: [GitDiffSide: CGFloat] = [:]

    mutating func record(_ measured: [GitDiffSide: CGFloat]) {
        for (side, width) in measured where width.isFinite && width >= 0 {
            widths[side] = max(widths[side] ?? 0, width)
        }
    }
    func maximum(_ side: GitDiffSide, column: CGFloat) -> CGFloat {
        max(0, (widths[side] ?? 0) + 8 - max(0, column - Self.gutter))
    }
    func offset(_ side: GitDiffSide, column: CGFloat) -> CGFloat {
        min(maximum(side, column: column), max(0, positions[side] ?? 0))
    }
    mutating func set(_ side: GitDiffSide, offset: CGFloat, column: CGFloat) {
        positions[side] = offset.isFinite ? min(maximum(side, column: column), max(0, offset)) : 0
    }
    mutating func fit(old: CGFloat, new: CGFloat) {
        set(.old, offset: offset(.old, column: old), column: old)
        set(.new, offset: offset(.new, column: new), column: new)
    }

    /// Horizontal gestures belong to a column. Ordinary vertical scrolling
    /// must continue to the shared native vertical scroll view unchanged.
    static func horizontalDelta(x: CGFloat, y: CGFloat, shift: Bool) -> CGFloat? {
        guard x.isFinite, y.isFinite else { return nil }
        if abs(x) > abs(y), x != 0 { return -x }
        if shift, x == 0, y != 0 { return -y }
        return nil
    }
}

struct GitDiffWidthPreference: PreferenceKey {
    static let defaultValue: [GitDiffSide: CGFloat] = [:]
    static func reduce(value: inout [GitDiffSide: CGFloat], nextValue: () -> [GitDiffSide: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: max)
    }
}

struct GitDiffHorizontalScroller: NSViewRepresentable {
    @Binding var offset: CGFloat
    let maximum: CGFloat
    let viewport: CGFloat
    let label: String

    func makeNSView(context: Context) -> GitDiffScroller {
        let view = GitDiffScroller(frame: NSRect(x: 0, y: 0, width: 100, height: 14))
        view.scrollerStyle = .legacy
        view.controlSize = .small
        view.target = view
        view.action = #selector(GitDiffScroller.changed(_:))
        return view
    }
    func updateNSView(_ view: GitDiffScroller, context: Context) {
        view.maximum = maximum
        view.viewport = viewport
        view.position = min(maximum, max(0, offset))
        view.change = { offset = $0 }
        view.isEnabled = maximum > 0
        view.knobProportion = viewport / max(1, viewport + maximum)
        view.doubleValue = maximum > 0 ? Double(view.position / maximum) : 0
        view.setAccessibilityLabel(label)
        view.toolTip = label
    }
}

final class GitDiffScroller: NSScroller {
    var maximum: CGFloat = 0
    var viewport: CGFloat = 0
    var position: CGFloat = 0
    var change: ((CGFloat) -> Void)?
    override var acceptsFirstResponder: Bool { isEnabled }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    @objc func changed(_ sender: NSScroller) {
        switch hitPart {
        case .decrementLine: adjust(-24)
        case .incrementLine: adjust(24)
        case .decrementPage: adjust(-max(24, viewport * 0.9))
        case .incrementPage: adjust(max(24, viewport * 0.9))
        default: update(CGFloat(doubleValue) * maximum)
        }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: adjust(event.modifierFlags.contains(.shift) ? -120 : -24)
        case 124: adjust(event.modifierFlags.contains(.shift) ? 120 : 24)
        case 115: update(0)
        case 119: update(maximum)
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityPerformIncrement() -> Bool { guard isEnabled else { return false }; adjust(24); return true }
    override func accessibilityPerformDecrement() -> Bool { guard isEnabled else { return false }; adjust(-24); return true }
    private func adjust(_ amount: CGFloat) { update(position + amount) }
    private func update(_ value: CGFloat) {
        position = min(maximum, max(0, value))
        doubleValue = maximum > 0 ? Double(position / maximum) : 0
        change?(position)
    }
}

/// This non-interactive background observes only this view's scroll gestures.
/// It leaves hit testing and text selection to the code, hunk buttons and divider.
struct GitDiffHorizontalGestures: NSViewRepresentable {
    let leftWidth: CGFloat
    let change: (GitDiffSide, CGFloat) -> Bool
    func makeNSView(context: Context) -> GitDiffGestureView { GitDiffGestureView() }
    func updateNSView(_ view: GitDiffGestureView, context: Context) {
        view.leftWidth = leftWidth
        view.change = change
    }
    static func dismantleNSView(_ view: GitDiffGestureView, coordinator: ()) { view.stop() }
}

final class GitDiffGestureView: NSView {
    var leftWidth: CGFloat = 0
    var change: ((GitDiffSide, CGFloat) -> Bool)?
    private var monitor: Any?
    var isMonitoring: Bool { monitor != nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window, !self.isHiddenOrHasHiddenAncestor else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.visibleRect.contains(point), let delta = GitDiffHorizontalState.horizontalDelta(
                x: event.scrollingDeltaX, y: event.scrollingDeltaY, shift: event.modifierFlags.contains(.shift)) else { return event }
            let side: GitDiffSide = point.x < self.leftWidth ? .old : .new
            return self.change?(side, delta * (event.hasPreciseScrollingDeltas ? 1 : 12)) == true ? nil : event
        }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}

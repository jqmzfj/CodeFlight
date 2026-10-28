import SwiftUI
import AppKit

/// Preferences are emitted only by instantiated lazy rows, never an entire layout cache.
struct GitDiffVisibleRow: Equatable {
    let location: GitDiffReadingLocation
    let minY: CGFloat
    let maxY: CGFloat
}

struct GitDiffVisibleRowPreference: PreferenceKey {
    static let defaultValue: [Bool: GitDiffVisibleRow] = [:]
    static func reduce(value: inout [Bool: GitDiffVisibleRow], nextValue: () -> [Bool: GitDiffVisibleRow]) {
        for (mode, row) in nextValue() where row.minY.isFinite && row.maxY.isFinite && row.maxY > 1 {
            if value[mode] == nil || row.minY < value[mode]!.minY { value[mode] = row }
        }
    }
}

/// Native row bounds stay independent even when SwiftUI combines selectable Text.
/// This tracker owns one clip observer and weak references to instantiated lazy rows.
@MainActor final class GitDiffReadingTracker {
    private struct WeakRow { weak var view: GitDiffReadingMarkerView? }
    private var rows: [ObjectIdentifier: WeakRow] = [:]
    private weak var clip: NSClipView?
    private var observer: NSObjectProtocol?
    private(set) var locations: [Bool: GitDiffReadingLocation] = [:]

    func register(_ view: GitDiffReadingMarkerView) {
        rows[ObjectIdentifier(view)] = WeakRow(view: view)
        if let next = view.enclosingScrollView?.contentView, next !== clip {
            detach(); clip = next
            next.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: next, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.capture() }
            }
        }
        capture()
    }
    func unregister(_ view: GitDiffReadingMarkerView) {
        rows.removeValue(forKey: ObjectIdentifier(view))
        if rows.isEmpty { detach() }
    }
    func capture() {
        guard let clip else { return }
        var visible: [Bool: GitDiffVisibleRow] = [:]
        rows = rows.filter { $0.value.view != nil }
        for row in rows.values {
            guard let view = row.view, view.window != nil, !view.isHiddenOrHasHiddenAncestor,
                  view.enclosingScrollView?.contentView === clip else { continue }
            let frame = view.convert(view.bounds, to: clip)
            let viewport = clip.bounds
            guard frame.intersects(viewport) else { continue }
            GitDiffVisibleRowPreference.reduce(value: &visible) {
                [view.split: .init(location: view.location, minY: frame.minY - viewport.minY, maxY: frame.maxY - viewport.minY)]
            }
        }
        for (mode, row) in visible { locations[mode] = row.location }
    }
    /// ScrollViewReader brings a lazy row into existence, then native geometry
    /// corrects its estimated offset after the target layout has settled.
    func align(location: GitDiffReadingLocation, split: Bool) {
        guard let clip, let row = rows.values.compactMap(\.view).first(where: {
            $0.split == split && $0.location == location && $0.window != nil
        }) else { return }
        let frame = row.convert(row.bounds, to: clip)
        guard frame.minY.isFinite else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: frame.minY))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        capture()
    }
    func reset() { locations = [:] }
    private func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil; clip = nil
    }
}

struct GitDiffReadingMarker: NSViewRepresentable {
    let tracker: GitDiffReadingTracker
    let split: Bool
    let location: GitDiffReadingLocation
    func makeNSView(context: Context) -> GitDiffReadingMarkerView { GitDiffReadingMarkerView() }
    func updateNSView(_ view: GitDiffReadingMarkerView, context: Context) {
        view.tracker = tracker; view.split = split; view.location = location
        if view.window != nil { tracker.register(view) }
    }
    static func dismantleNSView(_ view: GitDiffReadingMarkerView, coordinator: ()) {
        view.tracker?.unregister(view); view.tracker = nil
    }
}

final class GitDiffReadingMarkerView: NSView {
    weak var tracker: GitDiffReadingTracker?
    var split = false
    var location = GitDiffReadingLocation(hunk: 0, oldLine: nil, newLine: nil)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { tracker?.unregister(self) } else { tracker?.register(self) }
    }
    override func layout() {
        super.layout()
        tracker?.register(self)
    }
}

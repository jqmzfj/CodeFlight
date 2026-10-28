import SwiftUI

enum WorkbenchLayout {
    static let didReset = Notification.Name("WorkbenchLayoutDidReset")

    static func reset(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("layout.split.") || key == "layout.diff.leftFraction" || key == "sidebarWidth" || key == "bottomToolHeight" {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: didReset, object: nil)
    }
}


enum SplitSizing {
    static let divider: CGFloat = 5

    static func bounds(extent: CGFloat, minimum: CGFloat, otherMinimum: CGFloat) -> ClosedRange<CGFloat> {
        minimum...max(minimum, extent - divider - otherMinimum)
    }

    static func fitted(_ preferred: CGFloat, to bounds: ClosedRange<CGFloat>) -> CGFloat {
        guard preferred.isFinite else { return bounds.lowerBound }
        return min(bounds.upperBound, max(bounds.lowerBound, preferred))
    }
}

/// Keeps a preferred size separately from the currently available space so
/// shrinking a window does not overwrite the user's wider layout.
struct WorkbenchSplit<First: View, Second: View>: View {
    let key: String
    let axis: SplitAxis
    let initial: CGFloat
    let minimum: CGFloat
    let otherMinimum: CGFloat
    let resizesSecond: Bool
    let external: Binding<CGFloat>?
    let first: First
    let second: Second
    @State private var preferred: CGFloat

    init(_ key: String, axis: SplitAxis = .vertical, initial: CGFloat,
         minimum: CGFloat, otherMinimum: CGFloat, resizesSecond: Bool = false,
         dimension: Binding<CGFloat>? = nil,
         @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second) {
        self.key = key; self.axis = axis; self.initial = initial
        self.minimum = minimum; self.otherMinimum = otherMinimum
        self.resizesSecond = resizesSecond; external = dimension
        self.first = first(); self.second = second()
        let saved = UserDefaults.standard.double(forKey: "layout.split." + key)
        _preferred = State(initialValue: saved.isFinite && saved > 0 ? CGFloat(saved) : initial)
    }

    var body: some View {
        GeometryReader { geometry in
            let extent = axis == .vertical ? geometry.size.width : geometry.size.height
            let bounds = SplitSizing.bounds(extent: extent, minimum: minimum, otherMinimum: otherMinimum)
            let size = SplitSizing.fitted(external?.wrappedValue ?? preferred, to: bounds)
            let dimension = Binding<CGFloat>(get: { size }, set: { value in
                preferred = value
                external?.wrappedValue = value
            })
            let firstSize = resizesSecond ? max(0, extent - SplitSizing.divider - size) : size
            let secondSize = resizesSecond ? size : max(0, extent - SplitSizing.divider - size)
            if axis == .vertical {
                HStack(spacing: 0) {
                    // A fixed-width frame defaults to centered alignment. That leaves
                    // intrinsic-width panels floating in the middle of their column and
                    // can expose a large empty strip on either side. Keep every split
                    // child anchored to the leading edge and let it fill the column.
                    first.frame(width: firstSize, alignment: .topLeading)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .clipped()
                    divider(dimension, bounds: bounds)
                    second.frame(width: secondSize, alignment: .topLeading)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .clipped()
                }
            } else {
                VStack(spacing: 0) {
                    first.frame(height: firstSize, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .clipped()
                    divider(dimension, bounds: bounds)
                    second.frame(height: secondSize, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .clipped()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WorkbenchLayout.didReset)) { _ in
            preferred = initial
            external?.wrappedValue = initial
        }
    }

    private func divider(_ dimension: Binding<CGFloat>, bounds: ClosedRange<CGFloat>) -> some View {
        SplitDivider(axis: axis, dimension: dimension, range: bounds,
                     inverted: resizesSecond ? axis == .vertical : axis == .horizontal,
                     reset: {
                         preferred = initial; external?.wrappedValue = initial
                         UserDefaults.standard.removeObject(forKey: "layout.split." + key)
                     }, commit: {
                         UserDefaults.standard.set(Double(external?.wrappedValue ?? preferred), forKey: "layout.split." + key)
                     })
            .frame(width: axis == .vertical ? SplitSizing.divider : nil,
                   height: axis == .horizontal ? SplitSizing.divider : nil)
    }
}

/// A text area in a scrolling form grows independently of the form's columns.
struct ResizableFormArea<Content: View>: View {
    let key: String
    let initial: CGFloat
    let minimum: CGFloat
    let content: Content
    @State private var height: CGFloat

    init(_ key: String, initial: CGFloat, minimum: CGFloat = 48, @ViewBuilder content: () -> Content) {
        self.key = key; self.initial = initial; self.minimum = minimum
        self.content = content()
        let saved = UserDefaults.standard.double(forKey: "layout.split." + key)
        _height = State(initialValue: saved.isFinite && saved >= minimum ? saved : initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            content.frame(height: height)
            SplitDivider(axis: .horizontal, dimension: $height,
                         range: minimum...CGFloat.greatestFiniteMagnitude, inverted: true,
                         reset: { height = initial; UserDefaults.standard.removeObject(forKey: "layout.split." + key) },
                         commit: { UserDefaults.standard.set(Double(height), forKey: "layout.split." + key) })
                .frame(height: SplitSizing.divider)
        }
        .onReceive(NotificationCenter.default.publisher(for: WorkbenchLayout.didReset)) { _ in height = initial }
    }
}

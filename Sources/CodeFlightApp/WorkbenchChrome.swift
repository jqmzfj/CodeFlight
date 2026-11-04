import SwiftUI
import AppKit
import ImageIO

/// Shared semantic surfaces; keep editor contrast separate from window chrome.
enum WorkbenchChrome {
    static let editorColor = dynamicColor("editor", light: (1, 1, 1), dark: (0.105, 0.109, 0.118))
    static let editor = Color(nsColor: editorColor)
    static let canvasColor = dynamicColor("canvas", light: (0.900, 0.908, 0.922), dark: (0.082, 0.086, 0.096))
    static let canvas = Color(nsColor: canvasColor)
    static let bar = canvas
    // IDEA-style surfaces: use small tonal steps first, and reserve a line for
    // the few places where a resizable boundary needs a tactile affordance.
    static let panel = Color(nsColor: dynamicColor("panel", light: (0.970, 0.974, 0.980), dark: (0.145, 0.150, 0.162)))
    static let raised = Color(nsColor: dynamicColor("raised", light: (0.985, 0.988, 0.992), dark: (0.180, 0.185, 0.198)))
    static let separator = Color.primary.opacity(0.12)
    static let quietSeparator = Color.primary.opacity(0.06)
    static let subtleDivider = Color.primary.opacity(0.06)
    // Tone and canvas gaps establish the pane hierarchy. A faint single rim
    // only finishes rounded edges, without turning the workspace into a grid.
    static let paneBorder = Color.primary.opacity(0.09)
    // Two pane insets plus the 5pt resize target make a compact 7pt gutter.
    static let paneInset: CGFloat = 1
    static let paneCornerRadius: CGFloat = 7
    static let selectedSurface = Color.accentColor.opacity(0.12)
    static let selectedBorder = Color(nsColor: .controlAccentColor).opacity(0.30)
    static let rowHeight: CGFloat = 30

    private static func dynamicColor(_ name: String, light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: NSColor.Name("CodeFlight.chrome." + name)) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        }
    }
}

/// A single bounded, downsampled image per window. Never decode a wallpaper as
/// a side effect of evaluating SwiftUI's body or retain its full-resolution bitmap.
@MainActor
final class WorkbenchBackdrop: ObservableObject {
    enum State: Equatable {
        case idle, loading(URL), ready(URL), failed(URL)
    }
    @Published private(set) var image: NSImage?
    @Published private(set) var state: State = .idle
    private var displayedURL: URL?
    private var requestID = UUID()
    private var worker: Task<CGImage?, Never>?
    private let decoder: @Sendable (URL) async -> CGImage?

    init(decoder: @escaping @Sendable (URL) async -> CGImage? = { url in decode(url) }) {
        self.decoder = decoder
    }

    func load(_ url: URL?) async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        requestID = request
        worker?.cancel()
        guard let url else {
            worker = nil; image = nil; displayedURL = nil; state = .idle
            return
        }
        let previousState: State
        if let displayedURL { previousState = .ready(displayedURL) }
        else if case .failed = state { previousState = state }
        else { previousState = .idle }
        state = .loading(url)
        let decoder = decoder
        let worker = Task.detached(priority: .utility) { await decoder(url) }
        self.worker = worker
        let bitmap = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard requestID == request else { return }
        self.worker = nil
        guard !Task.isCancelled else {
            state = previousState
            return
        }
        guard let bitmap else {
            image = nil; displayedURL = nil; state = .failed(url)
            return
        }
        let result = NSImage(size: NSSize(width: bitmap.width, height: bitmap.height))
        result.addRepresentation(NSBitmapImageRep(cgImage: bitmap))
        image = result; displayedURL = url; state = .ready(url)
    }

    nonisolated private static func decode(_ url: URL) -> CGImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2560,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}


/// Configure only the window hosting this workbench. Sheets and system panels
/// retain AppKit's own titlebar behavior.
struct WorkbenchWindowAnchor: NSViewRepresentable {
    let theme: AppTheme

    func makeNSView(context: Context) -> NSView {
        let view = WorkbenchTitlebarAnchor()
        view.theme = theme
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        guard let anchor = view as? WorkbenchTitlebarAnchor else { return }
        anchor.theme = theme
        anchor.applyAppearance()
    }
}

/// SwiftUI's content frame expresses a preferred layout size, but AppKit can
/// still temporarily negotiate a smaller native window while the user drags
/// an edge or restores a saved frame. Keep the workbench's lowest usable size
/// at the window level so the navigator, editor and tool rail never collapse
/// into an unusable layout.
struct WorkbenchWindowMinimumSize: NSViewRepresentable {
    let minimum: NSSize

    func makeNSView(context: Context) -> SizingView {
        SizingView(minimum: minimum)
    }

    func updateNSView(_ view: SizingView, context: Context) {
        view.minimum = minimum
        view.applyMinimumIfNeeded()
    }

    final class SizingView: NSView {
        var minimum: NSSize
        private var sizingScheduled = false

        init(minimum: NSSize) {
            self.minimum = minimum
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyMinimumIfNeeded()
        }

        func applyMinimumIfNeeded() {
            guard !sizingScheduled else { return }
            sizingScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sizingScheduled = false
                guard let window = self.window else { return }
                if window.contentMinSize != self.minimum {
                    window.contentMinSize = self.minimum
                }
                let contentSize = window.contentRect(forFrameRect: window.frame).size
                if contentSize.width < self.minimum.width || contentSize.height < self.minimum.height {
                    window.setContentSize(NSSize(width: max(contentSize.width, self.minimum.width),
                                                 height: max(contentSize.height, self.minimum.height)))
                }
            }
        }
    }
}

private final class WorkbenchTitlebarAnchor: NSView {
    var theme: AppTheme = .system

    func applyAppearance() {
        guard let window else { return }
        // Keep native toolbar controls in step with SwiftUI. Nil retains live
        // system appearance changes when the user chooses Follow System.
        let appearance: NSAppearance?
        switch theme {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        if NSApp.appearance?.name != appearance?.name { NSApp.appearance = appearance }
        if window.appearance?.name != appearance?.name { window.appearance = appearance }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.titleVisibility = .hidden
        window?.titlebarAppearsTransparent = true
        window?.backgroundColor = WorkbenchChrome.canvasColor
        applyAppearance()
    }
}

import SwiftUI
import AppKit
import CoreText

struct PreparedCodeDocument: Sendable {
    let id = UUID()
    let text: String
    let offsets: [Int]
    let width: CGFloat
    let limitedLines: Bool
    let shortenedLines: Bool
    var syntax: CodeSyntaxIndex? = nil
    let fontSize: CGFloat
    var lineHeight: CGFloat { max(16, ceil(fontSize * 1.38)) }

    static func prepare(_ source: String, fontName: String, cellWidth: CGFloat, language: String = "", fontSize: CGFloat = 13) -> PreparedCodeDocument {
        // Detached tasks have no AppKit event-loop autorelease pool. Drain
        // temporary Core Text/Objective-C objects before retaining the result.
        autoreleasepool { prepareDocument(source, fontName: fontName, cellWidth: cellWidth, language: language, fontSize: fontSize) }
    }

    private static func prepareDocument(_ source: String, fontName: String, cellWidth: CGFloat, language: String, fontSize: CGFloat) -> PreparedCodeDocument {
        // AppKit also treats Unicode line/paragraph separators as hard breaks.
        // Count them consistently with the fixed-height gutter and sparse layout.
        if Task.isCancelled { return PreparedCodeDocument(text: "", offsets: [], width: 0, limitedLines: false, shortenedLines: false, fontSize: fontSize) }
        let normalized: String
        // CR starts with 0x0D; both Unicode separators start with 0xE2.
        // Ordinary LF files can reuse the source without four full Foundation
        // replacement passes. Other 0xE2 sequences take the exact slow path.
        if source.utf8.contains(where: { $0 == 0x0D || $0 == 0xE2 }) {
            normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\u{2028}", with: "\n")
                .replacingOccurrences(of: "\u{2029}", with: "\n")
        } else { normalized = source }
        let parts = normalized.split(separator: "\n", maxSplits: PreviewLinePolicy.maximumLines, omittingEmptySubsequences: false)
        var lines: [String] = []
        var offsets: [Int] = []
        var offset = 0
        var width: CGFloat = 0
        var shortened = false
        // Share font fallback/shaping work within bounded chunks. A typesetter
        // per line is slow, but a single document-wide typesetter retains
        // excessive glyph data. Each chunk is released before the next one.
        var shapedLines: [(offset: Int, length: Int)] = []
        lines.reserveCapacity(min(parts.count, PreviewLinePolicy.maximumLines))
        offsets.reserveCapacity(min(parts.count, PreviewLinePolicy.maximumLines))
        for part in parts.prefix(PreviewLinePolicy.maximumLines) {
            if Task.isCancelled { return PreparedCodeDocument(text: "", offsets: [], width: 0, limitedLines: false, shortenedLines: false, fontSize: fontSize) }
            let line: String
            if part.utf8.count > PreviewLinePolicy.maximumLineBytes {
                line = String(decoding: part.utf8.prefix(PreviewLinePolicy.maximumLineBytes), as: UTF8.self) + " …"
                shortened = true
            } else { line = String(part) }
            offsets.append(offset)
            offset += line.utf16.count + 1
            lines.append(line)
            if line.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) {
                width = max(width, CGFloat(line.utf8.count) * cellWidth)
            } else if !line.isEmpty {
                shapedLines.append((offsets[offsets.count - 1], line.utf16.count))
            }
        }
        let text = lines.joined(separator: "\n")
        if !shapedLines.isEmpty {
            // A small bounded worker pool keeps Core Text storage below the
            // full-document alternative while using spare cores on large
            // previews. Keep the unsafe task handle strictly within its
            // documented scope;
            // concurrentPerform joins both workers before this closure returns.
            width = max(width, withUnsafeCurrentTask { task in
                let measurement = CodeWidthMeasurement(text: text, ranges: shapedLines,
                                                      fontName: fontName, cellWidth: cellWidth, fontSize: fontSize, task: task)
                let workers = min(4, measurement.chunks.count)
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    measurement.measure(worker: worker, stride: workers)
                }
                return measurement.maximum
            })
        }
        if Task.isCancelled { return PreparedCodeDocument(text: "", offsets: [], width: 0, limitedLines: false, shortenedLines: false, fontSize: fontSize) }

        return PreparedCodeDocument(text: text, offsets: offsets, width: ceil(width), limitedLines: parts.count > PreviewLinePolicy.maximumLines, shortenedLines: shortened, syntax: CodeSyntaxIndex.prepare(text, language: language), fontSize: fontSize)
    }
}

/// Immutable input is shared between workers. Only the final maximum mutates,
/// under a lock. Core Text typesetters and paragraph styles stay worker-local.
/// The task handle never outlives the synchronous withUnsafeCurrentTask scope.
private final class CodeWidthMeasurement: @unchecked Sendable {
    let text: NSString
    let ranges: [(offset: Int, length: Int)]
    let chunks: [Range<Int>]
    let fontName: String
    let cellWidth: CGFloat
    let fontSize: CGFloat
    let task: UnsafeCurrentTask?
    private let lock = NSLock()
    private var measured: CGFloat = 0
    var maximum: CGFloat { lock.lock(); defer { lock.unlock() }; return measured }

    init(text: String, ranges: [(offset: Int, length: Int)], fontName: String, cellWidth: CGFloat, fontSize: CGFloat, task: UnsafeCurrentTask?) {
        self.text = text as NSString; self.ranges = ranges
        self.fontName = fontName; self.cellWidth = cellWidth; self.fontSize = fontSize; self.task = task
        var chunks: [Range<Int>] = []
        var index = 0
        while index < ranges.count {
            let start = ranges[index].offset
            var end = index + 1
            // Core Text's CJK spacing work grows with the text in a batch.
            // Keep both row count and UTF-16 span bounded; 32 rows retain
            // shared shaping without the larger 256-row preparation stall.
            while end < ranges.count && end - index < 32 && ranges[end].offset + ranges[end].length - start <= 65_536 {
                end += 1
            }
            chunks.append(index..<end); index = end
        }
        self.chunks = chunks
    }

    func measure(worker: Int, stride: Int) {
        autoreleasepool {
            let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = []; paragraph.defaultTabInterval = cellWidth * 4
            var maximum: CGFloat = 0
            var index = worker
            while index < chunks.count {
                if task?.isCancelled == true { return }
                let chunkRange = chunks[index]
                let first = ranges[chunkRange.lowerBound], last = ranges[chunkRange.upperBound - 1]
                let width = autoreleasepool {
                    let chunk = text.substring(with: NSRange(location: first.offset, length: last.offset + last.length - first.offset))
                    let attributed = NSAttributedString(string: chunk, attributes: [.font: font, .paragraphStyle: paragraph])
                    let typesetter = CTTypesetterCreateWithAttributedString(attributed)
                    var width: CGFloat = 0
                    for range in ranges[chunkRange] {
                        let line = CTTypesetterCreateLine(typesetter, CFRange(location: range.offset - first.offset, length: range.length))
                        width = max(width, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
                    }
                    return width
                }
                maximum = max(maximum, width)
                index += stride
            }
            lock.lock(); measured = max(measured, maximum); lock.unlock()
        }
    }
}

/// The header and native text surface share one prepared buffer. Source identity
/// prevents a completed document from being used for another file or revision.
struct PreviewSearchSnapshot {
    let file: String
    let source: String
    let prepared: PreparedCodeDocument

    func document(file: String, source: String) -> PreparedCodeDocument? {
        self.file == file && self.source == source ? prepared : nil
    }
}

private struct PreviewPreparationRequest: Equatable {
    let file: String
    let source: String
    let fontSize: CGFloat
}

/// Retain a few recently viewed buffers, never a project-wide index. Exact
/// source and font checks keep normalized/truncated buffers revision-safe.
/// This actor also keeps full-source comparisons off the UI thread.
actor PreparedPreviewCache {
    static let shared = PreparedPreviewCache()
    private struct Key: Hashable {
        let file: String
        let fontName: String
        let cellWidth: CGFloat
        let fontSize: CGFloat
    }
    private struct Entry {
        let source: String
        let document: PreparedCodeDocument
        let cost: Int
    }
    private let capacity: Int
    private let maximumEntries: Int
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private var totalCost = 0

    init(capacity: Int = 24 * 1024 * 1024, maximumEntries: Int = 3) {
        self.capacity = max(0, capacity)
        self.maximumEntries = max(0, maximumEntries)
    }

    func document(file: String, source: String, fontName: String, cellWidth: CGFloat, fontSize: CGFloat = 13) async -> PreparedCodeDocument? {
        guard !Task.isCancelled else { return nil }
        let key = Key(file: file, fontName: fontName, cellWidth: cellWidth, fontSize: fontSize)
        if let entry = entries[key] {
            if entry.source == source {
                touch(key)
                return Task.isCancelled ? nil : entry.document
            }
            remove(key)
        }
        // Do not serialize independent preparation on the cache actor. The
        // owning SwiftUI task still cancels its own worker on file changes.
        let worker = Task.detached(priority: .userInitiated) {
            PreparedCodeDocument.prepare(source, fontName: fontName, cellWidth: cellWidth, language: URL(fileURLWithPath: file).pathExtension.lowercased(), fontSize: fontSize)
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return nil }
        // Conservative accounting includes both UTF-8 and potential bridged
        // UTF-16 storage, source retention and the line-offset array. Shared
        // String storage is deliberately counted twice rather than assumed.
        let cost = source.utf8.count + source.utf16.count * 2
            + result.text.utf8.count + result.text.utf16.count * 2
            + result.offsets.count * MemoryLayout<Int>.stride + (result.syntax?.storageCost ?? 0) + 256
        guard !Task.isCancelled else { return nil }
        remove(key)
        if maximumEntries > 0, cost <= capacity {
            entries[key] = Entry(source: source, document: result, cost: cost)
            totalCost += cost
            touch(key)
            while totalCost > capacity || order.count > maximumEntries, let oldest = order.first { remove(oldest) }
        }
        return result
    }

    private func remove(_ key: Key) {
        if let removed = entries.removeValue(forKey: key) { totalCost -= removed.cost }
        order.removeAll { $0 == key }
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

struct CodePreview: View {
    let file: String
    let content: String
    let search: String
    let appLanguage: AppLanguage
    var fontSize: CGFloat = 13
    var document: FilePreviewDocument?
    var navigation: FileSearchNavigation? = nil
    var onPrepared: ((PreviewSearchSnapshot) -> Void)? = nil
    @State private var prepared: PreparedCodeDocument?
    @State private var preparedSource: String?
    private var preview: FilePreviewDocument? { document ?? (content.isEmpty ? nil : FilePreviewDocument(text: content)) }
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: appLanguage) }

    var body: some View {
        Group {
            if file.isEmpty { message("doc.text", text("选择文件以预览内容", "Select a file to preview")) }
            else if let preview {
                switch preview.kind {
                case .empty: message("doc", text("空文件", "Empty file"))
                case .binary: message("doc.zipper", text("此文件不支持文本预览", "Text preview is unavailable for this file"))
                case .unreadable(let error):
                    VStack(spacing: 12) {
                        message("exclamationmark.triangle", text("无法读取文件", "Cannot read file"), detail: error)
                    }
                case .text:
                    if let prepared, preparedSource == content, abs(prepared.fontSize - fontSize) < 0.01 {
                        VStack(spacing: 0) {
                            if preview.truncated || prepared.limitedLines || prepared.shortenedLines {
                                HStack(spacing: 8) {
                                    Image(systemName: "info.circle")
                                    Text(notice(preview, prepared)).lineLimit(2)
                                    Spacer(minLength: 0)
                                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 7)
                                Divider()
                            }
                            NativeTextSurface(document: prepared, language: URL(fileURLWithPath: file).pathExtension.lowercased(), search: search, navigation: navigation?.file == file ? navigation : nil)
                                .id(file)
                        }
                    } else { loading }
                }
            } else { loading }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: PreviewPreparationRequest(file: file, source: content, fontSize: fontSize)) {
            guard !content.isEmpty else { prepared = nil; preparedSource = nil; return }
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let name = font.fontName
            let cellWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
            guard let result = await PreparedPreviewCache.shared.document(file: file, source: content, fontName: name, cellWidth: cellWidth, fontSize: fontSize), !Task.isCancelled else { return }
            PreviewTrace.shared?.didPrepare(file: file, document: result.id)
            prepared = result; preparedSource = content
            onPrepared?(PreviewSearchSnapshot(file: file, source: content, prepared: result))
        }
    }
    private var loading: some View {
        VStack(spacing: 10) { ProgressView().controlSize(.small); Text(text("正在读取文件…", "Loading file…")).font(.system(size: 12)).foregroundStyle(.secondary) }
    }
    private func message(_ icon: String, _ title: String, detail: String? = nil) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(4).frame(maxWidth: 420).textSelection(.enabled) }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func notice(_ preview: FilePreviewDocument, _ document: PreparedCodeDocument) -> String {
        var notices: [String] = []
        if preview.truncated { notices.append(text("大文件：仅预览前 2 MB", "Large file: previewing the first 2 MB")) }
        if document.limitedLines { notices.append(text("最多显示 100,000 行", "Showing up to 100,000 lines")) }
        if document.shortenedLines { notices.append(text("超长行仅显示前 32 KB", "Long lines are limited to 32 KB")) }
        return notices.joined(separator: " · ")
    }
}

struct NativeTextSurface: NSViewRepresentable {
    let document: PreparedCodeDocument
    let language: String
    let search: String
    var navigation: FileSearchNavigation? = nil
    @Environment(\.colorScheme) var colorScheme
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> CodePreviewContainer {
        let scroll = Self.makeScrollView()
        context.coordinator.attach(scroll)
        return CodePreviewContainer(scroll: scroll)
    }
    static func makeScrollView() -> CodeScrollView {
        let scroll = CodeScrollView()
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        let storage = NSTextStorage()
        let textContainer = NSTextContainer(size: .zero)
        let layoutManager = CodeLayoutManager()
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        let view = CodeTextView(frame: .zero, textContainer: textContainer)
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.allowsUndo = false; view.usesFindPanel = false; view.usesFontPanel = false
        view.isHorizontallyResizable = false; view.isVerticallyResizable = false
        view.textContainerInset = NSSize(width: 8, height: 12)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        // Pair sparse layout with the coordinator's exact line geometry.
        // TextKit's estimated positions alone can leave distant lines blank.
        view.layoutManager?.allowsNonContiguousLayout = true
        view.layoutManager?.backgroundLayoutEnabled = false
        view.backgroundColor = .textBackgroundColor
        view.setAccessibilityLabel("Code preview")
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.borderType = .noBorder
        scroll.documentView = view
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        return scroll
    }
    func updateNSView(_ container: CodePreviewContainer, context: Context) {
        context.coordinator.update(document, language: language, search: search, navigation: navigation)
    }
    static func dismantleNSView(_ view: CodePreviewContainer, coordinator: Coordinator) { coordinator.detach() }

    @MainActor
    final class Coordinator: NSObject, @MainActor NSLayoutManagerDelegate {
        weak var scroll: CodeScrollView?
        var observer: NSObjectProtocol?
        var document: PreparedCodeDocument?
        var language = ""
        var search = ""
        var highlighted = NSRange(location: 0, length: 0)
        private struct HighlightViewport: Equatable {
            let document: UUID
            let range: NSRange
            let language: String
            let search: String
            let appearance: NSAppearance.Name
            let containerSize: NSSize
        }
        private var highlightedViewport: HighlightViewport?
        private var updating = false
        private var highlightScheduled = false
        private var navigationTask: Task<Void, Never>?
        private var lastNavigationID: UUID?
        private var navigationQuery = ""
        func attach(_ scroll: CodeScrollView) {
            self.scroll = scroll
            (scroll.documentView as? NSTextView)?.layoutManager?.delegate = self
            (scroll.documentView as? CodeTextView)?.onRevealInsertionPoint = { [weak self] index in self?.revealInsertionPoint(index) }
            scroll.onViewportResize = { [weak self] in self?.scheduleHighlight() }
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleHighlight() }
            }
        }
        func detach() {
            navigationTask?.cancel(); navigationTask = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            scroll?.onViewportResize = nil
            (scroll?.documentView as? CodeTextView)?.onRevealInsertionPoint = nil
            (scroll?.documentView as? NSTextView)?.layoutManager?.delegate = nil
            scroll = nil
            highlightedViewport = nil
        }
        private func lineIndex(at character: Int, in document: PreparedCodeDocument) -> Int {
            var low = 0
            var high = document.offsets.count
            while low < high {
                let middle = (low + high) / 2
                if document.offsets[middle] <= character { low = middle + 1 } else { high = middle }
            }
            return max(0, low - 1)
        }
        private func revealInsertionPoint(_ index: Int) {
            guard let scroll, let document, index != NSNotFound, !document.offsets.isEmpty else { return }
            let y = CGFloat(lineIndex(at: index, in: document)) * document.lineHeight
            let bounds = scroll.contentView.bounds
            var origin = bounds.origin
            if y + 12 < bounds.minY { origin.y = y }
            else if y + 12 + document.lineHeight > bounds.maxY { origin.y = y + 24 + document.lineHeight - bounds.height }
            origin.y = min(max(0, scroll.textHeight - bounds.height), max(0, origin.y))
            if origin != bounds.origin {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        func update(_ document: PreparedCodeDocument, language: String, search: String, navigation: FileSearchNavigation? = nil) {
            guard let scroll, let view = scroll.documentView as? NSTextView else { return }
            if self.document?.id != document.id || self.search != search || navigation == nil {
                navigationTask?.cancel(); navigationTask = nil
            }
            updating = true
            self.language = language; self.search = search
            if self.document?.id != document.id {
                self.document = document
                if let manager = view.layoutManager as? CodeLayoutManager {
                    manager.fixedLineHeight = document.lineHeight
                    manager.lineOffsets = document.offsets
                }
                (view as? CodeTextView)?.traceDocumentID = document.id
                let font = NSFont.monospacedSystemFont(ofSize: document.fontSize, weight: .regular)
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = document.lineHeight; paragraph.maximumLineHeight = document.lineHeight
                paragraph.lineBreakMode = .byClipping
                paragraph.tabStops = []; paragraph.defaultTabInterval = ("0" as NSString).size(withAttributes: [.font: font]).width * 4
                view.textStorage?.setAttributedString(NSAttributedString(string: document.text, attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]))
                highlighted = NSRange(location: 0, length: 0)
                highlightedViewport = nil
                scroll.textWidth = document.width + 16
                scroll.textHeight = CGFloat(max(1, document.offsets.count)) * document.lineHeight + 24
                scroll.lineHeight = document.lineHeight
                scroll.gutter?.lineHeight = document.lineHeight
                scroll.fitDocument()
                view.setSelectedRange(NSRange(location: 0, length: 0))
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                scroll.gutter?.lineCount = document.offsets.count
                // SwiftUI supplies the pane's final size after this update.
                // NSTextView can reveal its insertion point while still at
                // zero width, shifting a new wide document past its first column.
                DispatchQueue.main.async { [weak self, weak scroll] in
                    guard let self, let scroll, self.document?.id == document.id else { return }
                    scroll.fitDocument()
                    scroll.contentView.scroll(to: .zero)
                    scroll.reflectScrolledClipView(scroll.contentView)
                    self.highlight()
                }
            }
            updating = false
            highlight()
            scroll.gutter?.needsDisplay = true
            if let navigation, navigation.id != lastNavigationID {
                lastNavigationID = navigation.id
                navigate(navigation.direction)
            }
        }

        private func navigate(_ direction: FileSearchNavigation.Direction) {
            guard let document, let view = scroll?.documentView as? NSTextView else { return }
            navigationTask?.cancel()
            let query = search
            let originalSelection = view.selectedRange()
            let anchor = navigationQuery == query ? originalSelection : NSRange(location: originalSelection.location, length: 0)
            let input = FileSearchRequest(content: document.text, query: query)
            navigationTask = Task { [weak self, weak view] in
                let worker = Task.detached(priority: .userInitiated) { FileSearchNavigator.find(input, selection: anchor, direction: direction) }
                let match = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let self, let view, let match,
                      self.document?.id == document.id, self.search == query, view.selectedRange() == originalSelection else { return }
                self.navigationQuery = query
                self.revealInsertionPoint(match.location)
                self.highlight()
                view.setSelectedRange(match)
                view.scrollRangeToVisible(match)
                self.revealInsertionPoint(match.location)
                if view.window?.isVisible == true { view.showFindIndicator(for: match) }
            }
        }
        // No wrapping + fixed row height lets us place a distant paragraph
        // without typesetting every paragraph above it. Keep TextKit's glyph
        // shaping and native selection; replace only its estimated row origin.
        func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>, lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>, in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
            guard glyphRange.length > 0, let document, !document.offsets.isEmpty else { return false }
            let character = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let y = CGFloat(lineIndex(at: character, in: document)) * document.lineHeight
            lineFragmentRect.pointee.origin.y = y
            lineFragmentUsedRect.pointee.origin.y = y
            return true
        }
        // AppKit may emit bounds notifications for intermediate geometry.
        // Coalesce them until the transaction ends, then color the final pane.
        private func scheduleHighlight() {
            guard !updating, !highlightScheduled else { return }
            highlightScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.highlightScheduled = false
                self.highlight()
            }
        }
        func highlight() {
            guard !updating, let scroll, let view = scroll.documentView as? NSTextView,
                  let manager = view.layoutManager, let document else { return }
            let origin = scroll.contentView.bounds.origin
            updating = true
            defer { updating = false }
            // Fractional scrolling still moves the gutter even when the set
            // of visible source rows is unchanged.
            scroll.gutter?.needsDisplay = true
            let first = max(0, Int((scroll.contentView.bounds.minY - 12) / document.lineHeight) - 1)
            let last = min(document.offsets.count, first + Int(ceil(scroll.contentView.bounds.height / document.lineHeight)) + 4)
            guard first < last else { return }
            let source = document.text as NSString
            let start = document.offsets[first]
            let end = last < document.offsets.count ? document.offsets[last] : source.length
            let range = NSRange(location: start, length: end - start)
            let viewport = HighlightViewport(document: document.id, range: range, language: language,
                                             search: search, appearance: view.effectiveAppearance.name,
                                             containerSize: view.textContainer?.containerSize ?? .zero)
            // Native scrolling emits multiple bounds changes within a row.
            // Retain just this viewport identity, not another attributed copy
            // or a history of colored blocks. Geometry/appearance changes and
            // new search or document revisions always take the normal path.
            guard highlightedViewport != viewport else { return }
            manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: highlighted)
            manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: highlighted)
            // Some AppKit/TextKit combinations drop temporary foreground
            // attributes while a sparse, non-contiguous layout is being
            // repaired. Reset only the previously visible slice in storage,
            // then mirror the new slice there as well as in temporary attrs.
            // This keeps large files incremental while making colors reliable
            // across scrolling, window resizes, and appearance changes.
            if let storage = view.textStorage, highlighted.length > 0,
               NSMaxRange(highlighted) <= storage.length {
                storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: highlighted)
                storage.removeAttribute(.backgroundColor, range: highlighted)
            }
            highlighted = range
            manager.ensureLayout(forCharacterRange: highlighted)
            // TextKit can relocate an existing sparse block when joining it
            // to another one. Align the final cache as well as new fragments.
            for index in first..<last {
                let length = (index + 1 < document.offsets.count ? document.offsets[index + 1] : source.length) - document.offsets[index]
                guard length > 0 else { continue }
                let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: document.offsets[index], length: length), actualCharacterRange: nil)
                guard glyphs.length > 0 else { continue }
                var effective = NSRange()
                var rect = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: &effective, withoutAdditionalLayout: true)
                var used = manager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil, withoutAdditionalLayout: true)
                guard effective.length > 0 else { continue }
                rect.origin.y = CGFloat(index) * document.lineHeight
                used.origin.y = rect.origin.y
                manager.setLineFragmentRect(rect, forGlyphRange: effective, usedRect: used)
            }
            for index in first..<last {
                let offset = document.offsets[index]
                let end = index + 1 < document.offsets.count ? document.offsets[index + 1] - 1 : source.length
                let length = end - offset
                guard length > 0 else { continue }
                let line = source.substring(with: NSRange(location: offset, length: length))
                let tokens = document.syntax.flatMap { $0.language == language ? $0.tokens(in: NSRange(location: offset, length: length)) : nil }
                let attributed = SyntaxHighlighter.attributed(line, language: language, search: search, protectedTokens: tokens)
                attributed.enumerateAttributes(in: NSRange(location: 0, length: length)) { values, range, _ in
                    let colors = values.filter { $0.key == .foregroundColor || $0.key == .backgroundColor }
                    manager.setTemporaryAttributes(colors, forCharacterRange: NSRange(location: offset + range.location, length: range.length))
                    if let storage = view.textStorage {
                        let target = NSRange(location: offset + range.location, length: range.length)
                        guard target.location >= 0, NSMaxRange(target) <= storage.length else { return }
                        storage.addAttributes(colors, range: target)
                    }
                }
            }
            if scroll.contentView.bounds.origin != origin {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            scroll.gutter?.needsDisplay = true
            highlightedViewport = viewport
        }
    }
}

/// TextKit's glyph bounds can carry a small font-leading offset after a
/// distant non-contiguous jump. Keep the reported bounds aligned with the
/// fixed line fragments used by the editor without laying out the whole file.
final class CodeLayoutManager: NSLayoutManager {
    var fixedLineHeight: CGFloat = 0
    var lineOffsets: [Int] = []

    override func lineFragmentRect(forGlyphAt glyphIndex: Int, effectiveRange effectiveGlyphRange: NSRangePointer?, withoutAdditionalLayout flag: Bool) -> NSRect {
        var rect = super.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: effectiveGlyphRange, withoutAdditionalLayout: flag)
        guard fixedLineHeight > 0, glyphIndex > 0, glyphIndex <= (lineOffsets.last ?? 0), !lineOffsets.isEmpty else { return rect }
        var low = 0
        var high = lineOffsets.count
        while low < high {
            let middle = (low + high) / 2
            if lineOffsets[middle] <= glyphIndex { low = middle + 1 } else { high = middle }
        }
        rect.origin.y = CGFloat(max(0, low - 1)) * fixedLineHeight
        return rect
    }

    override func boundingRect(forGlyphRange glyphRange: NSRange, in textContainer: NSTextContainer) -> NSRect {
        var rect = super.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        guard fixedLineHeight > 0, rect.height > 0, rect.minY.isFinite else { return rect }
        guard glyphRange.location != NSNotFound else { return rect }
        var effective = NSRange()
        let line = lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: &effective, withoutAdditionalLayout: true)
        if line.height > 0, line.minY.isFinite {
            rect.origin.y = line.minY
        } else {
            rect.origin.y = (rect.minY / fixedLineHeight).rounded() * fixedLineHeight
        }
        return rect
    }
}

/// Keep AppKit's selection, hit testing and horizontal reveal. Sparse layout
/// estimates must not prevent a keyboard insertion point from being revealed
/// at the document's known fixed row position.
final class CodeTextView: NSTextView {
    var onRevealInsertionPoint: ((Int) -> Void)?
    var traceDocumentID: UUID?
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if window?.isVisible == true, !visibleRect.isEmpty, dirtyRect.intersects(visibleRect), let traceDocumentID {
            PreviewTrace.shared?.didDraw(document: traceDocumentID)
        }
    }
    override func scrollRangeToVisible(_ range: NSRange) {
        super.scrollRangeToVisible(range)
        if range.length == 0 { onRevealInsertionPoint?(range.location) }
    }
}

final class CodeScrollView: NSScrollView {
    weak var gutter: CodeLineGutter?
    static let lineHeight: CGFloat = 18
    var lineHeight: CGFloat = CodeScrollView.lineHeight
    var textWidth: CGFloat = 0
    var textHeight: CGFloat = 0
    private var fitting = false
    var onViewportResize: (() -> Void)?
    private var lastViewportSize: NSSize?
    private var resizeOrigin: NSPoint?
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { resizeOrigin = contentView.bounds.origin }
        super.setFrameSize(newSize)
    }
    override func layout() {
        super.layout(); fitDocument()
        if let origin = resizeOrigin {
            resizeOrigin = nil
            let maximumX = max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
            let maximumY = max(0, (documentView?.frame.height ?? 0) - contentView.bounds.height)
            contentView.scroll(to: NSPoint(x: min(maximumX, max(0, origin.x)), y: min(maximumY, max(0, origin.y))))
            reflectScrolledClipView(contentView)
        }
        let size = contentView.bounds.size
        if lastViewportSize != size {
            lastViewportSize = size
            // SwiftUI may assign the real pane size after the first update.
            // Recolor newly visible lines even if the scroll origin stays put.
            onViewportResize?()
        }
    }
    func fitDocument() {
        guard !fitting, let view = documentView as? NSTextView else { return }
        fitting = true
        let needsHorizontal = textWidth > contentView.bounds.width + 1
        if hasHorizontalScroller != needsHorizontal { hasHorizontalScroller = needsHorizontal }
        let size = NSSize(width: max(contentView.bounds.width, textWidth), height: max(contentView.bounds.height, textHeight))
        if view.frame.size != size { view.setFrameSize(size) }
        view.textContainer?.containerSize = NSSize(width: max(1, size.width - 16), height: max(1, size.height - 24))
        fitting = false
    }
}

final class CodePreviewContainer: NSView {
    let scroll: CodeScrollView
    let gutter: CodeLineGutter
    init(scroll: CodeScrollView) {
        self.scroll = scroll
        gutter = CodeLineGutter(scrollView: scroll)
        super.init(frame: .zero)
        scroll.gutter = gutter
        addSubview(gutter); addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func layout() {
        super.layout()
        gutter.frame = NSRect(x: 0, y: 0, width: 54, height: bounds.height)
        scroll.frame = NSRect(x: 54, y: 0, width: max(0, bounds.width - 54), height: bounds.height)
        scroll.fitDocument()
        gutter.needsDisplay = true
    }
}

final class CodeLineGutter: NSView {
    var lineCount = 0
    var lineHeight: CGFloat = CodeScrollView.lineHeight
    override var isFlipped: Bool { true }
    weak var scrollView: NSScrollView?
    private let ruleThickness: CGFloat = 54
    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: NSRect) {
        guard let scrollView else { return }
        // A partially visible first row must not paint over the toolbar.
        NSBezierPath(rect: bounds).addClip()
        NSColor.textBackgroundColor.setFill(); bounds.fill()
        let offset = scrollView.contentView.bounds.minY
        let first = max(0, Int((offset - 12) / lineHeight))
        let last = min(lineCount, first + Int(ceil(bounds.height / lineHeight)) + 2)
        guard first < last else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        for index in first..<last {
            let label = String(index + 1) as NSString
            label.draw(at: NSPoint(x: ruleThickness - 10 - label.size(withAttributes: attributes).width, y: 12 + CGFloat(index) * lineHeight - offset + 2), withAttributes: attributes)
        }
    }
}

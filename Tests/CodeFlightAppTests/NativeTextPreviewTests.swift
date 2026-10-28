import XCTest
import AppKit
import CoreText
@testable import CodeFlightApp

final class NativeTextPreviewTests: XCTestCase {
    func testSearchCountsAndNavigationUseDisplayedLimitsAndNormalizedNewlines() throws {
        let source = "needle\r\nsecond\u{2028}third\r" + String(repeating: "x", count: 40_000) + "hidden_long\n"
            + String(repeating: "line\n", count: 100_000) + "hidden_tail"
        let prepared = PreparedCodeDocument.prepare(source, fontName: "Menlo", cellWidth: 8)
        XCTAssertTrue(prepared.limitedLines)
        XCTAssertTrue(prepared.shortenedLines)
        XCTAssertEqual(prepared.offsets.count, 100_000)
        for query in ["hidden_long", "hidden_tail"] {
            let request = FileSearchRequest(content: prepared.text, query: query)
            XCTAssertEqual(FileSearchCounter.count(request), 0)
            XCTAssertNil(FileSearchNavigator.find(request, selection: .init(location: 0, length: 0), direction: .next))
        }
        let newline = FileSearchRequest(content: prepared.text, query: "second\nthird")
        XCTAssertEqual(FileSearchCounter.count(newline), 1)
        let match = try XCTUnwrap(FileSearchNavigator.find(newline, selection: .init(location: 0, length: 0), direction: .next))
        XCTAssertEqual((prepared.text as NSString).substring(with: match), newline.query)
        let snapshot = PreviewSearchSnapshot(file: "a.txt", source: source, prepared: prepared)
        XCTAssertEqual(snapshot.document(file: "a.txt", source: source)?.id, prepared.id)
        XCTAssertNil(snapshot.document(file: "b.txt", source: source), "Identical contents must not reuse another file's search state")
        XCTAssertNil(snapshot.document(file: "a.txt", source: "changed"), "A stale buffer must not enable navigation for a new revision")
    }

    @MainActor
    func testSearchNavigationRevealsLastMatchAndCancelsChangedQuery() async throws {
        _ = NSApplication.shared
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let source = "needle first\n" + (1..<99_999).map { "line \($0)" }.joined(separator: "\n") + "\nneedle last"
        let document = PreparedCodeDocument.prepare(source, fontName: font.fontName, cellWidth: 8)
        let scroll = NativeTextSurface.makeScrollView()
        let container = CodePreviewContainer(scroll: scroll)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        container.setFrameSize(NSSize(width: 700, height: 300)); container.layoutSubtreeIfNeeded()
        let coordinator = NativeTextSurface.Coordinator(); coordinator.attach(scroll)
        defer { coordinator.detach() }
        coordinator.update(document, language: "txt", search: "needle")
        let view = try XCTUnwrap(scroll.documentView as? NSTextView)
        let target = (document.text as NSString).range(of: "needle", options: [.backwards])
        coordinator.update(document, language: "txt", search: "needle", navigation: .init(file: "test", direction: .previous))
        for _ in 0..<200 {
            if view.selectedRange() == target { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(view.selectedRange(), target)
        XCTAssertGreaterThan(scroll.contentView.bounds.maxY, 99_999 * CodeScrollView.lineHeight)
        coordinator.update(document, language: "txt", search: "needle", navigation: .init(file: "test", direction: .next))
        coordinator.update(document, language: "txt", search: "absent")
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(view.selectedRange(), target, "A cancelled navigation must not change the selection")
    }

    @MainActor
    func testWideDocumentKeepsFirstColumnAfterInitialZeroSizeLayout() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let document = PreparedCodeDocument.prepare("wide_" + String(repeating: "a", count: 1000) + "\nend", fontName: font.fontName, cellWidth: 8)
        let scroll = NativeTextSurface.makeScrollView()
        let coordinator = NativeTextSurface.Coordinator()
        coordinator.attach(scroll)
        defer { coordinator.detach() }
        coordinator.update(document, language: "txt", search: "")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        let container = CodePreviewContainer(scroll: scroll)
        window.contentView = container
        container.setFrameSize(NSSize(width: 700, height: 300))
        container.layoutSubtreeIfNeeded()
        scroll.setFrameSize(NSSize(width: 700, height: 300))
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
        scroll.fitDocument()
        scroll.contentView.scroll(to: .zero)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 1)
    }
    @MainActor
    func testLastLineOfLargeDocumentHasDrawableGlyphsAtExpectedPosition() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let source = (0..<100_000).map { "let value\($0) = \"第\($0)行\"" }.joined(separator: "\n")
        let document = PreparedCodeDocument.prepare(source, fontName: font.fontName, cellWidth: 8)
        let scroll = NativeTextSurface.makeScrollView()
        scroll.setFrameSize(NSSize(width: 700, height: 300))
        let coordinator = NativeTextSurface.Coordinator()
        coordinator.attach(scroll)
        defer { coordinator.detach() }
        coordinator.update(document, language: "swift", search: "")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.textHeight - scroll.contentView.bounds.height))
        coordinator.highlight()
        let view = try XCTUnwrap(scroll.documentView as? NSTextView)
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: try XCTUnwrap(document.offsets.last), length: 10), actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertEqual(rect.minY, 99_999 * 18, accuracy: 2)
        XCTAssertEqual(view.frame.width, scroll.contentView.bounds.width, accuracy: 1)
        XCTAssertFalse(scroll.hasHorizontalScroller)
    }
    @MainActor
    func testSparseLayoutKeepsOutOfOrderJumpsAndNativeSelectionAccurate() throws {
        _ = NSApplication.shared
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let lines = (0..<99_999).map { $0 % 11 == 0 ? "" : "\tlet value\($0) = \"第\($0)行🙂e\u{301}\"" }
        let document = PreparedCodeDocument.prepare(lines.joined(separator: "\n") + "\n", fontName: font.fontName, cellWidth: 8)
        let scroll = NativeTextSurface.makeScrollView()
        scroll.setFrameSize(NSSize(width: 700, height: 300))
        let coordinator = NativeTextSurface.Coordinator()
        coordinator.attach(scroll)
        defer { coordinator.detach() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        let preview = CodePreviewContainer(scroll: scroll)
        window.contentView = preview
        preview.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime(window) {} }
        coordinator.update(document, language: "swift", search: "value")
        let view = try XCTUnwrap(scroll.documentView as? NSTextView)
        let manager = try XCTUnwrap(view.layoutManager)
        let textContainer = try XCTUnwrap(view.textContainer)
        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertTrue(manager.allowsNonContiguousLayout)
        XCTAssertFalse(manager.backgroundLayoutEnabled)
        for index in [99_997, 50_003, 25_001, 75_004, 10, 99_997] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(index) * 18))
            coordinator.highlight()
            let characterRange = NSRange(location: document.offsets[index], length: (lines[index] as NSString).length)
            let glyphs = manager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
            let rect = manager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            XCTAssertGreaterThan(rect.width, 0)
            XCTAssertEqual(rect.minY, CGFloat(index) * 18, accuracy: 1, "Wrong row after jump to \(index)")
            let native = view.string as NSString
            let selected = NSRange(location: document.offsets[index], length: document.offsets[index + 2] - document.offsets[index])
            view.setSelectedRange(selected)
            XCTAssertEqual(view.selectedRange(), selected)
            XCTAssertEqual(native.substring(with: selected), lines[index] + "\n" + lines[index + 1] + "\n")
        }
        XCTAssertLessThan(manager.firstUnlaidCharacterIndex(), document.offsets[25_000], "A distant jump must leave preceding paragraphs unlaid")
        XCTAssertEqual(manager.extraLineFragmentRect.minY, 99_999 * 18, accuracy: 1)
        // Explicit insertion-point reveals use the same path as native key
        // events; read-only NSTextView movement commands can scroll without
        // changing selectedRange when invoked directly by a test host.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.scrollRangeToVisible(view.selectedRange())
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
        view.setSelectedRange(NSRange(location: (document.text as NSString).length, length: 0))
        view.scrollRangeToVisible(view.selectedRange())
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 99_900 * 18)
        view.moveToBeginningOfDocument(nil)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
        view.moveToEndOfDocument(nil)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 99_900 * 18)
        view.moveToBeginningOfDocument(nil)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
        // Copy must include paragraphs that have never been laid out, without
        // touching the user's clipboard or reducing selection to the viewport.
        view.selectAll(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: (document.text as NSString).length))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
        XCTAssertTrue(pasteboard.string(forType: .string) == document.text, "Copy must include the full prepared document")
        // Changing document invalidates geometry, temporary colors and selection.
        let replacement = PreparedCodeDocument.prepare("let 短 = \"🙂\"\nend", fontName: font.fontName, cellWidth: 8)
        coordinator.update(replacement, language: "swift", search: "")
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
        XCTAssertEqual(view.string, replacement.text)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
    }

    @MainActor
    func testUnicodeAndWindowsLineEndingsKeepNativeSelectionOffsets() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let document = PreparedCodeDocument.prepare("中文🙂\r\n\tvalue\rfinal\u{2028}next\u{2029}last", fontName: font.fontName, cellWidth: 8)
        XCTAssertEqual(document.text, "中文🙂\n\tvalue\nfinal\nnext\nlast")
        let source = document.text as NSString
        XCTAssertEqual(source.substring(from: document.offsets[1]), "\tvalue\nfinal\nnext\nlast")
        XCTAssertEqual(source.substring(from: document.offsets[2]), "final\nnext\nlast")
        XCTAssertEqual(document.offsets.count, 5)
        XCTAssertGreaterThan(document.width, 0)
        XCTAssertFalse(document.shortenedLines)
    }

    @MainActor
    func testSharedMeasurementMatchesIndependentUnicodeShaping() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let cell = ("0" as NSString).size(withAttributes: [.font: font]).width
        let samples = ["中文🙂", "\t中文\tvalue", "e\u{301} → العربية", "👨‍👩‍👧‍👦 café", "\t\tlet 界 = 1", "", String(repeating: "界", count: 12_000)]
        let document = PreparedCodeDocument.prepare(samples.joined(separator: "\r\n"), fontName: font.fontName, cellWidth: cell)
        XCTAssertTrue(document.shortenedLines)
        XCTAssertEqual(document.offsets.count, samples.count)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []; paragraph.defaultTabInterval = cell * 4
        let ctFont = CTFontCreateWithName(font.fontName as CFString, 13, nil)
        var expected: CGFloat = 0
        for line in document.text.components(separatedBy: "\n") {
            let attributed = NSAttributedString(string: line, attributes: [.font: ctFont, .paragraphStyle: paragraph])
            let width = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil))
            expected = max(expected, width)
        }
        XCTAssertEqual(document.width, ceil(expected), accuracy: 1)
        // Check each short line too: a single very wide line must not mask an
        // incorrect source range after CRLF normalization or a surrogate pair.
        for line in samples.dropLast() {
            let independent = PreparedCodeDocument.prepare(line, fontName: font.fontName, cellWidth: cell)
            let afterPrefix = PreparedCodeDocument.prepare("🙂\n" + line, fontName: font.fontName, cellWidth: cell)
            let emoji = PreparedCodeDocument.prepare("🙂", fontName: font.fontName, cellWidth: cell)
            XCTAssertEqual(afterPrefix.width, max(emoji.width, independent.width), accuracy: 1)
        }
    }

    @MainActor
    func testMeasurementChunkBoundariesKeepLongestLineAndNativeOffsets() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let cell = ("0" as NSString).size(withAttributes: [.font: font]).width
        var lines = Array(repeating: "短🙂", count: 600)
        lines[31] = "\tالعربية עברית e\u{301} 👨‍👩‍👧‍👦"
        lines[32] = String(repeating: "界", count: 2000)
        lines[33] = "\u{2067}עברית\u{2069}\t中文🙂"
        lines[256] = String(repeating: "界", count: 1000)
        lines[257] = String(repeating: "a", count: 32_000)
        lines[258] = String(repeating: "b", count: 32_000)
        lines[259] = String(repeating: "c", count: 32_000)
        lines[512] = "\t" + String(repeating: "宽🙂", count: 2000)
        let document = PreparedCodeDocument.prepare(lines.joined(separator: "\n"), fontName: font.fontName, cellWidth: cell)
        let expected = lines.map { PreparedCodeDocument.prepare($0, fontName: font.fontName, cellWidth: cell).width }.max()!
        XCTAssertEqual(document.width, expected, accuracy: 1)
        let native = document.text as NSString
        for index in [31, 32, 33, 255, 256, 257, 259, 512, 599] {
            XCTAssertEqual(native.substring(with: NSRange(location: document.offsets[index], length: (lines[index] as NSString).length)), lines[index])
        }
    }

    @MainActor
    func testConcurrentPreparationsKeepIndependentWidthsAndCancelledResultEmpty() async {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let name = font.fontName
        let cell = ("0" as NSString).size(withAttributes: [.font: font]).width
        let short = Array(repeating: "界🙂", count: 1024).joined(separator: "\n")
        let wide = Array(repeating: "\t中文🙂e\u{301} → العربية", count: 1024).joined(separator: "\r\n")
        let first = Task.detached { PreparedCodeDocument.prepare(short, fontName: name, cellWidth: cell) }
        let second = Task.detached { PreparedCodeDocument.prepare(wide, fontName: name, cellWidth: cell) }
        let gate = AsyncStream<Void>.makeStream()
        let cancelled = Task.detached {
            for await _ in gate.stream {}
            return PreparedCodeDocument.prepare(wide, fontName: name, cellWidth: cell)
        }
        cancelled.cancel(); gate.continuation.finish()
        let (one, two, discarded) = await (first.value, second.value, cancelled.value)
        let expectedOne = PreparedCodeDocument.prepare("界🙂", fontName: name, cellWidth: cell)
        let expectedTwo = PreparedCodeDocument.prepare("\t中文🙂e\u{301} → العربية", fontName: name, cellWidth: cell)
        XCTAssertEqual(one.width, expectedOne.width)
        XCTAssertEqual(two.width, expectedTwo.width)
        XCTAssertEqual(one.offsets.count, 1024)
        XCTAssertEqual(two.offsets.count, 1024)
        XCTAssertFalse(two.text.contains("\r"))
        XCTAssertTrue(discarded.text.isEmpty)
        XCTAssertTrue(discarded.offsets.isEmpty)
    }

    @MainActor
    func testFractionalScrollingKeepsColorsAndSearchLanguageChangesRefreshSameRows() throws {
        _ = NSApplication.shared
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let source = "let 值 = 1\n/*\nlet 注释 = 2\n*/\n" + Array(repeating: "let 尾 = 3", count: 100).joined(separator: "\n")
        let document = PreparedCodeDocument.prepare(source, fontName: font.fontName, cellWidth: 8, language: "swift")
        let scroll = NativeTextSurface.makeScrollView()
        let container = CodePreviewContainer(scroll: scroll)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        container.setFrameSize(NSSize(width: 700, height: 300)); container.layoutSubtreeIfNeeded()
        let coordinator = NativeTextSurface.Coordinator(); coordinator.attach(scroll)
        defer { coordinator.detach(); withExtendedLifetime(window) {} }
        let view = try XCTUnwrap(scroll.documentView as? NSTextView)
        let manager = try XCTUnwrap(view.layoutManager)
        let value = (document.text as NSString).range(of: "值").location
        let number = (document.text as NSString).range(of: "1").location
        func color(_ attribute: NSAttributedString.Key, _ index: Int) -> NSColor? {
            manager.temporaryAttribute(attribute, atCharacterIndex: index, effectiveRange: nil) as? NSColor
        }
        coordinator.update(document, language: "swift", search: "值")
        for tick in 0..<24 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(tick % 8) / 4))
            coordinator.highlight()
            XCTAssertEqual(color(.foregroundColor, 0), SyntaxPalette.keyword)
            XCTAssertEqual(color(.foregroundColor, document.offsets[2]), SyntaxPalette.comment)
            XCTAssertNotNil(color(.backgroundColor, value))
        }
        coordinator.update(document, language: "swift", search: "1")
        XCTAssertNil(color(.backgroundColor, value), "An unchanged viewport must still remove the old query")
        XCTAssertNotNil(color(.backgroundColor, number))
        coordinator.update(document, language: "txt", search: "")
        XCTAssertEqual(color(.foregroundColor, 0), NSColor.labelColor)
        XCTAssertEqual(color(.foregroundColor, document.offsets[2]), NSColor.labelColor)
        XCTAssertNil(color(.backgroundColor, number))
        view.appearance = NSAppearance(named: .darkAqua)
        coordinator.update(document, language: "swift", search: "")
        XCTAssertEqual(color(.foregroundColor, 0), SyntaxPalette.keyword)
        view.appearance = NSAppearance(named: .aqua)
        coordinator.highlight()
        XCTAssertEqual(color(.foregroundColor, 0), SyntaxPalette.keyword)
        XCTAssertEqual(view.string, document.text)
    }

    @MainActor
    func testViewportGrowthColorsNewlyVisibleLinesWithoutScrolling() async throws {
        _ = NSApplication.shared
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let document = PreparedCodeDocument.prepare(Array(repeating: "let value = 1", count: 200).joined(separator: "\n"), fontName: font.fontName, cellWidth: 8)
        let scroll = NativeTextSurface.makeScrollView()
        let coordinator = NativeTextSurface.Coordinator()
        coordinator.attach(scroll)
        defer { coordinator.detach() }
        let container = CodePreviewContainer(scroll: scroll)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        container.setFrameSize(NSSize(width: 700, height: 120))
        container.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        coordinator.update(document, language: "swift", search: "")
        let view = try XCTUnwrap(scroll.documentView as? NSTextView)
        let manager = try XCTUnwrap(view.layoutManager)
        let offset = document.offsets[20]
        XCTAssertNil(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: offset, effectiveRange: nil))
        container.setFrameSize(NSSize(width: 700, height: 600))
        container.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
        // Resize and scroll notifications coalesce until AppKit finishes its
        // geometry transaction; wait for the actual asynchronous repaint.
        for _ in 0..<100 {
            if manager.temporaryAttribute(.foregroundColor, atCharacterIndex: offset, effectiveRange: nil) != nil { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let color = try XCTUnwrap(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: offset, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(color, SyntaxPalette.keyword)
    }

    @MainActor
    func testNativePreviewStaysInsidePaneAndOnlyWideCodeScrollsHorizontally() {
        let scroll = CodeScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
        scroll.documentView = NSTextView(frame: .zero)
        scroll.textWidth = 180; scroll.textHeight = 5000
        scroll.fitDocument()
        XCTAssertEqual(scroll.documentView?.frame.width, scroll.contentView.bounds.width)
        XCTAssertEqual(scroll.frame.size, NSSize(width: 700, height: 300))
        scroll.textWidth = 3000; scroll.fitDocument()
        XCTAssertEqual(scroll.documentView?.frame.width, 3000)
        XCTAssertEqual(scroll.frame.width, 700)
        scroll.setFrameSize(NSSize(width: 400, height: 200)); scroll.textWidth = 180; scroll.fitDocument()
        XCTAssertEqual(scroll.documentView?.frame.width, scroll.contentView.bounds.width)
    }

    func testReaderSeparatesEmptyBinaryAndReadErrors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".preview-states-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sample")
        try Data().write(to: file)
        XCTAssertEqual(FilePreviewReader.read(path: file.path).kind, .empty)
        try Data([0, 1, 2, 3]).write(to: file)
        XCTAssertEqual(FilePreviewReader.read(path: file.path).kind, .binary)
        XCTAssertEqual(FilePreviewReader.read(path: directory.path).kind, .binary)
        if case .unreadable = FilePreviewReader.read(path: directory.appendingPathComponent("missing").path).kind {} else {
            XCTFail("Missing files should show a read error, not source code")
        }
    }
}

import XCTest
import AppKit
@testable import CodeFlightApp

@MainActor
final class MultilineSyntaxTests: XCTestCase {
    private func color(_ needle: String, in text: String, language: String) -> NSColor? {
        let index = CodeSyntaxIndex.prepare(text, language: language)
        let source = text as NSString
        let target = source.range(of: needle)
        let lineRange = source.lineRange(for: target)
        let line = source.substring(with: lineRange)
        let value = SyntaxHighlighter.attributed(line, language: language, protectedTokens: index.tokens(in: lineRange))
        return value.attribute(.foregroundColor, at: target.location - lineRange.location, effectiveRange: nil) as? NSColor
    }

    func testBlockCommentContextAndNestedSwiftComments() {
        let text = "let a = \"/* string */\"\n/* outer\n let 值42 = 12 /* nested */\n still comment\n*/ let after = 42"
        XCTAssertEqual(color("/* string", in: text, language: "swift"), SyntaxPalette.string)
        XCTAssertEqual(color("let 值42", in: text, language: "swift"), SyntaxPalette.comment)
        XCTAssertEqual(color("still comment", in: text, language: "swift"), SyntaxPalette.comment)
        XCTAssertEqual(color("let after", in: text, language: "swift"), SyntaxPalette.keyword)
        let c = "/* first /* nested */ int value = 1;"
        XCTAssertEqual(color("int value", in: c, language: "c"), SyntaxPalette.keyword)
    }

    func testMultilineStringsShieldCommentMarkersAndResumeCode() {
        for (language, text, inside, after) in [
            ("py", "text = \"\"\"start\n# not comment 42\n\"\"\"; return 1", "# not", "return"),
            ("swift", "let text = \"\"\"\n// not comment 42\n\"\"\"; let after = 1", "// not", "let after"),
            ("go", "var text = `start\n// not comment 42\n`; var after = 1", "// not", "var after"),
            ("ts", "const text = `start\n/* not comment 42 */\n`; const after = 1", "/* not", "const after"),
            ("sql", "SELECT 'it''s\n-- not comment 42\n'; SELECT 1", "-- not", "; SELECT")
        ] {
            XCTAssertEqual(color(inside, in: text, language: language), SyntaxPalette.string, language)
            let offset = after.hasPrefix(";") ? "SELECT 1" : after
            XCTAssertEqual(color(offset, in: text, language: language), SyntaxPalette.keyword, language)
        }
    }

    func testRawSwiftDelimiterAndEscapesDoNotLoseState() {
        let text = "let s = #\"\"\"\n\"\"\" // still raw\n\\#\"quoted\n\"\"\"#; let after = 1"
        XCTAssertEqual(color("// still", in: text, language: "swift"), SyntaxPalette.string)
        XCTAssertEqual(color("quoted", in: text, language: "swift"), SyntaxPalette.string)
        XCTAssertEqual(color("let after", in: text, language: "swift"), SyntaxPalette.keyword)
        let regular = "let s = \"escaped \\\" // string\"; let after = 1 // real"
        XCTAssertEqual(color("// string", in: regular, language: "swift"), SyntaxPalette.string)
        XCTAssertEqual(color("let after", in: regular, language: "swift"), SyntaxPalette.keyword)
        XCTAssertEqual(color("// real", in: regular, language: "swift"), SyntaxPalette.comment)
    }

    func testFarViewportInsideUnterminatedCommentUsesIndexedUTF16Offsets() throws {
        let text = "let 🙂 = 1\n/* begin\n" + String(repeating: "中文🙂 let value = 42\n", count: 10_000)
        let document = PreparedCodeDocument.prepare(text, fontName: "Menlo", cellWidth: 8, language: "swift")
        let index = try XCTUnwrap(document.syntax)
        let start = document.offsets[9999], end = document.offsets[10000] - 1
        let lineRange = NSRange(location: start, length: end - start)
        let tokens = index.tokens(in: lineRange)
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens.first?.range, NSRange(location: 0, length: end - start))
        XCTAssertEqual(tokens.first?.kind, .comment)
        XCTAssertEqual(index.tokens.count, 1)
        let attributed = SyntaxHighlighter.attributed((document.text as NSString).substring(with: lineRange), language: "swift", search: "42", protectedTokens: tokens)
        XCTAssertEqual(attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, SyntaxPalette.comment)
        XCTAssertNotNil(attributed.attribute(.backgroundColor, at: attributed.length - 2, effectiveRange: nil))
    }

    func testCacheAndNativeViewportKeepContextAfterDistantJumpAndReplacement() async throws {
        _ = NSApplication.shared
        let cache = PreparedPreviewCache()
        let source = "/* start\n" + String(repeating: "let masked = 42\n", count: 10_000) + "*/ let end = 1"
        let prepared = await cache.document(file: "fixture.swift", source: source, fontName: "Menlo", cellWidth: 8)
        let document = try XCTUnwrap(prepared)
        XCTAssertEqual(document.syntax?.language, "swift")
        let scroll = NativeTextSurface.makeScrollView()
        let coordinator = NativeTextSurface.Coordinator()
        coordinator.attach(scroll)
        defer { coordinator.detach() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        let container = CodePreviewContainer(scroll: scroll)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        coordinator.update(document, language: "swift", search: "")
        let view = try XCTUnwrap(scroll.documentView as? NSTextView)
        let manager = try XCTUnwrap(view.layoutManager)
        for line in [9_999, 3, 5_000] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(line) * CodeScrollView.lineHeight))
            coordinator.highlight()
            XCTAssertEqual(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: document.offsets[line], effectiveRange: nil) as? NSColor, SyntaxPalette.comment)
        }
        let newResult = await cache.document(file: "fixture.swift", source: "let fresh = 42", fontName: "Menlo", cellWidth: 8)
        let replacement = try XCTUnwrap(newResult)
        XCTAssertNotEqual(document.id, replacement.id)
        coordinator.update(replacement, language: "swift", search: "")
        XCTAssertEqual(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor, SyntaxPalette.keyword)
        withExtendedLifetime(window) {}
    }

    func testCancelledIndexPreparationAndUnsupportedLanguage() async {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return CodeSyntaxIndex.prepare(String(repeating: "/*", count: 100_000), language: "swift")
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled.tokens.isEmpty)
        XCTAssertTrue(CodeSyntaxIndex.prepare("/* plain */", language: "txt").tokens.isEmpty)
    }
}

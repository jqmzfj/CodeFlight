import XCTest
import AppKit
@testable import CodeFlightApp

@MainActor
final class SyntaxIdentifierTests: XCTestCase {
    func testDigitsInsideUnicodeAndDollarIdentifiersKeepIdentifierColor() {
        for language in ["swift", "js", "php", "py", "sh"] {
            for identifier in ["值50000", "café42", "cafe\u{301}42", "变量42尾", "🙂42", "name$42", "abc123"] {
                let text = identifier + " = 42"
                let value = SyntaxHighlighter.attributed(text, language: language)
                let source = text as NSString
                for index in 0..<(identifier as NSString).length {
                    XCTAssertEqual(value.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor,
                                   NSColor.labelColor, "\(language): \(identifier)")
                }
                XCTAssertEqual(value.attribute(.foregroundColor, at: source.length - 2, effectiveRange: nil) as? NSColor,
                               SyntaxPalette.number, "Standalone literal must stay colored")
            }
        }
    }

    func testNumberBoundariesDoNotColorAPrefixOfInvalidLiteralOrIdentifier() {
        let text = "12tail 0xFFtail 42值 123_abc 0xFF + 12.5 - 42"
        for language in ["swift", "py"] {
            let value = SyntaxHighlighter.attributed(text, language: language)
            for identifier in ["12tail", "0xFFtail", "42值", "123_abc"] {
                let index = (text as NSString).range(of: identifier).location
                XCTAssertEqual(value.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor, NSColor.labelColor)
            }
            for literal in ["0xFF +", "12.5", "- 42"] {
                let index = (text as NSString).range(of: literal).location + (literal == "- 42" ? 2 : 0)
                XCTAssertEqual(value.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor, SyntaxPalette.number)
            }
        }
    }

    func testXMLTagsAttributesStringsAndCommentsUseEditorPalette() {
        let text = #"<!-- note --> <project artifactId="demo" version="1.2">true</project>"#
        let value = SyntaxHighlighter.attributed(text, language: "xml")
        let source = text as NSString
        XCTAssertEqual(value.attribute(.foregroundColor, at: source.range(of: "<!--").location, effectiveRange: nil) as? NSColor, SyntaxPalette.comment)
        XCTAssertEqual(value.attribute(.foregroundColor, at: source.range(of: "<project").location, effectiveRange: nil) as? NSColor, SyntaxPalette.keyword)
        XCTAssertEqual(value.attribute(.foregroundColor, at: source.range(of: "artifactId").location, effectiveRange: nil) as? NSColor, SyntaxPalette.type)
        XCTAssertEqual(value.attribute(.foregroundColor, at: source.range(of: "\"demo\"").location, effectiveRange: nil) as? NSColor, SyntaxPalette.string)
    }
}

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import CodeFlightApp

@MainActor
final class WorkbenchChromeTests: XCTestCase {
    func testWallpaperIsDownsampledAndMissingOrCancelledLoadClearsImage() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent(".wallpaper-qa-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("wide.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 8192, height: 64, bitsPerComponent: 8, bytesPerRow: 8192 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8192, height: 64))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let backdrop = WorkbenchBackdrop()
        await backdrop.load(file)
        XCTAssertEqual(backdrop.state, .ready(file))
        let representation = try XCTUnwrap(backdrop.image?.representations.first)
        XCTAssertEqual(representation.pixelsWide, 2560)
        XCTAssertLessThanOrEqual(representation.pixelsHigh, 64)
        let missing = folder.appendingPathComponent("missing.png")
        await backdrop.load(missing)
        XCTAssertNil(backdrop.image)
        XCTAssertEqual(backdrop.state, .failed(missing))
        let cancelled = Task { await backdrop.load(file) }
        cancelled.cancel()
        await cancelled.value
        XCTAssertNil(backdrop.image)
        XCTAssertEqual(backdrop.state, .failed(missing))
        await backdrop.load(file)
        XCTAssertEqual(backdrop.state, .ready(file))
        await backdrop.load(nil)
        XCTAssertNil(backdrop.image)
        XCTAssertEqual(backdrop.state, .idle)
    }

    func testSyntaxThemeAdaptsToAppearanceAndRecognizesModernSwift() throws {
        let token = SyntaxHighlighter.attributed("nonisolated actor Store {}", language: "swift")
        XCTAssertEqual(token.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, SyntaxPalette.keyword)
        XCTAssertEqual(token.attribute(.foregroundColor, at: 12, effectiveRange: nil) as? NSColor, SyntaxPalette.keyword)
        var light: NSColor?
        var dark: NSColor?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { light = SyntaxPalette.keyword.usingColorSpace(.sRGB) }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { dark = SyntaxPalette.keyword.usingColorSpace(.sRGB) }
        XCTAssertNotNil(light); XCTAssertNotNil(dark)
        XCTAssertNotEqual(light, dark)
    }

    func testWorkbenchWindowMinimumRestoresAnOvershrunkNativeWindow() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 480),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: .zero)
        let sizing = WorkbenchWindowMinimumSize.SizingView(minimum: NSSize(width: 1120, height: 720))
        host.addSubview(sizing)
        window.contentView = host
        window.orderFront(nil)
        for _ in 0..<100 {
            if window.contentMinSize == NSSize(width: 1120, height: 720) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(window.contentMinSize, NSSize(width: 1120, height: 720))
        let contentSize = window.contentRect(forFrameRect: window.frame).size
        XCTAssertGreaterThanOrEqual(contentSize.width, 1120)
        XCTAssertGreaterThanOrEqual(contentSize.height, 720)
    }
}

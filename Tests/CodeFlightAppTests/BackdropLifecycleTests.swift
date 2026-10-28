import XCTest
import AppKit
@testable import CodeFlightApp

private actor WallpaperDecodeGate {
    private var pending: [URL: CheckedContinuation<CGImage?, Never>] = [:]
    func decode(_ url: URL) async -> CGImage? {
        await withCheckedContinuation { pending[url] = $0 }
    }
    func isWaiting(_ url: URL) -> Bool { pending[url] != nil }
    func finish(_ url: URL, image: CGImage?) { pending.removeValue(forKey: url)?.resume(returning: image) }
}

@MainActor
final class BackdropLifecycleTests: XCTestCase {
    private func wait(_ gate: WallpaperDecodeGate, _ url: URL) async throws {
        for _ in 0..<500 {
            if await gate.isWaiting(url) { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Decode never started")
    }
    private func bitmap() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    func testOldDecodeCannotOverwriteNewImageOrFailureState() async throws {
        let gate = WallpaperDecodeGate()
        let backdrop = WorkbenchBackdrop(decoder: { await gate.decode($0) })
        let first = URL(fileURLWithPath: "/qa-first.png")
        let second = URL(fileURLWithPath: "/qa-second.png")
        let old = Task { await backdrop.load(first) }
        try await wait(gate, first)
        let current = Task { await backdrop.load(second) }
        try await wait(gate, second)
        await gate.finish(second, image: try bitmap())
        await current.value
        XCTAssertEqual(backdrop.state, .ready(second))
        let image = try XCTUnwrap(backdrop.image)
        // Simulate a decoder that finishes despite cancellation.
        await gate.finish(first, image: nil)
        await old.value
        XCTAssertTrue(backdrop.image === image)
        XCTAssertEqual(backdrop.state, .ready(second))
        let lateSuccess = Task { await backdrop.load(first) }
        try await wait(gate, first)
        let currentFailure = Task { await backdrop.load(second) }
        try await wait(gate, second)
        await gate.finish(second, image: nil); await currentFailure.value
        XCTAssertEqual(backdrop.state, .failed(second))
        await gate.finish(first, image: try bitmap()); await lateSuccess.value
        XCTAssertNil(backdrop.image)
        XCTAssertEqual(backdrop.state, .failed(second))
    }

    func testCancelledReplacementKeepsPreviousImageAndPlainInvalidatesPendingDecode() async throws {
        let gate = WallpaperDecodeGate()
        let backdrop = WorkbenchBackdrop(decoder: { await gate.decode($0) })
        let first = URL(fileURLWithPath: "/qa-loaded.png")
        let second = URL(fileURLWithPath: "/qa-replacement.png")
        let seed = Task { await backdrop.load(first) }
        try await wait(gate, first)
        await gate.finish(first, image: try bitmap()); await seed.value
        let image = try XCTUnwrap(backdrop.image)
        let cancelled = Task { await backdrop.load(second) }
        try await wait(gate, second)
        XCTAssertTrue(backdrop.image === image, "Keep the old image while decoding")
        cancelled.cancel()
        await gate.finish(second, image: nil); await cancelled.value
        XCTAssertTrue(backdrop.image === image)
        XCTAssertEqual(backdrop.state, .ready(first))
        let pending = Task { await backdrop.load(second) }
        try await wait(gate, second)
        await backdrop.load(nil)
        await gate.finish(second, image: try bitmap()); await pending.value
        XCTAssertNil(backdrop.image)
        XCTAssertEqual(backdrop.state, .idle)
    }
}

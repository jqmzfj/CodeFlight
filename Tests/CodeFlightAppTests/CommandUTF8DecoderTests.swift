import XCTest
@testable import CodeFlightApp

final class CommandUTF8DecoderTests: XCTestCase {
    @MainActor
    func testRealPipeReadsPreserveSplitScalarsInLiveOutput() async {
        let sink = StreamSink()
        let cwd = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
        let result = await CommandRunner.run(command: "printf '\\344'; sleep 0.05; printf '\\270'; sleep 0.05; printf '\\255\\346\\226\\207'", cwd: cwd) { sink.append($0) }
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "中文")
        XCTAssertEqual(sink.text, "中文")
    }

    func testChineseEmojiAndCombiningTextSurviveEveryByteBoundary() {
        let source = "启动成功 🚀 café e\u{301} 中文\n"
        let bytes = Array(source.utf8)
        for boundary in 0...bytes.count {
            var decoder = CommandUTF8Decoder()
            let text = decoder.decode(Data(bytes[..<boundary])) + decoder.decode(Data(bytes[boundary...]), final: true)
            XCTAssertEqual(text, source, "boundary \(boundary)")
        }
        var decoder = CommandUTF8Decoder()
        var text = ""
        for byte in bytes { text += decoder.decode(Data([byte])) }
        text += decoder.decode(Data(), final: true)
        XCTAssertEqual(text, source)
    }

    func testMalformedBytesAndIncompleteEOFUseReplacementWithoutLosingFollowingText() {
        let bytes: [UInt8] = [0xFF, 0x41, 0xE4, 0xB8]
        var decoder = CommandUTF8Decoder()
        let text = decoder.decode(Data(bytes)) + decoder.decode(Data(), final: true)
        XCTAssertEqual(text, String(decoding: bytes, as: UTF8.self))
        XCTAssertEqual(decoder.decode(Data("next".utf8)), "next")
    }
}

private final class StreamSink: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ text: String) { lock.lock(); value += text; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return value }
}

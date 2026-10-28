import Foundation

/// Pipes can split a scalar between reads. Retain only an incomplete UTF-8
/// suffix (at most three bytes); invalid bytes still use standard replacement.
struct CommandUTF8Decoder {
    private var pending = Data()

    mutating func decode(_ chunk: Data, final: Bool = false) -> String {
        pending.append(chunk)
        var count = pending.count
        if !final, count > 0 {
            let bytes = Array(pending.suffix(4))
            var lead = bytes.count - 1
            while lead > 0 && bytes[lead] & 0xC0 == 0x80 { lead -= 1 }
            let byte = bytes[lead]
            let expected = (0xC2...0xDF).contains(byte) ? 2 : (0xE0...0xEF).contains(byte) ? 3 : (0xF0...0xF4).contains(byte) ? 4 : 0
            let available = bytes.count - lead
            if expected > available { count -= available }
        }
        let text = String(decoding: pending.prefix(count), as: UTF8.self)
        pending = Data(pending.dropFirst(count))
        return text
    }
}

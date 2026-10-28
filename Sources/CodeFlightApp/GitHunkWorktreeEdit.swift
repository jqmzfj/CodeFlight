import Foundation

enum GitHunkWorktreeEdit {
    static let byteLimit = 8 * 1024 * 1024

    /// Splice one reverse hunk into the raw file, preserving its line endings.
    /// Git's clean/smudge conversion must not rewrite unrelated working lines.
    static func reverting(_ hunk: GitDiffDocument.Hunk, in data: Data) -> Data? {
        guard data.count <= byteLimit, let source = String(data: data, encoding: .utf8), !source.contains("\0") else { return nil }
        var lines = source.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for index in lines.indices where index < lines.count - 1 || source.hasSuffix("\n") { lines[index] += "\n" }
        let endings = Set(lines.compactMap { line -> String? in
            if line.hasSuffix("\r\n") { return "\r\n" }
            return line.hasSuffix("\n") ? "\n" : nil
        })
        guard endings.count <= 1 else { return nil }
        let ending = endings.first ?? "\n"
        struct Line { var text: String; var terminated = true }
        var before: [Line] = [], after: [Line] = []
        var previous: Character?
        for line in hunk.lines {
            guard let prefix = line.first else { return nil }
            if prefix == "\\" {
                guard line.hasPrefix("\\ No newline"), let previous else { return nil }
                if previous == " " || previous == "-" { guard !before.isEmpty else { return nil }; before[before.count - 1].terminated = false }
                if previous == " " || previous == "+" { guard !after.isEmpty else { return nil }; after[after.count - 1].terminated = false }
                continue
            }
            let value = Line(text: String(line.dropFirst()))
            switch prefix {
            case " ": before.append(value); after.append(value)
            case "-": before.append(value)
            case "+": after.append(value)
            default: return nil
            }
            previous = prefix
        }
        func rendered(_ values: [Line]) -> [String] {
            values.map { line in
                var value = line.text
                if line.terminated, value.hasSuffix("\r") { value.removeLast() }
                return value + (line.terminated ? ending : "")
            }
        }
        let offset = after.isEmpty ? hunk.newStart : max(0, hunk.newStart - 1)
        guard offset <= lines.count, after.count <= lines.count - offset,
              Array(lines[offset..<(offset + after.count)]) == rendered(after) else { return nil }
        lines.replaceSubrange(offset..<(offset + after.count), with: rendered(before))
        return Data(lines.joined().utf8)
    }
}

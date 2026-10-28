import Foundation

struct GitConflictBlock: Identifiable, Sendable {
    let id: Int
    let range: Range<String.Index>
    let ours: String
    let base: String?
    let theirs: String
}

enum GitConflictChoice { case ours, theirs, oursThenTheirs, theirsThenOurs }

enum GitConflictBlocks {
    /// Read Git's merge, diff3 and zdiff3 markers, including custom marker sizes.
    /// Ranges include marker lines but never adjacent, non-conflicting text.
    static func parse(_ text: String) -> [GitConflictBlock] {
        var blocks: [GitConflictBlock] = []
        var cursor = text.startIndex
        var start: String.Index?
        var oursStart = cursor
        var oursEnd: String.Index?
        var baseStart: String.Index?
        var baseEnd: String.Index?
        var theirsStart: String.Index?
        var width = 0
        while cursor < text.endIndex {
            let newline = text[cursor...].firstIndex(where: { $0 == "\n" || $0 == "\r\n" })
            let lineEnd = newline ?? text.endIndex
            let next = newline.map { text.index(after: $0) } ?? text.endIndex
            let line = text[cursor..<lineEnd]
            if let marker = marker(line) {
                if start == nil {
                    if marker.character == "<" {
                        start = cursor; width = marker.width; oursStart = next
                        oursEnd = nil; baseStart = nil; baseEnd = nil; theirsStart = nil
                    }
                } else {
                    // An ambiguous or nested region must be handled manually.
                    guard marker.width == width, marker.character != "<" else { return [] }
                    switch marker.character {
                    case "|":
                        guard baseStart == nil, theirsStart == nil else { return [] }
                        oursEnd = cursor; baseStart = next
                    case "=":
                        guard theirsStart == nil else { return [] }
                        if baseStart != nil { baseEnd = cursor } else { oursEnd = cursor }
                        theirsStart = next
                    case ">":
                        guard let regionStart = start, let oursEnd, let theirsStart else { return [] }
                        let base: String?
                        if let baseStart, let baseEnd { base = String(text[baseStart..<baseEnd]) } else { base = nil }
                        blocks.append(GitConflictBlock(id: blocks.count, range: regionStart..<next,
                                                       ours: String(text[oursStart..<oursEnd]), base: base,
                                                       theirs: String(text[theirsStart..<cursor])))
                        start = nil
                    default: break
                    }
                }
            }
            cursor = next
        }
        // Do not offer automatic replacement for a partly written conflict.
        return start == nil ? blocks : []
    }

    static func containsMarkers(_ text: String) -> Bool {
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }).contains { marker($0) != nil }
    }

    static func replacing(_ block: GitConflictBlock, choice: GitConflictChoice, in text: String, expected: String) -> String? {
        guard text == expected else { return nil }
        let replacement: String
        switch choice {
        case .ours: replacement = block.ours
        case .theirs: replacement = block.theirs
        case .oursThenTheirs: replacement = block.ours + block.theirs
        case .theirsThenOurs: replacement = block.theirs + block.ours
        }
        var result = text
        result.replaceSubrange(block.range, with: replacement)
        return result
    }

    private static func marker(_ raw: Substring) -> (character: Character, width: Int)? {
        let line = raw.last == "\r" ? raw.dropLast() : raw
        guard let first = line.first, ["<", "|", "=", ">"].contains(first) else { return nil }
        let run = line.prefix { $0 == first }
        guard run.count >= 7 else { return nil }
        let remainder = line.dropFirst(run.count)
        if first == "=" {
            guard remainder.isEmpty else { return nil }
        } else {
            guard remainder.isEmpty || remainder.first == " " else { return nil }
        }
        return (first, run.count)
    }
}

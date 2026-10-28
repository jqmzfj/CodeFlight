import Foundation

struct FileSearchNavigation: Equatable, Sendable {
    enum Direction: Sendable { case next, previous }
    let id = UUID()
    let file: String
    let direction: Direction
}

enum FileSearchNavigator {
    /// Use the same non-overlapping matches as the counter, keeping only the
    /// predecessor/last range rather than allocating an index for every match.
    static func find(_ request: FileSearchRequest, selection: NSRange, direction: FileSearchNavigation.Direction) -> NSRange? {
        guard !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let source = request.content as NSString
        let position = min(source.length, max(0, selection.location == NSNotFound ? 0 : selection.location))
        let end = position + min(max(0, selection.length), source.length - position)
        var remaining = NSRange(location: 0, length: source.length)
        var first: NSRange?
        var previous: NSRange?
        var last: NSRange?
        while remaining.length > 0 {
            if Task.isCancelled { return nil }
            let found = source.range(of: request.query, options: [.caseInsensitive], range: remaining)
            guard found.location != NSNotFound, found.length > 0 else { break }
            if first == nil { first = found }
            switch direction {
            case .next:
                if found.location >= end { return found }
            case .previous:
                if found.location < position { previous = found }
                else if let previous { return previous }
            }
            last = found
            let next = NSMaxRange(found)
            remaining = NSRange(location: next, length: source.length - next)
        }
        guard !Task.isCancelled else { return nil }
        return direction == .next ? first : (previous ?? last)
    }
}

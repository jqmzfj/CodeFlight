import Foundation

struct FilePreviewDocument: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case text, empty, binary, unreadable(String) }
    var text: String
    var kind: Kind = .text
    var truncated = false
}


/// Reads a bounded prefix, including for sparse or multi-gigabyte files.
enum FilePreviewReader {
    static let byteLimit = 2 * 1024 * 1024
    static let fullReadLimit = 8 * 1024 * 1024
    static let streamChunkSize = 1024 * 1024
    static let streamLimit = 32 * 1024 * 1024
    static func readRange(path: String, offset: UInt64, count: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return Data() }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset); return try handle.read(upToCount: count) ?? Data() } catch { return Data() }
    }
    static func fileSize(path: String) -> UInt64 { (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0 }
    static func read(path: String) -> FilePreviewDocument {
        do {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard attributes.isRegularFile == true else { return FilePreviewDocument(text: "", kind: .binary) }
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            if size == 0 { return FilePreviewDocument(text: "", kind: .empty) }
            let readLimit = size <= UInt64(fullReadLimit) ? Int(size) : byteLimit
            let data = try handle.read(upToCount: readLimit + 1) ?? Data()
            guard !data.prefix(8192).contains(0) else { return FilePreviewDocument(text: "", kind: .binary) }
            let truncated = data.count > readLimit
            let text = String(decoding: data.prefix(readLimit), as: UTF8.self)
            return FilePreviewDocument(text: text, truncated: truncated)
        } catch { return FilePreviewDocument(text: "", kind: .unreadable(error.localizedDescription)) }
    }
}

struct FileRevision: Equatable, Sendable {
    let modified: Date?
    let size: UInt64
    let inode: UInt64
    static func read(_ path: String) -> FileRevision? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return FileRevision(modified: attributes[.modificationDate] as? Date,
                            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }
}

actor PreviewCache {
    static let shared = PreviewCache()
    private let capacity = 64 * 1024 * 1024
    private var values: [String: (document: FilePreviewDocument, bytes: Int, revision: FileRevision)] = [:]
    private var order: [String] = []
    private var totalBytes = 0

    func value(for path: String) -> FilePreviewDocument? {
        guard let entry = values[path] else { return nil }
        guard FileRevision.read(path) == entry.revision else {
            values.removeValue(forKey: path)
            order.removeAll { $0 == path }
            totalBytes -= entry.bytes
            return nil
        }
        touch(path)
        return entry.document
    }

    func insert(_ document: FilePreviewDocument, for path: String, revision: FileRevision?) {
        if case .unreadable = document.kind { return }
        guard let revision, FileRevision.read(path) == revision else { return }
        let bytes = document.text.utf8.count
        guard bytes <= capacity else { return }
        if let old = values.removeValue(forKey: path) { totalBytes -= old.bytes }
        values[path] = (document, bytes, revision)
        totalBytes += bytes
        touch(path)
        while totalBytes > capacity || order.count > 32, let oldest = order.first {
            order.removeFirst()
            if let removed = values.removeValue(forKey: oldest) { totalBytes -= removed.bytes }
        }
    }

    private func touch(_ path: String) {
        order.removeAll { $0 == path }
        order.append(path)
    }
}

/// Presentation limits keep minified files from creating an enormous text
/// layout. The source file and the bounded raw preview remain unchanged.
enum PreviewLinePolicy {
    static let maximumLineBytes = 32 * 1024
    static let maximumLines = 100_000
    static let pageSize = 10_000
    static func lines(in text: String) -> [String] {
        let parts = text.split(separator: "\n", maxSplits: maximumLines, omittingEmptySubsequences: false)
        var lines: [String] = []
        lines.reserveCapacity(min(parts.count, maximumLines) + 1)
        for part in parts.prefix(maximumLines) {
            if Task.isCancelled { return [] }
            if part.utf8.count > maximumLineBytes {
                lines.append(String(decoding: part.utf8.prefix(maximumLineBytes), as: UTF8.self) + " … [本行过长，仅预览前 32 KB / Long line: first 32 KB]")
            } else { lines.append(String(part)) }
        }
        if parts.count > maximumLines { lines.append("// 行数过多，仅预览前 100,000 行 / Preview limited to 100,000 lines") }
        return lines
    }
}

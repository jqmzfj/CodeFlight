import Foundation

struct GitDiffDocument: Sendable {
    struct Hunk: Identifiable, Sendable {
        let id: Int
        let header: String
        let oldStart: Int
        let newStart: Int
        let lines: [String]
    }
    let source: String
    let header: [String]
    let hunks: [Hunk]
    let supportsPartialIndex: Bool

    init(_ content: String) {
        source = content
        var lines = content.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        // Keep parsing usable even if Foundation rejects a future pattern
        // change. A missing matcher simply produces a document without hunks.
        let pattern = try? NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)
        var prefix: [String] = []
        var blocks: [Hunk] = []
        var currentHeader: String?
        var old = 0; var new = 0; var body: [String] = []
        for line in lines {
            let source = line as NSString
            if let match = pattern?.firstMatch(in: line, range: NSRange(location: 0, length: source.length)) {
                if let currentHeader { blocks.append(Hunk(id: blocks.count, header: currentHeader, oldStart: old, newStart: new, lines: body)) }
                currentHeader = line
                old = Int(source.substring(with: match.range(at: 1))) ?? 0
                new = Int(source.substring(with: match.range(at: 3))) ?? 0
                body = []
            } else if currentHeader == nil { prefix.append(line) }
            else { body.append(line) }
        }
        if let currentHeader { blocks.append(Hunk(id: blocks.count, header: currentHeader, oldStart: old, newStart: new, lines: body)) }
        header = prefix; hunks = blocks
        supportsPartialIndex = prefix.filter { $0.hasPrefix("diff --git ") }.count == 1 && prefix.contains(where: { $0.hasPrefix("--- a/") || $0.hasPrefix("--- \"a/") }) && prefix.contains(where: { $0.hasPrefix("+++ b/") || $0.hasPrefix("+++ \"b/") }) && !prefix.contains(where: { $0.hasPrefix("new file") || $0.hasPrefix("deleted file") || $0.hasPrefix("old mode") || $0.hasPrefix("new mode") || $0.hasPrefix("rename ") || $0.contains("Binary files") || $0.hasPrefix("…") }) && !blocks.isEmpty && blocks.allSatisfy { $0.lines.allSatisfy { $0.hasPrefix(" ") || $0.hasPrefix("+") || $0.hasPrefix("-") || $0.hasPrefix("\\ No newline") } }
    }

    func patch(hunk index: Int) -> String? {
        guard supportsPartialIndex, hunks.indices.contains(index) else { return nil }
        return (header + [hunks[index].header] + hunks[index].lines).joined(separator: "\n") + "\n"
    }
}

struct GitSplitDiffRow: Identifiable, Sendable {
    let id: Int
    let oldLine: Int?
    let newLine: Int?
    let oldText: String?
    let newText: String?
    let changed: Bool
    static func rows(_ hunk: GitDiffDocument.Hunk) -> [GitSplitDiffRow] {
        var rows: [GitSplitDiffRow] = []
        var old = hunk.oldStart; var new = hunk.newStart
        var removed: [(Int, String)] = []; var added: [(Int, String)] = []
        func flush() {
            for index in 0..<max(removed.count, added.count) {
                let left = removed.indices.contains(index) ? removed[index] : nil
                let right = added.indices.contains(index) ? added[index] : nil
                rows.append(.init(id: rows.count, oldLine: left?.0, newLine: right?.0, oldText: left?.1, newText: right?.1, changed: true))
            }
            removed = []; added = []
        }
        for line in hunk.lines {
            if line.hasPrefix("-") { removed.append((old, String(line.dropFirst()))); old += 1 }
            else if line.hasPrefix("+") { added.append((new, String(line.dropFirst()))); new += 1 }
            else if line.hasPrefix(" ") {
                flush()
                let text = String(line.dropFirst())
                rows.append(.init(id: rows.count, oldLine: old, newLine: new, oldText: text, newText: text, changed: false))
                old += 1; new += 1
            }
        }
        flush(); return rows
    }
}

extension GitService {
    static func discardWorktreeHunk(file: String, hunk: Int, expectedDiff: String, at path: String) async -> CommandResult {
        guard !file.isEmpty, !file.hasPrefix("/"), !file.split(separator: "/").contains(where: { $0 == ".." || $0.lowercased() == ".git" }) else {
            return CommandResult(output: "文件路径无效。 / Invalid file path.", status: 1)
        }
        let fileURL = URL(fileURLWithPath: path).appendingPathComponent(file)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path), attributes[.type] as? FileAttributeType == .typeRegular else {
            return CommandResult(output: "仅普通文本文件支持按块回滚。 / Hunk revert requires a regular text file.", status: 1)
        }
        let current = await diff(file, at: path)
        guard current == expectedDiff else { return CommandResult(output: "差异已改变，未回滚文件。请刷新后重试。 / The diff changed. Nothing was reverted. Refresh and retry.", status: 1) }
        let document = GitDiffDocument(current)
        guard document.supportsPartialIndex, document.hunks.indices.contains(hunk) else {
            return CommandResult(output: "此差异不支持按块回滚，请按文件操作。 / Hunk revert is unavailable for this diff.", status: 1)
        }
        let filters = await CommandRunner.run(command: "git --literal-pathspecs check-attr -z filter working-tree-encoding -- \(Shell.quote(file))", cwd: path)
        let fields = filters.output.split(separator: "\0", omittingEmptySubsequences: false)
        guard filters.status == 0, !filters.truncated, fields.count == 7, fields[1] == "filter", fields[4] == "working-tree-encoding",
              stride(from: 2, to: fields.count - 1, by: 3).allSatisfy({ fields[$0] == "unspecified" || fields[$0] == "unset" }) else {
            return CommandResult(output: "此文件使用了内容过滤或编码转换，请按文件操作。 / This file uses content filters or encoding conversion; use file actions.", status: 1)
        }
        return await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let limit = GitHunkWorktreeEdit.byteLimit
            guard let info = try? fm.attributesOfItem(atPath: fileURL.path), info[.type] as? FileAttributeType == .typeRegular,
                  (info[.size] as? NSNumber)?.intValue ?? Int.max <= limit else {
                return CommandResult(output: "按块回滚仅支持不超过 8 MB 的普通 UTF-8 文件。 / Hunk revert supports regular UTF-8 files up to 8 MB.", status: 1)
            }
            let original = FilePreviewReader.readRange(path: fileURL.path, offset: 0, count: limit + 1)
            guard original.count == (info[.size] as? NSNumber)?.intValue,
                  let updated = GitHunkWorktreeEdit.reverting(document.hunks[hunk], in: original) else {
                return CommandResult(output: "磁盘内容与差异不一致，或文件含混合换行。未修改文件，请刷新或使用外部工具。 / Disk content differs from the diff or uses mixed line endings. Nothing was changed; refresh or use an external tool.", status: 1)
            }
            guard await GitService.diff(file, at: path) == expectedDiff else {
                return CommandResult(output: "差异或暂存内容已改变，未回滚。请刷新。 / The diff or index changed. Nothing was reverted; refresh.", status: 1)
            }
            guard let latest = try? fm.attributesOfItem(atPath: fileURL.path), latest[.type] as? FileAttributeType == .typeRegular,
                  (latest[.size] as? NSNumber)?.intValue ?? Int.max <= limit,
                  FilePreviewReader.readRange(path: fileURL.path, offset: 0, count: limit + 1) == original else {
                return CommandResult(output: "磁盘文件已改变，未回滚。请刷新。 / The disk file changed. Nothing was reverted; refresh.", status: 1)
            }
            do {
                try updated.write(to: fileURL, options: .atomic)
                if let permissions = latest[.posixPermissions] { try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: fileURL.path) }
                return CommandResult(output: "", status: 0)
            } catch { return CommandResult(output: error.localizedDescription, status: 1) }
        }.value
    }

    static func applyIndexHunk(file: String, hunk: Int, staged: Bool, expectedDiff: String, at path: String) async -> CommandResult {
        let current = await diff(file, at: path, staged: staged)
        guard current == expectedDiff else { return CommandResult(output: "差异已被其他操作改变，请刷新后重试。 / The diff changed. Refresh before applying this hunk.", status: 1) }
        let document = GitDiffDocument(current)
        guard let patch = document.patch(hunk: hunk) else { return CommandResult(output: "此差异不支持按块暂存，请按文件操作。 / Use file staging for this diff.", status: 1) }
        let directory = await CommandRunner.run(command: "git rev-parse --absolute-git-dir", cwd: path)
        guard directory.status == 0 else { return directory }
        let url = URL(fileURLWithPath: directory.output.trimmingCharacters(in: .whitespacesAndNewlines)).appendingPathComponent("git-workbench-patch-" + UUID().uuidString)
        do { try Data(patch.utf8).write(to: url, options: .withoutOverwriting) }
        catch { return CommandResult(output: error.localizedDescription, status: 1) }
        defer { try? FileManager.default.removeItem(at: url) }
        let command = "git apply --cached \(staged ? "--reverse " : "")"
        return await CommandRunner.run(command: "\(command)--check -- \(Shell.quote(url.path)) && \(command)-- \(Shell.quote(url.path))", cwd: path)
    }
}

struct GitDiffReadingLocation: Equatable, Sendable {
    let hunk: Int
    let oldLine: Int?
    let newLine: Int?
}

struct GitDiffDisplayRow: Identifiable, Sendable {
    enum Content: Sendable { case header(String), split(GitSplitDiffRow), unified(String) }
    let id: String
    let hunk: Int
    let content: Content
    let location: GitDiffReadingLocation
}

struct GitDiffPresentation: Sendable {
    let document: GitDiffDocument
    let splitRows: [GitDiffDisplayRow]
    let unifiedRows: [GitDiffDisplayRow]
    init(_ source: String) {
        let document = GitDiffDocument(source)
        self.document = document
        var split: [GitDiffDisplayRow] = []; var unified: [GitDiffDisplayRow] = []
        for hunk in document.hunks {
            let header = GitDiffDisplayRow(id: "h\(hunk.id)-header", hunk: hunk.id, content: .header(hunk.header), location: .init(hunk: hunk.id, oldLine: nil, newLine: nil))
            split.append(header); unified.append(header)
            split.append(contentsOf: GitSplitDiffRow.rows(hunk).map { .init(id: "h\(hunk.id)-row\($0.id)", hunk: hunk.id, content: .split($0), location: .init(hunk: hunk.id, oldLine: $0.oldLine, newLine: $0.newLine)) })
            var old = hunk.oldStart; var new = hunk.newStart
            var previous = header.location
            for (index, line) in hunk.lines.enumerated() {
                let location: GitDiffReadingLocation
                if line.hasPrefix("-") {
                    location = .init(hunk: hunk.id, oldLine: old, newLine: nil); old += 1
                } else if line.hasPrefix("+") {
                    location = .init(hunk: hunk.id, oldLine: nil, newLine: new); new += 1
                } else if line.hasPrefix(" ") {
                    location = .init(hunk: hunk.id, oldLine: old, newLine: new); old += 1; new += 1
                } else { location = previous }
                unified.append(.init(id: "h\(hunk.id)-row\(index)", hunk: hunk.id, content: .unified(line), location: location))
                previous = location
            }
        }
        splitRows = split; unifiedRows = unified
    }

    func rowID(for location: GitDiffReadingLocation, split: Bool) -> String? {
        let rows = split ? splitRows : unifiedRows
        if let line = location.newLine, let row = rows.first(where: { $0.hunk == location.hunk && $0.location.newLine == line }) {
            return row.id
        }
        if let line = location.oldLine, let row = rows.first(where: { $0.hunk == location.hunk && $0.location.oldLine == line }) {
            return row.id
        }
        return rows.first(where: { $0.hunk == location.hunk })?.id
    }
}

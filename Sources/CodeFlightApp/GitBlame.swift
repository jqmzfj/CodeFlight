import SwiftUI
import AppKit

struct GitBlameTarget: Identifiable {
    let projectID: UUID
    let root: String
    let file: String
    var id: String { projectID.uuidString + file }
}

struct GitBlameLine: Identifiable, Sendable {
    let hash: String
    let originalLine: Int
    let line: Int
    let author: String
    let date: String
    let summary: String
    let path: String
    let content: String
    var id: Int { line }
    var uncommitted: Bool { hash.allSatisfy { $0 == "0" } }
}

struct GitBlameResult: Sendable {
    let lines: [GitBlameLine]
    let error: String?
}

extension GitService {
    static func blame(_ file: String, at root: String, taskID: UUID = UUID(), language: AppLanguage = .chinese) async -> GitBlameResult {
        func failure(_ zh: String, _ en: String) -> GitBlameResult { GitBlameResult(lines: [], error: Copy.t(zh, en, language: language)) }
        let cancelled = failure("读取已取消。", "Read cancelled.")
        guard !Task.isCancelled else { return cancelled }
        let invalid = failure("请选择仓库内的普通文本文件。", "Select a regular text file inside the repository.")
        guard !file.isEmpty, !file.hasPrefix("/"), !file.contains("\0"), !file.split(separator: "/").contains("..") else { return invalid }
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        let url = base.appendingPathComponent(file)
        guard url.resolvingSymlinksInPath().path.hasPrefix(base.path + "/"),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeRegular else { return invalid }
        let validation = Task.detached(priority: .userInitiated) { () -> Bool in
            guard !Task.isCancelled else { return false }
            let data = FilePreviewReader.readRange(path: url.path, offset: 0, count: 1024 * 1024 + 1)
            return blameTextIsSupported(data)
        }
        let bounded = await withTaskCancellationHandler { await validation.value } onCancel: { validation.cancel() }
        guard !Task.isCancelled else { return cancelled }
        guard bounded else { return failure("逐行追溯支持不超过 1 MB、10,000 行的 UTF-8 文本。", "Annotate supports UTF-8 text up to 1 MB and 10,000 lines.") }
        let result = await CancellableGitRead.run(command: "git --literal-pathspecs -c core.quotePath=false --no-pager blame --line-porcelain --no-textconv -- \(Shell.quote(file))", cwd: root, outputLimit: 8 * 1024 * 1024, taskID: taskID, timeoutSeconds: 20)
        guard !Task.isCancelled else { return cancelled }
        guard result.status == 0, !result.truncated else {
            if result.truncated { return failure("追溯结果超过读取限制。", "Annotation exceeds the read limit.") }
            return GitBlameResult(lines: [], error: result.output.isEmpty ? Copy.t("读取追溯失败，请重试。", "Cannot read annotation. Retry.", language: language) : result.output)
        }
        let worker = Task.detached(priority: .userInitiated) { parseBlame(result.output, language: language) }
        let parsed = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return cancelled }
        return parsed
    }

    static func blameTextIsSupported(_ data: Data) -> Bool {
        guard data.count <= 1024 * 1024, !data.contains(0), String(data: data, encoding: .utf8) != nil else { return false }
        let count = data.reduce(0) { $0 + ($1 == 10 ? 1 : 0) } + (data.isEmpty || data.last == 10 ? 0 : 1)
        return count <= 10_000
    }

    static func parseBlame(_ output: String, language: AppLanguage = .chinese) -> GitBlameResult {
        let invalid = GitBlameResult(lines: [], error: Copy.t("无法解析追溯结果。", "Cannot parse annotation.", language: language))
        var lines: [GitBlameLine] = []
        var hash = "", original = 0, number = 0, author = "", date = "", summary = "", path = ""
        for part in output.utf8.split(separator: 10, omittingEmptySubsequences: false) {
            if Task.isCancelled { return GitBlameResult(lines: [], error: Copy.t("读取已取消。", "Read cancelled.", language: language)) }
            let value = String(decoding: part, as: UTF8.self)
            if value.hasPrefix("\t") {
                guard !hash.isEmpty, original > 0, number == lines.count + 1, !path.isEmpty else { return invalid }
                lines.append(GitBlameLine(hash: hash, originalLine: original, line: number, author: author, date: date, summary: summary, path: path, content: String(value.dropFirst())))
                hash = ""
            } else {
                let fields = value.split(separator: " ")
                if fields.count >= 3, [40, 64].contains(fields[0].count), fields[0].allSatisfy(\.isHexDigit), let from = Int(fields[1]), let to = Int(fields[2]) {
                    guard hash.isEmpty else { return invalid }
                    hash = String(fields[0]); original = from; number = to; author = ""; date = ""; summary = ""; path = ""
                } else if value.hasPrefix("author ") { author = String(value.dropFirst(7)) }
                else if value.hasPrefix("author-time "), let seconds = Double(value.dropFirst(12)), seconds.isFinite, abs(seconds) < 253_402_300_800 { date = Date(timeIntervalSince1970: seconds).ISO8601Format().prefix(10).description }
                else if value.hasPrefix("summary ") { summary = String(value.dropFirst(8)) }
                else if value.hasPrefix("filename ") { path = decodeBlamePath(String(value.dropFirst(9))) }
            }
        }
        guard hash.isEmpty, output.isEmpty || !lines.isEmpty else { return invalid }
        return GitBlameResult(lines: lines, error: nil)
    }

    private static func decodeBlamePath(_ value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        let input = Array(value.utf8.dropFirst().dropLast())
        var bytes: [UInt8] = [], i = 0
        let escapes: [UInt8: UInt8] = [97: 7, 98: 8, 116: 9, 110: 10, 118: 11, 102: 12, 114: 13, 34: 34, 92: 92]
        while i < input.count {
            if input[i] != 92 { bytes.append(input[i]); i += 1; continue }
            i += 1
            guard i < input.count else { break }
            if i + 2 < input.count, input[i...i+2].allSatisfy({ (48...55).contains($0) }) {
                let byte = Int(input[i] - 48) * 64 + Int(input[i+1] - 48) * 8 + Int(input[i+2] - 48)
                guard byte <= 255 else { return "" }
                bytes.append(UInt8(byte)); i += 3
            } else { bytes.append(escapes[input[i]] ?? input[i]); i += 1 }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct GitBlameSheet: View {
    @ObservedObject var model: WorkbenchModel
    let target: GitBlameTarget
    @Environment(\.dismiss) private var dismiss
    @State private var result = GitBlameResult(lines: [], error: nil)
    @State private var loading = true
    @State private var request = UUID()
    @State private var selection: Int?
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var selected: GitBlameLine? { result.lines.first { $0.line == selection } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(text("逐行追溯", "Annotate"), systemImage: "person.text.rectangle").font(.system(size: 14, weight: .semibold))
                Text(target.file).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(target.file)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { request = UUID() } label: { Image(systemName: "arrow.clockwise") }.help(text("刷新追溯", "Refresh annotation")).accessibilityLabel(text("刷新追溯", "Refresh annotation")).disabled(loading)
                Button(text("关闭", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(14)
            Divider()
            if loading {
                ProgressView(text("正在读取逐行追溯…", "Reading annotation…")).controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = result.error {
                ScrollView { Text(error).font(.system(.caption, design: .monospaced)).foregroundStyle(.orange).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
            } else {
                WorkbenchSplit("blame.selection", axis: .horizontal, initial: 130, minimum: 96, otherMinimum: 160, resizesSecond: true) {
                List(selection: $selection) {
                    ForEach(result.lines) { line in
                        HStack(spacing: 10) {
                            Text(line.uncommitted ? text("未提交", "Local") : String(line.hash.prefix(8))).foregroundStyle(line.uncommitted ? Color.orange : Color.secondary).frame(width: 75, alignment: .leading)
                            Text(line.uncommitted ? text("本地修改", "Local changes") : line.author).lineLimit(1).frame(width: 95, alignment: .leading)
                            Text(line.uncommitted ? "" : line.date).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
                            Text(String(line.line)).foregroundStyle(.tertiary).frame(width: 38, alignment: .trailing)
                            Text(code(line)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.system(size: 11, design: .monospaced)).frame(height: 23).tag(line.line).listRowSeparator(.hidden).help(line.summary + "\n" + line.content.prefix(4000))
                        .contextMenu {
                            if !line.uncommitted {
                                Button(text("查看提交差异", "Show commit diff")) { showCommit(line) }
                                Button(text("复制完整哈希", "Copy full hash")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(line.hash, forType: .string) }
                            }
                        }
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden)
                .overlay {
                    if result.lines.isEmpty { Text(text("空文件，没有可追溯的行。", "Empty file; no lines to annotate.")).font(.caption).foregroundStyle(.secondary).padding() }
                }
                } second: {
                    lineDetails
                }

            }
            Divider()
            HStack {
                if let selected {
                    Text(text("第 \(selected.line) 行", "Line \(selected.line)") + " · " + (selected.uncommitted ? text("尚未提交", "Uncommitted") : selected.author)).lineLimit(1)
                    Spacer()
                    if !selected.uncommitted { Button(text("查看提交差异", "Show commit diff")) { showCommit(selected) } }
                } else { Text(text("选择一行查看提交信息；内容包含当前本地修改。", "Select a line for commit details; includes current local changes.")); Spacer() }
            }.font(.caption).foregroundStyle(.secondary).padding(12).frame(minHeight: 48)
        }.frame(minWidth: 820, idealWidth: 940, minHeight: 460, idealHeight: 580)
        .resizableSheet(minimumWidth: 820, minimumHeight: 460, language: model.language)
        .task(id: request) {
            let id = request
            loading = true; selection = nil; result = GitBlameResult(lines: [], error: nil)
            let value = await GitService.blame(target.file, at: target.root, taskID: id, language: model.language)
            guard !Task.isCancelled, model.selectedProjectID == target.projectID else { return }
            result = value; selection = value.lines.first?.line; loading = false
        }
        .onDisappear { CommandRunner.stop(taskID: request) }
        .onChange(of: model.selectedProjectID) { _ in dismiss() }
    }
    @ViewBuilder private var lineDetails: some View {
        if let selected {
            VStack(spacing: 0) {
                HStack {
                    Text(text("第 \(selected.line) 行", "Line \(selected.line)")).fontWeight(.medium)
                    Text(selected.uncommitted ? text("本地修改", "Local changes") : String(selected.hash.prefix(8))).foregroundStyle(.secondary)
                    Spacer()
                    Button(text("复制整行", "Copy full line")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(selected.content, forType: .string)
                    }.buttonStyle(.borderless)
                }.font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(selected.uncommitted ? text("此行尚未提交", "This line has not been committed") : selected.summary).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Text(selected.uncommitted ? text("本地修改 · \(selected.path)", "Local changes · \(selected.path)") : selected.author + " · " + selected.date + " · " + selected.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        ScrollView(.horizontal) {
                            Text(AttributedString(SyntaxHighlighter.attributed(String(selected.content.prefix(4000)), language: (target.file as NSString).pathExtension))).font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if selected.content.count > 4000 {
                            Text(text("长行预览显示前 4,000 个字符；“复制整行”保留完整内容。", "Showing the first 4,000 characters; Copy full line keeps the complete content.")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(.horizontal, 12).padding(.bottom, 8)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(text("选择一行查看完整提交说明和代码", "Select a line for its commit message and code")).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func code(_ line: GitBlameLine) -> AttributedString {
        let value = SyntaxHighlighter.attributed(String(line.content.prefix(2000)), language: (target.file as NSString).pathExtension)
        if selection == line.line {
            let selected = NSMutableAttributedString(attributedString: value)
            selected.addAttribute(.foregroundColor, value: NSColor.alternateSelectedControlTextColor, range: NSRange(location: 0, length: selected.length))
            return AttributedString(selected)
        }
        return AttributedString(value)
    }
    private func showCommit(_ line: GitBlameLine) {
        guard !line.uncommitted, model.selectedProjectID == target.projectID else { return }
        dismiss(); model.openCommitDiff(line.hash, file: line.path)
    }
}

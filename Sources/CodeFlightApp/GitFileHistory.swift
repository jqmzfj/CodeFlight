import SwiftUI
import AppKit

struct GitFileHistoryEntry: Identifiable, Sendable {
    let commit: GitCommit
    let path: String
    var id: String { commit.hash }
}

struct GitFileHistoryPage: Sendable {
    let entries: [GitFileHistoryEntry]
    let hasMore: Bool
    let error: String?
    var snapshot: String? = nil
}

extension GitService {
    static func fileHistory(_ file: String, at path: String, skip: Int = 0, limit: Int = 50, snapshot: String? = nil) async -> GitFileHistoryPage {
        let offset = max(0, skip), count = max(1, min(limit, 100))
        if let snapshot, !([40, 64].contains(snapshot.count) && snapshot.allSatisfy(\.isHexDigit)) {
            return GitFileHistoryPage(entries: [], hasMore: false, error: "文件历史快照无效，请刷新。 / Invalid file history snapshot. Refresh and retry.")
        }
        let cancelled = GitFileHistoryPage(entries: [], hasMore: false, error: "读取已取消。 / Read cancelled.")
        guard !Task.isCancelled else { return cancelled }
        let resolved = await CancellableGitRead.run(command: "git rev-parse --verify --end-of-options \(Shell.quote((snapshot ?? "HEAD") + "^{commit}"))", cwd: path)
        guard !Task.isCancelled else { return cancelled }
        let head = resolved.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolved.status == 0, [40, 64].contains(head.count), head.allSatisfy(\.isHexDigit) else {
            // Only a missing local branch ref is an unborn repository. Corrupt
            // refs, detached missing objects and unavailable snapshots are errors.
            if snapshot == nil {
                let branch = await CancellableGitRead.run(command: "git symbolic-ref -q HEAD", cwd: path)
                guard !Task.isCancelled else { return cancelled }
                let reference = branch.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if branch.status == 0, reference.hasPrefix("refs/heads/") {
                    let exists = await CancellableGitRead.run(command: "git show-ref --verify --quiet \(Shell.quote(reference))", cwd: path)
                    guard !Task.isCancelled else { return cancelled }
                    if exists.status == 1 { return GitFileHistoryPage(entries: [], hasMore: false, error: nil) }
                }
            }
            return GitFileHistoryPage(entries: [], hasMore: false, error: "无法读取文件历史起点，请检查仓库或刷新后重试。 / Cannot read the file history starting commit. Check the repository or refresh and retry.")
        }
        // Re-read preceding rename records within the same frozen history so
        // later pages retain paths used before a rename on an earlier page.
        let result = await CancellableGitRead.run(command: "git --literal-pathspecs --no-pager log --follow --name-status -z -n \(offset + count + 1) --date=iso-strict --format='%H%x00%s%x00%an%x00%ad%x00%P%x00%D' \(head) -- \(Shell.quote(file))", cwd: path, outputLimit: 4 * 1024 * 1024)
        guard !Task.isCancelled else { return cancelled }
        guard result.status == 0, !result.truncated else {
            return GitFileHistoryPage(entries: [], hasMore: false, error: result.truncated ? "文件历史超过读取限制。 / File history exceeds the read limit." : result.output)
        }
        let worker = Task.detached(priority: .userInitiated) { parseFileHistory(result.output, file: file) }
        let entries = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return cancelled }
        return GitFileHistoryPage(entries: Array(entries.dropFirst(offset).prefix(count)), hasMore: entries.count > offset + count, error: nil, snapshot: head)
    }

    static func parseFileHistory(_ output: String, file: String) -> [GitFileHistoryEntry] {
        let fields = output.components(separatedBy: "\0")
        var index = 0, currentPath = file
        var entries: [GitFileHistoryEntry] = []
        func isHash(_ value: String) -> Bool { [40, 64].contains(value.count) && value.allSatisfy(\.isHexDigit) }
        while index + 5 < fields.count {
            if Task.isCancelled { return [] }
            guard isHash(fields[index]) else { break }
            let commit = GitCommit(hash: fields[index], subject: fields[index + 1], author: fields[index + 2], date: fields[index + 3], parents: fields[index + 4].split(separator: " ").map(String.init), refs: fields[index + 5].components(separatedBy: ", ").filter { !$0.isEmpty })
            index += 6
            let pathAtCommit = currentPath
            while index < fields.count && !isHash(fields[index]) {
                if Task.isCancelled { return [] }
                let status = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
                index += 1
                if status.isEmpty { continue }
                if status.hasPrefix("R") || status.hasPrefix("C") {
                    guard index + 1 < fields.count else { break }
                    let old = fields[index], new = fields[index + 1]
                    if new == currentPath { currentPath = old }
                    index += 2
                } else {
                    guard index < fields.count else { break }
                    index += 1
                }
            }
            entries.append(GitFileHistoryEntry(commit: commit, path: pathAtCommit))
        }
        return entries
    }
}

struct GitFileHistoryPanel: View {
    @ObservedObject var model: WorkbenchModel
    let file: String
    @StateObject private var history = GitFileHistoryStore()
    @State private var refreshRevision = UUID()
    @State private var pageTask: Task<Void, Never>?
    private enum FocusArea: Hashable { case search, commits }
    @FocusState private var focusedArea: FocusArea?
    private var selected: GitFileHistoryEntry? { history.selected }
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }

    var body: some View {
        WorkbenchSplit("fileHistory", initial: 280, minimum: 220, otherMinimum: 380, resizesSecond: true) {
            VStack(spacing: 0) {
                HStack {
                    Button { model.gitFileHistoryPath = nil } label: { Image(systemName: "chevron.left"); Text(text("仓库历史", "Repository history")) }.buttonStyle(.borderless)
                    Text(file).lineLimit(1).truncationMode(.middle).help(file)
                    Spacer(minLength: 0)
                    Button { refreshRevision = UUID() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help(text("刷新文件历史", "Refresh file history")).accessibilityLabel(text("刷新文件历史", "Refresh file history"))
                }.font(.system(size: 11)).padding(.horizontal, 10).frame(height: WorkbenchChrome.rowHeight)
                Divider()
                TextField(text("搜索已加载的提交、作者、哈希或路径", "Search loaded commits, author, hash or path"), text: $history.search)
                    .textFieldStyle(.roundedBorder).controlSize(.small).padding(.horizontal, 10)
                    .frame(height: WorkbenchChrome.rowHeight)
                    .focused($focusedArea, equals: .search)
                    .onSubmit {
                        history.selectVisibleCommit()
                        if history.selection != nil { focusedArea = .commits }
                    }
                    .onExitCommand { history.search = "" }
                    .accessibilityLabel(text("筛选文件历史", "Filter file history"))
                    .accessibilityHint(text("回车进入提交列表，Esc 清空筛选。", "Return enters the commit list. Escape clears the filter."))
                Divider()
                List(selection: $history.selection) {
                    ForEach(history.visible) { entry in
                        HStack(spacing: 8) {
                            Text(entry.commit.subject).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(entry.commit.author).foregroundStyle(.secondary).lineLimit(1).frame(width: 80, alignment: .leading)
                            Text(String(entry.commit.hash.prefix(8))).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }.font(.system(size: 11)).frame(height: GitGraphCell.rowHeight).tag(entry.id).help(entry.commit.subject).contextMenu {
                            Button(text("复制完整哈希", "Copy full hash")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.id, forType: .string) }
                        }
                    }
                }.listStyle(.inset(alternatesRowBackgrounds: false)).scrollContentBackground(.hidden)
                    .focused($focusedArea, equals: .commits)
                    .accessibilityLabel(text("文件提交历史", "File commit history"))
                    .overlay {
                        if !history.loading && history.failure == nil && history.visible.isEmpty {
                            Text(history.search.isEmpty ? text("此文件暂无提交记录", "No commits for this file") : text("没有匹配的已加载提交", "No matching loaded commits"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if let failure = history.failure {
                        ScrollView {
                            Text(failure).font(.system(.caption, design: .monospaced)).foregroundStyle(.orange)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 100)
                    }
                    HStack {
                        Text(text("已加载 \(history.entries.count) 个提交", "\(history.entries.count) commits loaded")).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        if history.loading { ProgressView().controlSize(.mini) }
                        else if history.failure != nil { Button(text("重试", "Retry")) {
                            if history.retryRefresh { refreshRevision = UUID() } else { loadMore() }
                        }.buttonStyle(.borderless) }
                        else if history.hasMore { Button(text("加载更早的提交", "Load older commits")) { loadMore() }.buttonStyle(.borderless) }
                    }.font(.system(size: 11))
                }.padding(.horizontal, 10).padding(.vertical, 5)
            }.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                } second: {
            ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let selected {
                    Text(selected.commit.subject).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                    Text("\(selected.commit.author) · \(selected.commit.date.prefix(10))").font(.caption).foregroundStyle(.secondary)
                    Text(selected.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    if selected.path != file { Text(text("重命名前的路径", "Path before rename")).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button(text("查看此版本差异", "Show revision diff")) { model.openCommitDiff(selected.id, file: selected.path) }.buttonStyle(.borderless)
                } else { Text(text("选择提交查看文件差异", "Select a commit to view the file diff")).font(.caption).foregroundStyle(.secondary); Spacer() }
            }.padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .task(id: "\(model.selectedProjectID?.uuidString ?? "")|\(file)|\(refreshRevision)|\(model.gitFileHistoryRequest)|\(model.gitCommits.map(\.hash).joined(separator: ","))") {
            pageTask?.cancel(); pageTask = nil
            if let project = model.selectedProject {
                await history.refresh(GitFileHistoryContext(path: project.path, file: file))
            }
        }
        .onDisappear { pageTask?.cancel(); pageTask = nil; history.cancel() }
        .onChange(of: history.selection) { _ in
            if let selected { model.openCommitDiff(selected.id, file: selected.path) }
        }
    }
    private func loadMore() {
        guard !history.loading else { return }
        pageTask?.cancel()
        pageTask = Task { await history.loadMore() }
    }
}

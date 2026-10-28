import SwiftUI
import AppKit

struct GitReflogEntry: Identifiable, Sendable {
    let hash: String
    let selector: String
    let subject: String
    let date: String
    var id: String { selector + hash }
    var commit: GitCommit { GitCommit(hash: hash, subject: subject, author: selector, date: date) }
}

enum GitReflogFailure: Sendable {
    case invalidPage, cancelled, readLimit, invalidOutput, changed
    case command(String)

    var requiresRefresh: Bool {
        switch self { case .invalidPage, .changed: return true; default: return false }
    }

    func message(language: AppLanguage) -> String {
        switch self {
        case .invalidPage: return Copy.t("操作记录分页状态无效，请刷新。", "Invalid reflog page state. Refresh and retry.", language: language)
        case .cancelled: return Copy.t("读取已取消。", "Read cancelled.", language: language)
        case .readLimit: return Copy.t("操作记录超过读取限制，请使用 Git 命令查看完整历史。", "Reflog exceeds the read limit. Use Git to inspect the full history.", language: language)
        case .invalidOutput: return Copy.t("无法解析操作记录，请刷新后重试。", "Cannot parse reflog. Refresh and retry.", language: language)
        case .changed: return Copy.t("操作记录已发生变化，请刷新后继续，避免遗漏或重复。", "Reflog changed. Refresh before continuing to avoid missing or duplicate entries.", language: language)
        case .command(let output): return output.isEmpty ? Copy.t("读取操作记录失败，请重试。", "Cannot read reflog. Retry.", language: language) : output
        }
    }
}

struct GitReflogPage: Sendable {
    let entries: [GitReflogEntry]
    let hasMore: Bool
    let failure: GitReflogFailure?
    var requiresRefresh: Bool { failure?.requiresRefresh ?? false }
}

extension GitService {
    static func reflogPage(at path: String, skip: Int = 0, limit: Int = 100,
                           expectedPrefix: [String]? = nil, outputLimit: Int = 4 * 1024 * 1024) async -> GitReflogPage {
        let offset = max(0, skip), count = max(1, min(100, limit))
        if let expectedPrefix, expectedPrefix.count != offset {
            return GitReflogPage(entries: [], hasMore: false, failure: .invalidPage)
        }
        // Re-read the loaded prefix: reflog selectors are mutable indices, so a
        // concurrent checkout/reset must not silently shift an offset-based page.
        let result = await CancellableGitRead.run(command: "git --no-pager reflog show --all -z -n \(offset + count + 1) --format='%H%x00%gD%x00%gs%x00%cI'", cwd: path, outputLimit: outputLimit)
        guard !Task.isCancelled else {
            return GitReflogPage(entries: [], hasMore: false, failure: .cancelled)
        }
        guard result.status == 0, !result.truncated else {
            return GitReflogPage(entries: [], hasMore: false, failure: result.truncated ? .readLimit : .command(result.output))
        }
        let worker = Task.detached(priority: .userInitiated) { parseReflog(result.output) }
        let parsed = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else {
            return GitReflogPage(entries: [], hasMore: false, failure: .cancelled)
        }
        guard let all = parsed else {
            return GitReflogPage(entries: [], hasMore: false, failure: .invalidOutput)
        }
        if let expectedPrefix, Array(all.prefix(offset).map(\.id)) != expectedPrefix {
            return GitReflogPage(entries: [], hasMore: false, failure: .changed)
        }
        return GitReflogPage(entries: Array(all.dropFirst(offset).prefix(count)), hasMore: all.count > offset + count, failure: nil)
    }

    static func parseReflog(_ output: String) -> [GitReflogEntry]? {
        if output.isEmpty { return [] }
        var values = output.components(separatedBy: "\0")
        guard values.last == "" else { return nil }
        values.removeLast()
        guard values.count.isMultiple(of: 4) else { return nil }
        var entries: [GitReflogEntry] = []
        for index in stride(from: 0, to: values.count, by: 4) {
            if Task.isCancelled { return nil }
            let hash = values[index]
            guard [40, 64].contains(hash.count), hash.allSatisfy(\.isHexDigit), !values[index + 1].isEmpty else { return nil }
            entries.append(GitReflogEntry(hash: hash, selector: values[index + 1], subject: values[index + 2], date: values[index + 3]))
        }
        return entries
    }
}

struct GitReflogPanel: View {
    @ObservedObject var model: WorkbenchModel
    let back: () -> Void
    @State private var entries: [GitReflogEntry] = []
    @State private var selection: String?
    @State private var loading = false
    @State private var reachedEnd = false
    @State private var failure: GitReflogFailure?
    @State private var requiresRefresh = false
    @State private var loadTask: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var query = ""
    @State private var recoveryEntry: GitReflogEntry?
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var visible: [GitReflogEntry] { entries.filter { query.isEmpty || "\($0.hash) \($0.subject) \($0.selector)".localizedCaseInsensitiveContains(query) } }
    var body: some View {
        WorkbenchSplit("reflog", initial: 280, minimum: 220, otherMinimum: 380, resizesSecond: true) {
            VStack(spacing: 5) {
                HStack {
                    Button { back() } label: { Image(systemName: "chevron.left"); Text(text("提交历史", "History")) }.buttonStyle(.borderless)
                    TextField(text("搜索已加载的操作记录", "Search loaded reflog entries"), text: $query).textFieldStyle(.roundedBorder)
                    Button { reload() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help(text("刷新操作记录", "Refresh reflog")).accessibilityLabel(text("刷新操作记录", "Refresh reflog"))
                }.font(.system(size: 11)).padding(.horizontal, 10).padding(.top, 6)
                List(selection: $selection) {
                    ForEach(visible) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.subject).lineLimit(1)
                                Text(entry.selector).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(String(entry.hash.prefix(8))).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }.font(.system(size: 11)).tag(entry.id).help(entry.subject).contextMenu {
                            Button(text("从此处恢复为新分支…", "Recover as a new branch…")) { recoveryEntry = entry }
                            Button(text("复制提交哈希", "Copy commit hash")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.hash, forType: .string) }
                        }
                    }
                    if entries.isEmpty && query.isEmpty && !loading && failure == nil { Text(text("暂无操作记录", "No reflog entries")).font(.caption).foregroundStyle(.secondary) }
                }.listStyle(.inset).scrollContentBackground(.hidden)
                .overlay {
                    if !query.isEmpty && visible.isEmpty && !loading && failure == nil {
                        Text(text("没有匹配的已加载记录", "No matching loaded entries")).font(.caption).foregroundStyle(.secondary).padding()
                    }
                }
                if let failure {
                    ScrollView { Text(failure.message(language: model.language)).font(.system(.caption, design: .monospaced)).foregroundStyle(.orange).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }.frame(maxHeight: 90)
                }
                HStack {
                    Text(text("已加载 \(entries.count) 条记录", "\(entries.count) entries loaded")).foregroundStyle(.secondary)
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    else if failure != nil {
                        Button(text(requiresRefresh ? "刷新后重试" : "重试", requiresRefresh ? "Refresh and retry" : "Retry")) { if requiresRefresh { reload() } else { loadMore() } }.buttonStyle(.borderless)
                    } else if !reachedEnd {
                        Button(text("加载更早的记录", "Load older entries")) { loadMore() }.buttonStyle(.borderless)
                    }
                }.font(.caption).padding(.horizontal, 10).padding(.bottom, 6)
            }.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                } second: {
            Group {
                if let entry = visible.first(where: { $0.id == selection }) { GitCommitInspector(model: model, commit: entry.commit).id(entry.id) }
                else { Text(text("选择记录查看文件，可右键恢复为新分支", "Select an entry to inspect files; right-click to recover as a new branch")).font(.caption).foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.frame(maxWidth: .infinity)
        }
        .onAppear { reload() }
        .onChange(of: model.selectedProjectID) { _ in query = ""; selection = nil; recoveryEntry = nil; reload() }
        .onChange(of: query) { _ in if !visible.contains(where: { $0.id == selection }) { selection = visible.first?.id } }
        .onDisappear { loadTask?.cancel(); loadTask = nil; generation = UUID() }
        .onChange(of: model.gitCommits.map(\.hash)) { _ in reload() }
        .sheet(item: $recoveryEntry) { entry in GitRecoveryBranchSheet(model: model, entry: entry) }
    }
    private func reload() {
        loadTask?.cancel(); generation = UUID(); entries = []; selection = nil
        loading = false; reachedEnd = false; failure = nil; requiresRefresh = false
        loadMore()
    }
    private func loadMore() {
        guard let project = model.selectedProject, !loading else { return }
        let request = generation; let prefix = entries.map(\.id)
        loading = true; failure = nil; requiresRefresh = false
        loadTask = Task {
            let page = await GitService.reflogPage(at: project.path, skip: prefix.count, expectedPrefix: prefix)
            guard !Task.isCancelled, generation == request, model.selectedProjectID == project.id else { return }
            failure = page.failure; requiresRefresh = page.requiresRefresh
            if page.failure == nil {
                entries.append(contentsOf: page.entries)
                reachedEnd = !page.hasMore
                if selection == nil { selection = visible.first?.id }
            }
            loading = false; loadTask = nil
        }
    }

}

private struct GitRecoveryBranchSheet: View {
    @ObservedObject var model: WorkbenchModel
    let entry: GitReflogEntry
    var body: some View { GitBranchEditor(model: model, mode: .recover(entry)) }
}

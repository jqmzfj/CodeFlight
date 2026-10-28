import SwiftUI
import AppKit

struct GitHistoryPanel: View {
    @ObservedObject var model: WorkbenchModel
    var externalRefresh: UUID? = nil
    @State private var historyScope = "HEAD"
    @AppStorage("layout.gitHistory.navigatorVisible") private var navigatorVisible = true
    @State private var comparisonTarget: GitComparisonTarget?
    @State private var showNewBranch = false
    @State private var showTags = false
    @State private var showReflog = false
    private enum FocusArea: Hashable { case search, commits }
    @FocusState private var focusedArea: FocusArea?
    @StateObject private var history = GitHistoryStore()
    @State private var refreshRevision = UUID()
    private var selectedHash: String? { history.selectedHash }
    private var commits: [GitCommit] { history.commits }
    private var loadingMore: Bool { history.loading }
    private var reachedEnd: Bool { history.reachedEnd }
    private var failure: String? { history.failure }
    private var requiresRefresh: Bool { history.requiresRefresh }
    @State private var commitPrompt: GitHistoryPrompt?
    @State private var branchCommit: GitCommit?
    @State private var rebaseCommit: GitCommit?
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var search: String { history.search }
    private var visibleCommits: [GitCommit] { history.visibleCommits }

    var body: some View {
        Group {
        if let path = model.gitFileHistoryPath { GitFileHistoryPanel(model: model, file: path).id(path + (model.selectedProjectID?.uuidString ?? "")) }
        else if showReflog { GitReflogPanel(model: model) { showReflog = false } }
        else { Group {
            if navigatorVisible {
                WorkbenchSplit("history.navigator", initial: 180, minimum: 150, otherMinimum: 565) {
                GitHistoryNavigator(model: model, selection: $historyScope,
                    compare: { comparisonTarget = GitComparisonTarget(id: $0) },
                    newBranch: { showNewBranch = true }, manageTags: { showTags = true })
                } second: { historyDetails }
            } else { historyDetails }
        }
        .task(id: "\(model.selectedProjectID?.uuidString ?? "")|\(historyScope)|\(refreshRevision)|\(externalRefresh?.uuidString ?? "")") {
            if let project = model.selectedProject {
                await history.refresh(GitHistoryContext(path: project.path, scope: historyScope))
            }
        }
        .onDisappear { history.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: WorkbenchLayout.didReset)) { _ in
            navigatorVisible = true
        }
        .onChange(of: model.selectedProjectID) { _ in history.search = ""; historyScope = "HEAD"; reload() }
        .onChange(of: model.gitCommits.map { $0.hash + $0.refs.joined(separator: ",") }) { _ in reload() }
        }
        }
        .sheet(item: $comparisonTarget) { GitBranchComparisonSheet(model: model, target: $0.id) }
        .sheet(isPresented: $showNewBranch) { GitBranchEditor(model: model, mode: .create) }
        .sheet(isPresented: $showTags) { GitTagsSheet(model: model) }
        .sheet(item: $commitPrompt) { request in GitPromptSheet(model: model, kind: request.kind, initialCommit: request.commit) }
        .sheet(item: $branchCommit) { commit in GitBranchEditor(model: model, mode: .create, baseCommit: commit) }
        .sheet(item: $rebaseCommit) { commit in GitInteractiveRebaseSheet(model: model, base: commit) }
        .onChange(of: model.gitOperationState) { state in
            if state != nil { history.selectedHash = nil }
        }
    }

    private var historyDetails: some View {
        WorkbenchSplit("history.details", initial: 240, minimum: 180, otherMinimum: 380, resizesSecond: true) {
            VStack(spacing: 0) {
                HStack {
                    Button { navigatorVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                        .buttonStyle(.borderless).help(text("显示或隐藏分支导航", "Toggle branch navigator"))
                        .accessibilityLabel(text("显示或隐藏分支导航", "Toggle branch navigator"))
                    TextField(text("搜索已加载的提交、作者或哈希", "Search loaded commits, author or hash"), text: $history.search)
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                        .focused($focusedArea, equals: .search)
                        .onSubmit {
                            history.selectVisibleCommit()
                            if history.selectedHash != nil { focusedArea = .commits }
                        }
                        .onExitCommand { history.search = "" }
                        .accessibilityLabel(text("筛选已加载的提交", "Filter loaded commits"))
                        .accessibilityHint(text("回车进入提交列表，Esc 清空筛选。", "Return enters the commit list. Escape clears the filter."))
                    Button { refreshRepository() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).disabled(loadingMore).help(text("刷新提交历史", "Refresh commit history"))
                        .accessibilityLabel(text("刷新提交历史", "Refresh commit history"))
                    Button { showReflog = true } label: { Image(systemName: "clock.arrow.circlepath") }.buttonStyle(.borderless).help(text("操作记录与恢复（Reflog）", "Reflog and recovery"))
                        .accessibilityLabel(text("操作记录与恢复（Reflog）", "Reflog and recovery"))
                    Text(scopeTitle).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 150).help(scopeTitle)
                }.padding(.horizontal, 8).frame(height: WorkbenchChrome.rowHeight)
                .background(WorkbenchChrome.raised)
                Rectangle().fill(WorkbenchChrome.quietSeparator).frame(height: 1)
                Table(visibleCommits, selection: $history.selectedHash) {
                    TableColumn(text("提交", "Commit")) { commit in
                        HStack(spacing: 8) {
                            if search.isEmpty, let row = history.graph[commit.hash] { GitGraphCell(row: row, columns: history.graphColumns, verticalOverflow: 4) }
                            if !commit.refs.isEmpty {
                                Text(commit.refs.joined(separator: ", ")).font(.system(size: 9, weight: .medium)).lineLimit(1).padding(.horizontal, 5).padding(.vertical, 2).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 3)).frame(maxWidth: 110, alignment: .leading)
                            }
                            Text(commit.subject).font(.system(size: 11)).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading).frame(height: GitGraphCell.rowHeight).help(commit.subject)
                    }.width(min: 260, ideal: 320)
                    TableColumn(text("作者", "Author")) { commit in
                        Text(commit.author).font(.system(size: 11)).lineLimit(1).help(commit.author)
                    }.width(min: 60, ideal: 80)
                    TableColumn(text("哈希", "Hash")) { commit in
                        Text(String(commit.hash.prefix(8))).font(.system(size: 10, design: .monospaced)).help(commit.hash)
                    }.width(min: 65, ideal: 70)
                    TableColumn(text("日期", "Date")) { commit in
                        Text(String(commit.date.prefix(10))).font(.system(size: 10)).lineLimit(1).help(commit.date)
                    }.width(min: 80, ideal: 85)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                .controlSize(.small)
                .focused($focusedArea, equals: .commits)
                .accessibilityLabel(text("提交历史", "Commit history"))
                .contextMenu(forSelectionType: String.self) { selection in
                    if let hash = selection.first, let commit = commits.first(where: { $0.hash == hash }) {
                        commitActions(commit)
                    }
                }
                .overlay {
                    if commits.isEmpty && !loadingMore && failure == nil {
                        Text(text("暂无提交记录", "No commit history")).font(.caption).foregroundStyle(.secondary)
                    } else if !search.isEmpty && visibleCommits.isEmpty {
                        Text(text("没有匹配的提交", "No matching commits")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Rectangle().fill(WorkbenchChrome.quietSeparator).frame(height: 1)
                VStack(alignment: .leading, spacing: 6) {
                    if let failure { Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled).lineLimit(3) }
                    HStack {
                        Text(text("已加载 \(commits.count) 个提交", "\(commits.count) commits loaded")).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        if loadingMore { ProgressView().controlSize(.mini) }
                        else if failure != nil {
                            Button(requiresRefresh ? text("刷新历史", "Refresh history") : text("重试", "Retry")) {
                                (requiresRefresh || history.retryRefresh) ? reload() : loadMore()
                            }.buttonStyle(.borderless)
                        } else if !reachedEnd {
                            Button(text("加载更早的提交", "Load older commits")) { loadMore() }.buttonStyle(.borderless)
                        }
                    }.font(.system(size: 11))
                }.padding(.horizontal, 10).padding(.vertical, 5)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } second: {
            Group {
                if let hash = selectedHash, let commit = commits.first(where: { $0.hash == hash }) {
                    GitCommitInspector(model: model, commit: commit).id(hash + (model.selectedProjectID?.uuidString ?? ""))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle").font(.system(size: 20)).foregroundStyle(.tertiary)
                        Text(text("选择提交查看变更文件", "Select a commit to view changed files")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var scopeTitle: String {
        if historyScope == "HEAD" { return text("当前分支", "Current branch") }
        if historyScope == "--all" { return text("所有分支", "All branches") }
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] {
            if historyScope.hasPrefix(prefix) { return String(historyScope.dropFirst(prefix.count)) }
        }
        return historyScope
    }
    @ViewBuilder private func commitActions(_ commit: GitCommit) -> some View {
        Button(text("复制完整哈希", "Copy full hash")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commit.hash, forType: .string) }
        Divider()
        Button(text("从此提交新建分支…", "New branch from this commit…")) { branchCommit = commit }.disabled(model.isGitBusy)
        Divider()
        Button(text("撤销此提交…", "Revert commit…")) { commitPrompt = GitHistoryPrompt(kind: .revert, commit: commit) }.disabled(model.isGitBusy || model.gitOperationState != nil)
        Button(text("拣选到当前分支…", "Cherry-pick to current branch…")) { commitPrompt = GitHistoryPrompt(kind: .cherryPick, commit: commit) }.disabled(model.isGitBusy || model.gitOperationState != nil)
        Button(text("交互式变基此提交之后…", "Interactively rebase commits after this…")) { rebaseCommit = commit }.disabled(model.isGitBusy || model.gitOperationState != nil)
        Menu(text("重置当前分支到此处", "Reset current branch here")) {
            Button(text("软重置（保留暂存）", "Soft (keep staged)")) { commitPrompt = GitHistoryPrompt(kind: .resetSoft, commit: commit) }
            Button(text("混合重置（保留文件）", "Mixed (keep files)")) { commitPrompt = GitHistoryPrompt(kind: .resetMixed, commit: commit) }
            Button(text("硬重置…", "Hard reset…"), role: .destructive) { commitPrompt = GitHistoryPrompt(kind: .resetHard, commit: commit) }
        }.disabled(model.isGitBusy)
    }

    private func refreshRepository() {
        reload()
        if let project = model.selectedProject { Task { await model.refreshProject(project) } }
    }
    private func reload() { refreshRevision = UUID() }
    private func loadMore() { Task { await history.loadMore() } }

}

struct GitCommitInspector: View {
    @ObservedObject var model: WorkbenchModel
    let commit: GitCommit
    @State private var description = ""
    @State private var files: [String] = []
    @State private var selectedFile: String?
    @State private var loading = true
    @State private var failure: String?
    @State private var revision = UUID()
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 5) {
                Text(commit.subject).font(.system(size: 11, weight: .medium)).lineLimit(2).help(commit.subject)
                Text("\(commit.hash.prefix(8)) · \(commit.author)").font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help("\(commit.hash) · \(commit.author)").textSelection(.enabled)
                DisclosureGroup(text("提交详情", "Commit details")) {
                    ScrollView { Text(description).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 70)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 10).padding(.top, 8)
            Rectangle().fill(WorkbenchChrome.quietSeparator).frame(height: 1)
            if loading { ProgressView().controlSize(.small).padding(10) }
            else if let failure {
                VStack(alignment: .leading, spacing: 8) {
                    Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    Button(text("重试", "Retry")) { revision = UUID() }.buttonStyle(.borderless)
                }.padding(10)
                Spacer()
            }
            else if files.isEmpty { Text(text("此提交没有文件变更", "No file changes in this commit")).font(.caption).foregroundStyle(.secondary).padding(10); Spacer() }
            else {
                List(files, id: \.self, selection: $selectedFile) { file in
                    Label(file, systemImage: "doc.text").font(.system(size: 11)).lineLimit(1).truncationMode(.middle).help(file).tag(file)
                }.listStyle(.plain).scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, GitGraphCell.rowHeight)
            }
        }.frame(maxHeight: .infinity, alignment: .top)
        .task(id: revision) {
            guard let project = model.selectedProject else { return }
            loading = true; failure = nil; selectedFile = nil
            let details = await GitService.commitDetails(commit.hash, at: project.path)
            guard !Task.isCancelled, model.selectedProjectID == project.id else { return }
            description = details.description; files = details.files; failure = details.error; loading = false
            if details.error == nil { selectedFile = files.first }
        }
        .onChange(of: selectedFile) { file in
            if let file { model.openCommitDiff(commit.hash, file: file) }
        }
    }
}

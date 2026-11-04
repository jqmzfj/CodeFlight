import SwiftUI
import AppKit

struct GitHistoryPanel: View {
    @ObservedObject var model: WorkbenchModel
    var externalRefresh: UUID? = nil
    @Binding var showConsole: Bool
    var onHide: (() -> Void)? = nil

    enum GitToolTab: String {
        case log
        case console
    }
    @State private var selectedTab: GitToolTab = .log

    init(model: WorkbenchModel, externalRefresh: UUID? = nil, showConsole: Binding<Bool> = .constant(false), onHide: (() -> Void)? = nil) {
        self.model = model
        self.externalRefresh = externalRefresh
        self._showConsole = showConsole
        self.onHide = onHide
        self._selectedTab = State(initialValue: showConsole.wrappedValue ? .console : .log)
    }

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
    @State private var scrollTargetHash: String? = nil
    @State private var authorFilter: String? = nil
    @State private var dateFilter = GitHistoryDateFilter()
    @State private var showDateRange = false
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var search: String { history.search }
    private var visibleCommits: [GitCommit] { history.visibleCommits }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Group {
                if selectedTab == .console {
                    ConsoleTool(model: model)
                } else if let path = model.gitFileHistoryPath {
                    GitFileHistoryPanel(model: model, file: path).id(path + (model.selectedProjectID?.uuidString ?? ""))
                } else if showReflog {
                    GitReflogPanel(model: model) { showReflog = false }
                } else {
                    Group {
                        if navigatorVisible {
                            WorkbenchSplit("history.navigator", initial: 190, minimum: 150, otherMinimum: 565) {
                                GitHistoryNavigator(model: model, selection: $historyScope,
                                    compare: { comparisonTarget = GitComparisonTarget(id: $0) },
                                    newBranch: { showNewBranch = true }, manageTags: { showTags = true },
                                    onCollapse: { withAnimation(.easeInOut(duration: 0.15)) { navigatorVisible = false } },
                                    onNavigateToBranchHead: { navigateLogToBranchHead($0) })
                            } second: { historyDetails }
                        } else { historyDetails }
                    }
                    .task(id: refreshKey) {
                        if let project = model.selectedProject {
                            let bounds = dateFilter.bounds()
                            await history.refresh(GitHistoryContext(path: project.path, scope: historyScope,
                                                                    author: authorFilter, since: bounds.since, until: bounds.until))
                        }
                    }
                    .task(id: model.selectedProjectID) {
                        if let project = model.selectedProject { await history.loadAuthors(for: project.path) }
                    }
                    .onDisappear { history.cancel() }
                    .onReceive(NotificationCenter.default.publisher(for: WorkbenchLayout.didReset)) { _ in
                        navigatorVisible = true
                    }
                    .onChange(of: model.selectedProjectID) { _ in
                        history.search = ""; historyScope = "HEAD"; authorFilter = nil
                        dateFilter = GitHistoryDateFilter(); showDateRange = false
                        reload()
                    }
                    .onChange(of: model.gitCommits.map { $0.hash + $0.refs.joined(separator: ",") }) { _ in reload() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $comparisonTarget) { GitBranchComparisonSheet(model: model, target: $0.id) }
        .sheet(isPresented: $showNewBranch) { GitBranchEditor(model: model, mode: .create) }
        .sheet(isPresented: $showTags) { GitTagsSheet(model: model) }
        .sheet(item: $commitPrompt) { request in GitPromptSheet(model: model, kind: request.kind, initialCommit: request.commit) }
        .sheet(item: $branchCommit) { commit in GitBranchEditor(model: model, mode: .create, baseCommit: commit) }
        .sheet(item: $rebaseCommit) { commit in GitInteractiveRebaseSheet(model: model, base: commit) }
        .sheet(isPresented: $showDateRange) { GitHistoryDateRangeSheet(model: model, filter: $dateFilter) }
        .onChange(of: model.gitOperationState) { state in
            if state != nil { history.selectedHash = nil }
        }
        .onChange(of: showConsole) { show in
            if show { selectedTab = .console }
            else if selectedTab == .console { selectedTab = .log }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Text("Git").font(.system(size: 11, weight: .semibold))

            HStack(spacing: 4) {
                let currentBranch = model.gitBranch.isEmpty ? "HEAD" : model.gitBranch
                jetBrainsTab(
                    title: "\(text("日志", "Log")): \(currentBranch)",
                    selected: selectedTab == .log,
                    hasClose: false
                ) {
                    selectedTab = .log
                    showConsole = false
                }

                jetBrainsTab(
                    title: text("控制台", "Console"),
                    selected: selectedTab == .console,
                    hasClose: false
                ) {
                    selectedTab = .console
                    showConsole = true
                }
            }

            Spacer()

            if let tracking = model.gitTracking, tracking.upstream != nil {
                GitTrackingSummary(tracking: tracking, language: model.language)
            }

            if model.isGitBusy {
                ProgressView().controlSize(.mini).padding(.trailing, 2)
            }

            // Pull
            Button {
                model.gitAction(.pull)
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.down")
                    if let behind = model.gitTracking?.behind, behind > 0 {
                        Text("\(behind)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.isGitBusy || !model.isGitRepository)
            .help(Copy.t("拉取远程更改 (Pull)", "Pull remote changes", language: model.language))

            // Push
            Button {
                model.gitAction(.push)
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up")
                    if let ahead = model.gitTracking?.ahead, ahead > 0 {
                        Text("\(ahead)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.isGitBusy || !model.isGitRepository)
            .help(Copy.t("推送本地提交 (Push)", "Push local commits", language: model.language))

            // Fetch
            Button {
                model.gitAction(.fetch)
            } label: {
                Image(systemName: "arrow.clockwise.icloud")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.isGitBusy || !model.isGitRepository)
            .help(Copy.t("获取远程更新 (Fetch)", "Fetch remote updates", language: model.language))

            // Refresh
            Button {
                refreshRepository()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.isGitBusy)
            .help(Copy.t("刷新", "Refresh", language: model.language))

            Menu {
                if selectedTab == .console {
                    Button(Copy.t("清空记录", "Clear History", language: model.language)) { model.clearGitConsole() }
                } else {
                    Button(Copy.t("刷新 Git 历史", "Refresh Git history", language: model.language)) { refreshRepository() }
                }
                Divider()
                Button(Copy.t("获取远程更新（Fetch）", "Fetch remote updates", language: model.language)) { model.gitAction(.fetch) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
            .fixedSize()

            if let onHide {
                Button(action: onHide) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Copy.t("隐藏工具窗口", "Hide tool window", language: model.language))
                .help(Copy.t("隐藏工具窗口", "Hide tool window", language: model.language))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(WorkbenchChrome.panel)
    }

    private func jetBrainsTab(title: String, selected: Bool, hasClose: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                if hasClose && selected {
                    Image(systemName: "xmark")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(selected ? Color.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var dateFilterTitle: String {
        switch dateFilter.preset {
        case .all: return text("全部", "All")
        case .today: return text("今天", "Today")
        case .lastWeek: return text("最近 7 天", "Last 7 days")
        case .lastMonth: return text("最近 30 天", "Last 30 days")
        case .lastQuarter: return text("最近 90 天", "Last 90 days")
        case .custom:
            return "\(GitHistoryDateFilter.day(dateFilter.customStart)) – \(GitHistoryDateFilter.day(dateFilter.customEnd))"
        }
    }

    /// Changing any part of the request reloads the first page; paging follows
    /// the filtered history instead of the unfiltered one.
    private var refreshKey: String {
        let bounds = dateFilter.bounds()
        return [model.selectedProjectID?.uuidString ?? "", historyScope, authorFilter ?? "", bounds.since ?? "", bounds.until ?? "",
                refreshRevision.uuidString, externalRefresh?.uuidString ?? ""].joined(separator: "|")
    }

    private func filterLabel(title: String, value: String, active: Bool, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 3) {
            Text("\(title): \(value)")
                .lineLimit(1).truncationMode(.middle)
            if active {
                Button(action: clear) { Image(systemName: "xmark").font(.system(size: 8)) }
                    .buttonStyle(.plain)
                    .help(text("清除筛选", "Clear filter"))
            } else {
                Image(systemName: "chevron.down").font(.system(size: 7))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(active ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func datePresetButton(_ preset: GitHistoryDateFilter.Preset, _ title: String) -> some View {
        Button {
            dateFilter.preset = preset
        } label: {
            HStack {
                Text(title)
                if dateFilter.preset == preset { Image(systemName: "checkmark") }
            }
        }
    }

    private var historyDetails: some View {
        WorkbenchSplit("history.details", initial: 240, minimum: 180, otherMinimum: 380, resizesSecond: true) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { navigatorVisible.toggle() }
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 11))
                            .foregroundStyle(navigatorVisible ? Color.accentColor : Color.secondary)
                            .frame(width: 22, height: 22)
                            .background(navigatorVisible ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(text("显示或隐藏分支导航", "Toggle branch navigator"))
                    .accessibilityLabel(text("显示或隐藏分支导航", "Toggle branch navigator"))

                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        TextField(text("文本或哈希", "Text or hash"), text: $history.search)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .focused($focusedArea, equals: .search)
                            .onSubmit {
                                history.selectVisibleCommit()
                                if history.selectedHash != nil { focusedArea = .commits }
                            }
                            .onExitCommand { history.search = "" }
                        if !history.search.isEmpty {
                            Button { history.search = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3.5)
                    .frame(minWidth: 140, maxWidth: 200)
                    .background(WorkbenchChrome.editor, in: Capsule())
                    .overlay(Capsule().stroke(WorkbenchChrome.subtleDivider, lineWidth: 0.5))

                    // Branch filter
                    Menu {
                        Button {
                            historyScope = "HEAD"
                        } label: {
                            HStack {
                                Text(text("当前分支 (HEAD)", "Current branch (HEAD)"))
                                if historyScope == "HEAD" { Image(systemName: "checkmark") }
                            }
                        }
                        Button {
                            historyScope = "--all"
                        } label: {
                            HStack {
                                Text(text("所有分支", "All branches"))
                                if historyScope == "--all" { Image(systemName: "checkmark") }
                            }
                        }
                        if !model.gitBranches.isEmpty {
                            Divider()
                            Menu(text("本地分支", "Local branches")) {
                                ForEach(model.gitBranches, id: \.self) { branch in
                                    Button {
                                        historyScope = "refs/heads/" + branch
                                    } label: {
                                        HStack {
                                            Text(branch)
                                            if historyScope == "refs/heads/" + branch { Image(systemName: "checkmark") }
                                        }
                                    }
                                }
                            }
                        }
                        if !model.gitRemoteBranches.isEmpty {
                            Menu(text("远程分支", "Remote branches")) {
                                ForEach(model.gitRemoteBranches, id: \.self) { branch in
                                    Button {
                                        historyScope = "refs/remotes/" + branch
                                    } label: {
                                        HStack {
                                            Text(branch)
                                            if historyScope == "refs/remotes/" + branch { Image(systemName: "checkmark") }
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text("\(text("分支", "Branch")): \(scopeTitle)")
                                .lineLimit(1).truncationMode(.middle)
                            if historyScope != "HEAD" {
                                Button {
                                    historyScope = "HEAD"
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8))
                                }
                                .buttonStyle(.plain)
                            } else {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 7))
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(historyScope == "HEAD" ? .secondary : Color.accentColor)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(text("按分支筛选提交历史", "Filter commits by branch or scope"))

                    // Author filter
                    Menu {
                        Button {
                            authorFilter = nil
                        } label: {
                            HStack {
                                Text(text("全部作者", "All authors"))
                                if authorFilter == nil { Image(systemName: "checkmark") }
                            }
                        }
                        if !history.authors.isEmpty {
                            Divider()
                            ForEach(history.authors, id: \.self) { author in
                                Button {
                                    authorFilter = author
                                } label: {
                                    HStack {
                                        Text(author)
                                        if authorFilter == author { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }
                    } label: {
                        filterLabel(title: text("用户", "User"), value: authorFilter ?? text("全部", "All"), active: authorFilter != nil) {
                            authorFilter = nil
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(text("按作者筛选提交历史", "Filter commits by author"))
                    .accessibilityLabel(text("按作者筛选提交历史", "Filter commits by author"))

                    // Date filter
                    Menu {
                        datePresetButton(.all, text("全部日期", "All dates"))
                        datePresetButton(.today, text("今天", "Today"))
                        datePresetButton(.lastWeek, text("最近 7 天", "Last 7 days"))
                        datePresetButton(.lastMonth, text("最近 30 天", "Last 30 days"))
                        datePresetButton(.lastQuarter, text("最近 90 天", "Last 90 days"))
                        Divider()
                        Button(text("自定义区间…", "Custom range…")) { showDateRange = true }
                    } label: {
                        filterLabel(title: text("日期", "Date"), value: dateFilterTitle, active: dateFilter.preset != .all) {
                            dateFilter = GitHistoryDateFilter()
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(text("按日期筛选提交历史", "Filter commits by date"))
                    .accessibilityLabel(text("按日期筛选提交历史", "Filter commits by date"))

                    Spacer()

                    Button { refreshRepository() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10.5))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(loadingMore)
                    .help(text("刷新提交历史", "Refresh commit history"))
                    .accessibilityLabel(text("刷新提交历史", "Refresh commit history"))

                    Button { showReflog = true } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10.5))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(text("操作记录与恢复（Reflog）", "Reflog and recovery"))
                    .accessibilityLabel(text("操作记录与恢复（Reflog）", "Reflog and recovery"))
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(WorkbenchChrome.panel)

                commitHistoryTable
                    .focused($focusedArea, equals: .commits)
                    .accessibilityLabel(text("提交历史", "Commit history"))
                    .overlay {
                        if commits.isEmpty && !loadingMore && failure == nil {
                            Text(history.isFiltering ? text("没有匹配的提交", "No matching commits") : text("暂无提交记录", "No commit history"))
                                .font(.caption).foregroundStyle(.secondary)
                        } else if !search.isEmpty && visibleCommits.isEmpty {
                            Text(text("没有匹配的提交", "No matching commits")).font(.caption).foregroundStyle(.secondary)
                        }
                    }

                Rectangle().fill(WorkbenchChrome.subtleDivider).frame(height: 1)

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
                .background(WorkbenchChrome.panel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WorkbenchChrome.editor)
        } second: {
            Group {
                if let hash = selectedHash, let commit = commits.first(where: { $0.hash == hash }) {
                    GitCommitInspector(model: model, commit: commit).id(hash + (model.selectedProjectID?.uuidString ?? ""))
                } else {
                    VStack(spacing: 8) {
                        Text(text("未选择提交", "No commit selected"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.tertiary)
                        Text(text("选择要查看更改的提交", "Select a commit to view changes"))
                            .font(.system(size: 11))
                            .foregroundStyle(.quaternary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WorkbenchChrome.panel)
        }
    }

    /// A quiet log surface is easier to scan than a grid of rules. Fixed-width
    /// metadata columns keep the layout aligned while the subject column takes
    /// the remaining space, just like the Git log in JetBrains IDEs.
    private var commitHistoryTable: some View {
        GeometryReader { proxy in
            let authorWidth: CGFloat = 90
            let hashWidth: CGFloat = 92
            let dateWidth: CGFloat = 104
            let commitWidth = max(260, proxy.size.width - authorWidth - hashWidth - dateWidth - 16)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text(text("提交", "Commit"))
                        .frame(width: commitWidth, alignment: .leading)
                    Text(text("作者", "Author"))
                        .frame(width: authorWidth, alignment: .leading)
                    Text(text("哈希", "Hash"))
                        .frame(width: hashWidth, alignment: .leading)
                    Text(text("日期", "Date"))
                        .frame(width: dateWidth, alignment: .leading)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(WorkbenchChrome.panel)

                Rectangle().fill(WorkbenchChrome.subtleDivider).frame(height: 1)

                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 2) {
                            ForEach(visibleCommits, id: \.hash) { commit in
                                commitHistoryRow(commit, commitWidth: commitWidth, authorWidth: authorWidth, hashWidth: hashWidth, dateWidth: dateWidth)
                                    .id(commit.hash)
                            }
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: scrollTargetHash) { hash in
                        if let hash {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                scrollProxy.scrollTo(hash, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(WorkbenchChrome.editor)
    }

    private func navigateLogToBranchHead(_ ref: String) {
        let target = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) :
                     ref.hasPrefix("refs/remotes/") ? String(ref.dropFirst("refs/remotes/".count)) :
                     ref == "HEAD" ? model.gitBranch : ref

        if let commit = history.commits.first(where: { c in
            c.refs.contains { r in
                r == target || r == "origin/" + target || r.hasSuffix("/" + target) || r == ref
            }
        }) {
            withAnimation(.easeInOut(duration: 0.2)) {
                history.selectedHash = commit.hash
                scrollTargetHash = commit.hash
            }
        } else {
            historyScope = ref
        }
    }

    private func commitHistoryRow(_ commit: GitCommit, commitWidth: CGFloat, authorWidth: CGFloat, hashWidth: CGFloat, dateWidth: CGFloat) -> some View {
        let selected = history.selectedHash == commit.hash
        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                if search.isEmpty, authorFilter == nil, let row = history.graph[commit.hash] {
                    GitGraphCell(row: row, columns: history.graphColumns, verticalOverflow: 4)
                        .frame(minWidth: 52, alignment: .leading)
                }
                if !commit.refs.isEmpty {
                    Text(commit.refs.joined(separator: ", "))
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
                        .frame(maxWidth: 110, alignment: .leading)
                }
                Text(commit.subject)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: commitWidth, alignment: .leading)
            Text(commit.author)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: authorWidth, alignment: .leading)
            Text(String(commit.hash.prefix(8)))
                .font(.system(size: 10, design: .monospaced))
                .frame(width: hashWidth, alignment: .leading)
            Text(String(commit.date.prefix(10)))
                .font(.system(size: 10))
                .lineLimit(1)
                .frame(width: dateWidth, alignment: .leading)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .frame(height: GitGraphCell.rowHeight)
        .background(selected ? WorkbenchChrome.selectedSurface : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture { history.selectedHash = commit.hash }
        .contextMenu { commitActions(commit) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityLabel("\(commit.subject), \(commit.author), \(String(commit.hash.prefix(8))), \(String(commit.date.prefix(10)))")
        .help(commit.subject)
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

/// Custom ranges are applied explicitly; closing the sheet keeps the previous
/// filter, so a half-edited range never changes the log.
private struct GitHistoryDateRangeSheet: View {
    @ObservedObject var model: WorkbenchModel
    @Binding var filter: GitHistoryDateFilter
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date

    init(model: WorkbenchModel, filter: Binding<GitHistoryDateFilter>) {
        self.model = model
        _filter = filter
        let current = filter.wrappedValue
        _start = State(initialValue: current.preset == .custom ? current.customStart : Date())
        _end = State(initialValue: current.preset == .custom ? current.customEnd : Date())
    }

    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text("自定义日期区间", "Custom date range"))
                .font(.system(size: 12, weight: .semibold))
            Text(text("按提交日期显示区间内的记录。结束日期包含当天。", "Show commits inside the range. The end date includes the whole day."))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(text("开始", "Start")).font(.system(size: 11)).frame(width: 40, alignment: .leading)
                    DatePicker("", selection: $start, displayedComponents: .date).labelsHidden()
                }
                HStack {
                    Text(text("结束", "End")).font(.system(size: 11)).frame(width: 40, alignment: .leading)
                    DatePicker("", selection: $end, in: start..., displayedComponents: .date).labelsHidden()
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if filter.preset != .all {
                    Button(text("清除筛选", "Clear filter")) {
                        filter = GitHistoryDateFilter()
                        dismiss()
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button(text("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(text("应用", "Apply")) {
                    filter.preset = .custom
                    filter.customStart = min(start, end)
                    filter.customEnd = max(start, end)
                    filter.normalizeCustomDates()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 360, height: 210)
    }
}

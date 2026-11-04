import SwiftUI
import AppKit

struct GitChangeSelection: Hashable {
    let path: String
    let staged: Bool
}

struct GitChangesPanel: View {
    @ObservedObject var model: WorkbenchModel
    @State private var showStashSheet = false
    @State private var showAmendSheet = false
    @State private var isAmending = false
    @State private var selection: Set<GitChangeSelection> = []
    @State private var search = ""
    @AppStorage("layout.gitChanges.stagedExpanded") private var stagedExpanded = true
    @AppStorage("layout.gitChanges.modifiedExpanded") private var modifiedExpanded = true
    @AppStorage("layout.gitChanges.untrackedExpanded") private var untrackedExpanded = true
    @AppStorage("layout.gitChanges.conflictsExpanded") private var conflictsExpanded = true
    @FocusState private var messageFocused: Bool

    enum CommitTab: String {
        case commit, shelf, stash
    }
    struct GitShelfItem: Identifiable, Equatable {
        let id: String
        let name: String
        let date: Date
        let path: String
    }

    @State private var activeTab: CommitTab = .commit
    @State private var selectedStashHash: String? = nil
    @State private var stashDiffText: String = ""
    @State private var loadingStashDiff = false
    @State private var showCreateStashPopover = false
    @State private var newStashMessage = ""

    @State private var shelfItems: [GitShelfItem] = []
    @State private var selectedShelfID: String? = nil
    @State private var shelfDiffText: String = ""
    @State private var loadingShelfDiff = false
    @State private var showCreateShelfPopover = false
    @State private var newShelfName = ""
    @State private var revertOnShelf = true

    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var staged: [GitChange] { model.gitChanges.filter { $0.isStaged && matches($0) } }
    private var modified: [GitChange] { model.gitChanges.filter { $0.isUnstaged && !$0.isConflicted && $0.state != "??" && matches($0) } }
    private var untracked: [GitChange] { model.gitChanges.filter { $0.state == "??" && matches($0) } }
    private var unstaged: [GitChange] { model.gitChanges.filter { $0.isUnstaged && !$0.isConflicted && matches($0) } }
    private var conflicted: [GitChange] { model.gitChanges.filter { $0.isConflicted && matches($0) } }
    private var canCommit: Bool { !model.isGitBusy && model.gitChanges.contains(where: \.isStaged) && !model.gitChanges.contains(where: \.isConflicted) && !model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func matches(_ change: GitChange) -> Bool { search.isEmpty || change.displayPath.localizedCaseInsensitiveContains(search) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            Rectangle().fill(WorkbenchChrome.quietSeparator).frame(height: 1)
            if activeTab == .commit {
                actionToolbar
                Rectangle().fill(WorkbenchChrome.subtleDivider).frame(height: 0.5)
                panelContent.padding(.horizontal, 10).padding(.vertical, 6)
            } else if activeTab == .shelf {
                shelfContent
            } else {
                stashContent
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showStashSheet) { StashSheet(model: model) }
        .sheet(isPresented: $showAmendSheet) { GitAmendSheet(model: model) }
        .onReceive(NotificationCenter.default.publisher(for: WorkbenchLayout.didReset)) { _ in
            stagedExpanded = true
            modifiedExpanded = true
            untrackedExpanded = true
            conflictsExpanded = true
        }
        .onChange(of: selection) { values in
            guard values.count == 1, let value = values.first else { return }
            if let change = model.gitChanges.first(where: { $0.path == value.path }) {
                model.openDiff(change, staged: value.staged)
            }
        }
        .onChange(of: model.selectedProjectID) { _ in selection = []; search = ""; loadShelves() }
        .onChange(of: activeTab) { tab in if tab == .shelf { loadShelves() } }
        .onChange(of: search) { _ in pruneSelection() }
        .onChange(of: stagedExpanded) { _ in pruneSelection() }
        .onChange(of: modifiedExpanded) { _ in pruneSelection() }
        .onChange(of: untrackedExpanded) { _ in pruneSelection() }
        .onChange(of: conflictsExpanded) { _ in pruneSelection() }
        .onChange(of: model.gitChanges.map { $0.path + "\0" + $0.state }) { _ in pruneSelection() }
        .onChange(of: model.selectedFile) { _ in syncSelection() }
        .onChange(of: model.diffIsStaged) { _ in syncSelection() }
        .onChange(of: model.historyCommit) { _ in syncSelection() }
        .onAppear { syncSelection(); loadShelves() }
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            Button {
                activeTab = .commit
            } label: {
                let count = model.gitChanges.count
                Text(count > 0 ? "\(text("提交", "Commit")) \(count)" : text("提交", "Commit"))
                    .font(.system(size: 11, weight: activeTab == .commit ? .medium : .regular))
                    .foregroundStyle(activeTab == .commit ? Color.primary : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(activeTab == .commit ? Color.primary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                activeTab = .shelf
            } label: {
                let shelfCount = shelfItems.count
                Text(shelfCount > 0 ? "\(text("搁置", "Shelf")) \(shelfCount)" : text("搁置", "Shelf"))
                    .font(.system(size: 11, weight: activeTab == .shelf ? .medium : .regular))
                    .foregroundStyle(activeTab == .shelf ? Color.primary : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(activeTab == .shelf ? Color.primary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(text("管理搁置更改 (Shelf)", "Manage shelved changes"))

            Button {
                activeTab = .stash
            } label: {
                let stashCount = model.gitStashes.count
                Text(stashCount > 0 ? "\(text("储藏", "Stash")) \(stashCount)" : text("储藏", "Stash"))
                    .font(.system(size: 11, weight: activeTab == .stash ? .medium : .regular))
                    .foregroundStyle(activeTab == .stash ? Color.primary : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(activeTab == .stash ? Color.primary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(text("管理储藏 (Stash)", "Manage stashes"))

            Spacer()

            Menu {
                Button(text("修改最近一次提交…", "Amend last commit…")) { showAmendSheet = true }
                    .disabled(model.gitCommits.isEmpty || model.gitOperationState != nil || model.gitChanges.contains(where: \.isConflicted))
                Divider()
                Button(text("暂存全部", "Stage all")) { model.gitAction(.stageAll) }
                Button(text("取消全部暂存", "Unstage all")) { model.gitAction(.unstageAll) }
                Divider()
                Button(text("保存到 Stash…", "Stash changes…")) { showCreateStashPopover = true }
                Button(text("恢复最近 Stash (Pop)", "Pop latest stash")) { model.gitAction(.stashPop) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
            .fixedSize()
            .disabled(model.isGitBusy || !model.isGitRepository)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(WorkbenchChrome.panel)
    }

    private var actionToolbar: some View {
        HStack(spacing: 8) {
            Button {
                if let project = model.selectedProject { Task { await model.refreshProject(project) } }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(text("刷新", "Refresh"))

            let discardables = targets(.discard, selected: selection)
            Button {
                if !discardables.isEmpty { model.gitBatchFileAction(.discard, changes: discardables) }
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(discardables.isEmpty || model.isGitBusy)
            .help(text("回滚所选工作区修改…", "Rollback selected working changes…"))

            Button {
                if let first = selection.first, let change = model.gitChanges.first(where: { $0.path == first.path }) {
                    model.openDiff(change, staged: first.staged)
                }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .disabled(selection.isEmpty)
            .help(text("显示差异", "Show diff"))

            Button {
                model.gitAction(.pull)
            } label: {
                Image(systemName: "arrow.down.to.line")
            }
            .disabled(model.isGitBusy)
            .help(text("拉取更改", "Pull changes"))

            Menu {
                Toggle(text("自动暂存更改", "Auto stage"), isOn: .constant(true))
            } label: {
                Image(systemName: "eye")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help(text("查看选项", "View options"))

            Button {
                syncSelection()
            } label: {
                Image(systemName: "scope")
            }
            .help(text("定位当前文件", "Select current file"))

            Spacer()

            Button {
                stagedExpanded = true
                modifiedExpanded = true
                untrackedExpanded = true
                conflictsExpanded = true
            } label: {
                Image(systemName: "arrow.up.and.down")
            }
            .help(text("全部展开", "Expand all"))

            Button {
                stagedExpanded = false
                modifiedExpanded = false
                untrackedExpanded = false
                conflictsExpanded = false
            } label: {
                Image(systemName: "arrow.down.and.line.horizontal.and.arrow.up")
            }
            .help(text("全部折叠", "Collapse all"))
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(WorkbenchChrome.panel)
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = model.gitStatusError {
                Label(text("无法读取 Git 状态", "Cannot read Git status"), systemImage: "exclamationmark.triangle").font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 6)
                Spacer()
            } else if model.isGitRepository {
                if model.gitOperationState != nil || model.gitChanges.contains(where: \.isConflicted) {
                    operationBanner.padding(.bottom, 6)
                }

                WorkbenchSplit("changes.commit", axis: .horizontal, initial: 175,
                               minimum: 140, otherMinimum: 80, resizesSecond: true) {
                    VStack(spacing: 0) {
                        if model.gitChanges.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "checkmark.circle").font(.system(size: 22)).foregroundStyle(.green)
                                Text(text("没有未提交的更改", "No uncommitted changes")).font(.system(size: 11)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            changesList
                        }
                        if selection.count > 1 { batchToolbar }
                    }
                } second: {
                    commitArea.padding(.top, 6)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(text("当前目录尚未使用 Git", "This directory is not a Git repository")).font(.caption).foregroundStyle(.secondary)
                    Button(text("初始化 Git 仓库", "Initialize Git repository")) { model.initializeGit() }.buttonStyle(.borderedProminent).controlSize(.small)
                }.padding(.vertical, 12)
                Spacer()
            }
        }.frame(maxHeight: .infinity, alignment: .top)
    }

    private var operationBanner: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(model.gitOperationState?.title(model.language) ?? text("存在待解决的冲突", "Unresolved conflicts"), systemImage: "arrow.triangle.merge")
                .font(.system(size: 11, weight: .medium))
            let conflicts = model.gitChanges.filter(\.isConflicted)
            HStack(spacing: 10) {
                if let first = conflicts.first {
                    Button(text("解决 \(conflicts.count) 个冲突", "Resolve \(conflicts.count) conflicts")) { model.openDiff(first) }
                } else if let state = model.gitOperationState {
                    Button(text("继续", "Continue")) { model.gitAdvanced(state.continueOperation) }
                }
                Spacer(minLength: 0)
                if let state = model.gitOperationState {
                    if let operation = state.skipOperation {
                        Button(text("跳过…", "Skip…")) { model.gitAdvanced(operation) }
                            .help(text("放弃当前提交并继续后续提交", "Discard the current commit and continue the sequence"))
                    }
                    Button(text("中止…", "Abort…")) { model.gitAdvanced(state.abortOperation) }
                }
            }.font(.system(size: 11)).buttonStyle(.borderless).disabled(model.isGitBusy)
        }.padding(9).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }

    private var changesList: some View {
        List(selection: $selection) {
            if !conflicted.isEmpty {
                groupHeaderView(
                    title: "\(text("冲突", "Conflicts"))  \(conflicted.count) \(text("个文件", "files"))",
                    count: conflicted.count,
                    expanded: $conflictsExpanded,
                    items: conflicted,
                    staged: false
                )
                .listRowSeparator(.hidden)
                if conflictsExpanded {
                    ForEach(conflicted) { change in
                        GitChangeRowView(
                            change: change,
                            staged: false,
                            model: model,
                            onOpenWorkingFile: { openWorkingFile(change) },
                            onPerformAction: { perform($0, clicked: change, staged: false) },
                            actionTitle: { actionTitle($0, clicked: change, staged: false) }
                        )
                        .tag(GitChangeSelection(path: change.path, staged: false))
                        .listRowSeparator(.hidden)
                    }
                }
            }

            let modifiedFiles = model.gitChanges.filter { !$0.isConflicted && $0.state != "??" && matches($0) }
            if !modifiedFiles.isEmpty {
                groupHeaderView(
                    title: "\(text("更改", "Changes"))  \(modifiedFiles.count) \(text("个文件", "files"))",
                    count: modifiedFiles.count,
                    expanded: $modifiedExpanded,
                    items: modifiedFiles,
                    staged: false
                )
                .listRowSeparator(.hidden)
                if modifiedExpanded {
                    ForEach(modifiedFiles) { change in
                        GitChangeRowView(
                            change: change,
                            staged: change.isStaged,
                            model: model,
                            onOpenWorkingFile: { openWorkingFile(change) },
                            onPerformAction: { perform($0, clicked: change, staged: change.isStaged) },
                            actionTitle: { actionTitle($0, clicked: change, staged: change.isStaged) }
                        )
                        .tag(GitChangeSelection(path: change.path, staged: change.isStaged))
                        .listRowSeparator(.hidden)
                    }
                }
            }

            if !untracked.isEmpty {
                groupHeaderView(
                    title: "\(text("未进行版本管理的文件", "Unversioned Files"))  \(untracked.count) \(text("个文件", "files"))",
                    count: untracked.count,
                    expanded: $untrackedExpanded,
                    items: untracked,
                    staged: false
                )
                .listRowSeparator(.hidden)
                if untrackedExpanded {
                    ForEach(untracked) { change in
                        GitChangeRowView(
                            change: change,
                            staged: change.isStaged,
                            model: model,
                            onOpenWorkingFile: { openWorkingFile(change) },
                            onPerformAction: { perform($0, clicked: change, staged: change.isStaged) },
                            actionTitle: { actionTitle($0, clicked: change, staged: change.isStaged) }
                        )
                        .tag(GitChangeSelection(path: change.path, staged: change.isStaged))
                        .listRowSeparator(.hidden)
                    }
                }
            }

            if modifiedFiles.isEmpty && untracked.isEmpty && conflicted.isEmpty {
                Text(text("没有匹配的文件", "No matching files")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, -10)
        .padding(.vertical, 3)
        .background {
            Button(action: toggleSelected) { EmptyView() }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)
        }
    }

    private func toggleSelected() {
        guard !selection.isEmpty else { return }
        let toStage = selection.filter { !$0.staged }
        let toUnstage = selection.filter { $0.staged }
        if !toStage.isEmpty {
            let changes = model.gitChanges.filter { ch in toStage.contains { $0.path == ch.path } }
            model.gitBatchFileAction(.stage, changes: changes)
        } else if !toUnstage.isEmpty {
            let changes = model.gitChanges.filter { ch in toUnstage.contains { $0.path == ch.path } }
            model.gitBatchFileAction(.unstage, changes: changes)
        }
    }

    private func groupHeaderView(title: String, count: Int, expanded: Binding<Bool>, items: [GitChange], staged: Bool) -> some View {
        let allChecked = staged ? items.allSatisfy(\.isStaged) : items.allSatisfy(\.isStaged)
        let anyChecked = items.contains(where: \.isStaged)

        return HStack(spacing: 5) {
            Button {
                expanded.wrappedValue.toggle()
            } label: {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 18)
            }
            .buttonStyle(.plain)

            Button {
                if staged {
                    model.gitBatchFileAction(.unstage, changes: items)
                } else {
                    if allChecked {
                        model.gitBatchFileAction(.unstage, changes: items)
                    } else {
                        model.gitBatchFileAction(.stage, changes: items)
                    }
                }
            } label: {
                Image(systemName: staged ? "checkmark.square.fill" : (allChecked ? "checkmark.square.fill" : (anyChecked ? "minus.square.fill" : "square")))
                    .font(.system(size: 11))
                    .foregroundStyle(staged || allChecked || anyChecked ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(model.isGitBusy)

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.88))

            Spacer(minLength: 2)

            GitChangesIconButton(
                symbol: staged ? "minus" : "plus",
                label: staged ? text("取消此组暂存", "Unstage this group") : text("暂存此组", "Stage this group"),
                enabled: !model.isGitBusy
            ) {
                model.gitBatchFileAction(staged ? .unstage : .stage, changes: items)
            }
            .frame(width: 18, height: 18)
        }
        .frame(height: 20)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    private var commitArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    isAmending.toggle()
                    if isAmending && model.commitMessage.isEmpty, let last = model.gitCommits.first {
                        model.commitMessage = last.subject
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isAmending ? "checkmark.square.fill" : "square")
                            .font(.system(size: 11))
                            .foregroundStyle(isAmending ? Color.accentColor : Color.secondary)
                        Text(text("修正(M)", "Amend(M)"))
                            .font(.system(size: 11))
                            .foregroundStyle(isAmending ? Color.primary : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.gitCommits.isEmpty || model.gitOperationState != nil || model.gitChanges.contains(where: \.isConflicted))

                if !model.gitCommits.isEmpty {
                    Menu {
                        ForEach(Array(model.gitCommits.prefix(8))) { commit in
                            Button(commit.subject) {
                                model.commitMessage = commit.subject
                            }
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text(text("上次提交", "Last commit"))
                                .font(.system(size: 11))
                                .foregroundStyle(Color.accentColor)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Menu {
                    Text(text("历史提交说明", "Recent commit messages"))
                    Divider()
                    let recentCommits = Array(model.gitCommits.prefix(15))
                    if recentCommits.isEmpty {
                        Text(text("无历史记录", "No recent commit messages")).foregroundStyle(.secondary)
                    } else {
                        ForEach(recentCommits) { commit in
                            Button {
                                model.commitMessage = commit.subject
                            } label: {
                                Text(commit.subject)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "clock")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(text("选择历史提交说明…", "Recent commit messages…"))

                Spacer()

                let stagedCount = model.gitChanges.filter(\.isStaged).count
                Text("\(stagedCount) \(text("已修改", "modified"))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 0.40, green: 0.70, blue: 1.0))
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.commitMessage).font(.system(size: 12)).focused($messageFocused)
                    .scrollContentBackground(.hidden).padding(4)
                if model.commitMessage.isEmpty {
                    Text(text("输入本次修改的说明…", "Describe your changes…"))
                        .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.top, 8).allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(messageFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12)))

            if model.gitChanges.contains(where: \.isConflicted) {
                Text(text("请先解决冲突，再提交。", "Resolve conflicts before committing.")).font(.system(size: 10)).foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Button {
                    if isAmending {
                        showAmendSheet = true
                    } else {
                        model.commitChanges()
                    }
                } label: {
                    Text(text("提交(T)", "Commit(T)"))
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.bordered)
                .disabled(!canCommit && !isAmending)
                .keyboardShortcut(.return, modifiers: .command)

                Button {
                    if isAmending {
                        showAmendSheet = true
                    } else {
                        model.commitChanges(pushAfter: true)
                    }
                } label: {
                    Text(text("提交并推送(P)…", "Commit and Push(P)…"))
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.bordered)
                .disabled(!canCommit && !isAmending)

                Spacer()

                Menu {
                    Button(text("修改最近一次提交…", "Amend last commit…")) { showAmendSheet = true }
                    Divider()
                    Button(text("清空提交说明", "Clear commit message")) { model.commitMessage = "" }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.top, 2)
        }
    }

    private var visibleSelections: Set<GitChangeSelection> {
        var result: Set<GitChangeSelection> = []
        if stagedExpanded { result.formUnion(staged.map { GitChangeSelection(path: $0.path, staged: true) }) }
        if modifiedExpanded { result.formUnion(modified.map { GitChangeSelection(path: $0.path, staged: false) }) }
        if untrackedExpanded { result.formUnion(untracked.map { GitChangeSelection(path: $0.path, staged: false) }) }
        if conflictsExpanded { result.formUnion(conflicted.map { GitChangeSelection(path: $0.path, staged: false) }) }
        return result
    }
    private func pruneSelection() { selection.formIntersection(visibleSelections) }
    private func syncSelection() {
        guard let project = model.selectedProject, model.historyCommit == nil, !model.diffContent.isEmpty else { selection = []; return }
        let prefix = project.path + "/"
        guard model.selectedFile.hasPrefix(prefix) else { return }
        let entry = GitChangeSelection(path: String(model.selectedFile.dropFirst(prefix.count)), staged: model.diffIsStaged)
        guard visibleSelections.contains(entry) else { return }
        if !selection.contains(entry) { selection = [entry] }
    }
    private func targets(_ action: GitFileAction, selected: Set<GitChangeSelection>) -> [GitChange] {
        let paths = Set(selected.filter { action == .unstage ? $0.staged : !$0.staged }.map(\.path))
        return model.gitChanges.filter { paths.contains($0.path) && !$0.isConflicted && (action == .unstage ? $0.isStaged : $0.isUnstaged) }
    }
    private func targets(_ action: GitFileAction, clicked: GitChange, staged: Bool) -> [GitChange] {
        let entry = GitChangeSelection(path: clicked.path, staged: staged)
        return targets(action, selected: selection.contains(entry) ? selection : [entry])
    }
    private func actionTitle(_ action: GitFileAction, clicked: GitChange, staged: Bool) -> String {
        let count = targets(action, clicked: clicked, staged: staged).count
        switch action {
        case .stage: return count > 1 ? text("暂存所选 \(count) 个文件", "Stage \(count) selected files") : text("暂存文件", "Stage file")
        case .unstage: return count > 1 ? text("取消所选 \(count) 个文件暂存", "Unstage \(count) selected files") : text("取消暂存", "Unstage file")
        case .discard: return count > 1 ? text("回滚所选 \(count) 个文件…", "Rollback \(count) selected files…") : text("回滚工作区修改…", "Rollback working changes…")
        }
    }
    private func perform(_ action: GitFileAction, clicked: GitChange, staged: Bool) {
        model.gitBatchFileAction(action, changes: targets(action, clicked: clicked, staged: staged))
    }
    private var batchToolbar: some View {
        HStack(spacing: 7) {
            Text(text("已选 \(selection.count) 项", "\(selection.count) selected")).font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Menu(text("所选操作", "Selection actions")) {
                let toStage = targets(.stage, selected: selection)
                let toUnstage = targets(.unstage, selected: selection)
                Button(text("暂存 \(toStage.count) 个文件", "Stage \(toStage.count) files")) { model.gitBatchFileAction(.stage, changes: toStage) }.disabled(toStage.isEmpty)
                Button(text("取消 \(toUnstage.count) 个文件暂存", "Unstage \(toUnstage.count) files")) { model.gitBatchFileAction(.unstage, changes: toUnstage) }.disabled(toUnstage.isEmpty)
                Divider()
                Button(text("回滚 \(toStage.count) 个工作区文件…", "Rollback \(toStage.count) working files…"), role: .destructive) { model.gitBatchFileAction(.discard, changes: toStage) }.disabled(toStage.isEmpty)
            }.controlSize(.small).disabled(model.isGitBusy)
        }.padding(.vertical, 7)
    }
    private func openWorkingFile(_ change: GitChange) {
        guard let project = model.selectedProject else { return }
        model.openFilePath(URL(fileURLWithPath: project.path).appendingPathComponent(change.path).path)
    }

    private var shelfDirectory: URL? {
        guard let project = model.selectedProject else { return nil }
        let ideaShelf = URL(fileURLWithPath: project.path).appendingPathComponent(".idea/shelf")
        if FileManager.default.fileExists(atPath: ideaShelf.path) {
            return ideaShelf
        }
        return URL(fileURLWithPath: project.path).appendingPathComponent(".git/shelves")
    }

    private func loadShelves() {
        guard let dir = shelfDirectory else { shelfItems = []; return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else {
            shelfItems = []
            return
        }
        var items: [GitShelfItem] = []
        for file in files where file.pathExtension == "patch" || file.pathExtension == "diff" {
            let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            let date = attrs?.contentModificationDate ?? Date()
            let rawName = file.deletingPathExtension().lastPathComponent
            let displayName: String
            if let underscoreIdx = rawName.firstIndex(of: "_") {
                displayName = String(rawName[rawName.index(after: underscoreIdx)...]).replacingOccurrences(of: "_", with: " ")
            } else {
                displayName = rawName.replacingOccurrences(of: "_", with: " ")
            }
            items.append(GitShelfItem(id: file.lastPathComponent, name: displayName.isEmpty ? rawName : displayName, date: date, path: file.path))
        }
        items.sort { $0.date > $1.date }
        shelfItems = items
        if selectedShelfID == nil {
            selectedShelfID = items.first?.id
        }
        if let id = selectedShelfID, let item = items.first(where: { $0.id == id }) {
            loadShelfDiff(path: item.path)
        }
    }

    private func loadShelfDiff(path: String) {
        loadingShelfDiff = true
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            shelfDiffText = text
        } else {
            shelfDiffText = ""
        }
        loadingShelfDiff = false
    }

    private func createShelf(name: String, revert: Bool) {
        guard let project = model.selectedProject, let dir = shelfDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = trimmed.isEmpty ? "shelf" : trimmed.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
        let filename = "\(Int(Date().timeIntervalSince1970))_\(safeName).patch"
        let dest = dir.appendingPathComponent(filename)
        Task {
            let diffResult = await CommandRunner.run(command: "git diff HEAD", cwd: project.path)
            if diffResult.status == 0, !diffResult.output.isEmpty {
                try? diffResult.output.write(to: dest, atomically: true, encoding: .utf8)
                if revert {
                    _ = await CommandRunner.run(command: "git checkout -- .", cwd: project.path)
                }
                await model.refreshProject(project)
                loadShelves()
                selectedShelfID = filename
                loadShelfDiff(path: dest.path)
            }
        }
    }

    private func unshelve(item: GitShelfItem) {
        guard let project = model.selectedProject else { return }
        Task {
            let res = await CommandRunner.run(command: "git apply --3way \(Shell.quote(item.path))", cwd: project.path)
            if res.status == 0 {
                try? FileManager.default.removeItem(atPath: item.path)
                await model.refreshProject(project)
                loadShelves()
                selectedShelfID = shelfItems.first?.id
            }
        }
    }

    private func restoreShelf(item: GitShelfItem) {
        guard let project = model.selectedProject else { return }
        Task {
            _ = await CommandRunner.run(command: "git apply --3way \(Shell.quote(item.path))", cwd: project.path)
            await model.refreshProject(project)
        }
    }

    private func dropShelf(item: GitShelfItem) {
        try? FileManager.default.removeItem(atPath: item.path)
        loadShelves()
        if selectedShelfID == item.id {
            selectedShelfID = shelfItems.first?.id
        }
    }

    private var shelfContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // 1. 新建搁置 +
                Button {
                    newShelfName = ""
                    revertOnShelf = true
                    showCreateShelfPopover = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(model.gitChanges.isEmpty || model.isGitBusy)
                .help(text("搁置当前更改…", "Shelve changes…"))

                // 2. 取消搁置 ↳ (Unshelve: apply & delete from shelf)
                Button {
                    if let selected = shelfItems.first(where: { $0.id == selectedShelfID }) {
                        unshelve(item: selected)
                    }
                } label: {
                    Image(systemName: "arrow.turn.down.right")
                }
                .disabled(selectedShelfID == nil || model.isGitBusy)
                .help(text("取消搁置 (应用并从搁置中移除)", "Unshelve changes"))

                // 3. 恢复搁置 ⤓ (Restore: apply & keep in shelf)
                Button {
                    if let selected = shelfItems.first(where: { $0.id == selectedShelfID }) {
                        restoreShelf(item: selected)
                    }
                } label: {
                    Image(systemName: "arrow.down.to.line")
                }
                .disabled(selectedShelfID == nil || model.isGitBusy)
                .help(text("恢复搁置 (应用并保留在搁置中)", "Restore shelf (keep in shelf)"))

                // 4. 删除搁置 🗑 (Drop)
                Button {
                    if let selected = shelfItems.first(where: { $0.id == selectedShelfID }) {
                        dropShelf(item: selected)
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selectedShelfID == nil || model.isGitBusy)
                .help(text("删除所选搁置", "Drop selected shelf"))

                Spacer()

                // 5. 刷新 ↻
                Button {
                    loadShelves()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(text("刷新搁置", "Refresh shelves"))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(WorkbenchChrome.bar)

            Rectangle().fill(WorkbenchChrome.subtleDivider).frame(height: 0.5)

            if shelfItems.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundStyle(.quaternary)
                    Text(text("暂无搁置记录", "No Shelved Changes"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    if !model.gitChanges.isEmpty {
                        Button(text("搁置当前更改…", "Shelve current changes…")) {
                            newShelfName = ""
                            revertOnShelf = true
                            showCreateShelfPopover = true
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedShelfID) {
                    ForEach(shelfItems) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: "tray.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.accentColor)
                                Text(item.name)
                                    .font(.system(size: 11, weight: .semibold))
                                Spacer()
                            }
                            Text(item.date.formatted(date: .numeric, time: .shortened))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        .tag(item.id)
                        .contextMenu {
                            Button(text("取消搁置 (应用并移除)", "Unshelve Changes")) {
                                unshelve(item: item)
                            }
                            Button(text("恢复搁置 (应用并保留)", "Restore Shelf")) {
                                restoreShelf(item: item)
                            }
                            Divider()
                            Button(text("删除搁置", "Drop Shelf"), role: .destructive) {
                                dropShelf(item: item)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .onChange(of: selectedShelfID) { id in
                    if let id = id, let item = shelfItems.first(where: { $0.id == id }) {
                        loadShelfDiff(path: item.path)
                    } else {
                        shelfDiffText = ""
                    }
                }

                if selectedShelfID != nil {
                    Rectangle().fill(WorkbenchChrome.subtleDivider).frame(height: 1)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(text("搁置补丁预览", "Shelf patch preview"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if loadingShelfDiff {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        .padding(.horizontal, 8).padding(.top, 4)

                        ScrollView {
                            Text(shelfDiffText.isEmpty ? text("无文本差异", "No text diff") : shelfDiffText)
                                .font(.system(size: 10, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .textSelection(.enabled)
                        }
                        .background(WorkbenchChrome.editor)
                    }
                    .frame(height: 160)
                }
            }
        }
        .popover(isPresented: $showCreateShelfPopover) {
            VStack(alignment: .leading, spacing: 10) {
                Text(text("搁置更改", "Shelve Changes"))
                    .font(.system(size: 12, weight: .semibold))

                TextField(text("搁置说明…", "Shelf description…"), text: $newShelfName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 240)

                Toggle(text("搁置后还原工作区更改", "Revert changes after shelving"), isOn: $revertOnShelf)
                    .font(.system(size: 11))

                HStack {
                    Button(text("取消", "Cancel")) {
                        showCreateShelfPopover = false
                    }
                    .controlSize(.small)

                    Spacer()

                    Button(text("搁置", "Shelve")) {
                        let name = newShelfName
                        let revert = revertOnShelf
                        showCreateShelfPopover = false
                        createShelf(name: name, revert: revert)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
        }
    }

    private var stashContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    showCreateStashPopover = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(model.gitChanges.isEmpty || model.isGitBusy)
                .help(text("保存当前更改到 Stash…", "Save changes to Stash…"))

                Button {
                    model.gitAction(.stashPop)
                } label: {
                    Image(systemName: "arrow.down.to.line")
                }
                .disabled(model.gitStashes.isEmpty || model.isGitBusy)
                .help(text("恢复并弹出最近 Stash (Pop)", "Pop latest stash"))

                Button {
                    if let selected = model.gitStashes.first(where: { $0.hash == selectedStashHash }) {
                        model.stashAction(.apply, stash: selected)
                    }
                } label: {
                    Image(systemName: "arrow.uturn.down")
                }
                .disabled(selectedStashHash == nil || model.isGitBusy)
                .help(text("应用所选 Stash (Apply)", "Apply selected stash"))

                Button {
                    if let selected = model.gitStashes.first(where: { $0.hash == selectedStashHash }) {
                        model.stashAction(.drop, stash: selected)
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selectedStashHash == nil || model.isGitBusy)
                .help(text("丢弃所选 Stash (Drop)", "Drop selected stash"))

                Spacer()

                Button {
                    if let project = model.selectedProject {
                        Task { await model.refreshProject(project) }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isGitBusy)
                .help(text("刷新", "Refresh"))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(WorkbenchChrome.bar)

            Rectangle().fill(WorkbenchChrome.subtleDivider).frame(height: 0.5)

            if model.gitStashes.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "archivebox")
                        .font(.system(size: 28))
                        .foregroundStyle(.quaternary)
                    Text(text("暂无储藏记录", "No Stashes"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    if !model.gitChanges.isEmpty {
                        Button(text("保存当前更改到 Stash…", "Save current changes to Stash…")) {
                            showCreateStashPopover = true
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedStashHash) {
                    ForEach(model.gitStashes) { stash in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: "archivebox")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.accentColor)
                                Text(stash.reference)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                Spacer()
                            }
                            Text(stash.message)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 3)
                        .tag(stash.hash)
                        .contextMenu {
                            Button(text("应用此 Stash (Apply)", "Apply Stash")) {
                                model.stashAction(.apply, stash: stash)
                            }
                            Button(text("弹出此 Stash (Pop)", "Pop Stash")) {
                                model.gitAction(.stashPop)
                            }
                            Divider()
                            Button(text("丢弃此 Stash (Drop)", "Drop Stash"), role: .destructive) {
                                model.stashAction(.drop, stash: stash)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .onChange(of: selectedStashHash) { hash in
                    loadStashDiff(hash: hash)
                }
                .onAppear {
                    if selectedStashHash == nil { selectedStashHash = model.gitStashes.first?.hash }
                    loadStashDiff(hash: selectedStashHash)
                }

                if model.gitStashes.contains(where: { $0.hash == selectedStashHash }) {
                    Rectangle().fill(WorkbenchChrome.subtleDivider).frame(height: 1)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(text("修改预览", "Diff preview"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if loadingStashDiff {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        .padding(.horizontal, 8).padding(.top, 4)

                        ScrollView {
                            Text(stashDiffText.isEmpty ? text("无文本差异", "No text diff") : stashDiffText)
                                .font(.system(size: 10, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .textSelection(.enabled)
                        }
                        .background(WorkbenchChrome.editor)
                    }
                    .frame(height: 160)
                }
            }
        }
        .popover(isPresented: $showCreateStashPopover) {
            VStack(alignment: .leading, spacing: 10) {
                Text(text("保存更改到 Stash", "Stash Changes"))
                    .font(.system(size: 12, weight: .semibold))
                TextField(text("说明信息（可选）", "Message (optional)"), text: $newStashMessage)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                HStack {
                    Button(text("取消", "Cancel")) {
                        showCreateStashPopover = false
                        newStashMessage = ""
                    }
                    Spacer()
                    Button(text("保存", "Stash")) {
                        let msg = newStashMessage
                        showCreateStashPopover = false
                        newStashMessage = ""
                        model.saveStash(message: msg, includeUntracked: true, keepIndex: false) { _ in
                            if let project = model.selectedProject {
                                Task { await model.refreshProject(project) }
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(12)
        }
    }

    private func loadStashDiff(hash: String?) {
        guard let hash, let stash = model.gitStashes.first(where: { $0.hash == hash }), let path = model.selectedProject?.path else {
            stashDiffText = ""
            return
        }
        loadingStashDiff = true
        Task {
            let diff = await GitService.stashDiff(stash, at: path)
            await MainActor.run {
                if selectedStashHash == hash {
                    stashDiffText = diff
                    loadingStashDiff = false
                }
            }
        }
    }
}

struct GitChangeRowView: View {
    let change: GitChange
    let staged: Bool
    @ObservedObject var model: WorkbenchModel
    let onOpenWorkingFile: () -> Void
    let onPerformAction: (GitFileAction) -> Void
    let actionTitle: (GitFileAction) -> String

    @State private var isHovering = false

    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var filename: String { URL(fileURLWithPath: change.path).lastPathComponent }
    private var dir: String { change.path.contains("/") ? (change.path as NSString).deletingLastPathComponent : "" }

    private var textColor: Color {
        if change.isConflicted { return Color.red }
        if change.state == "??" { return Color(red: 0.88, green: 0.44, blue: 0.44) }
        if change.state.contains("M") || staged { return Color(red: 0.38, green: 0.68, blue: 1.0) }
        if change.state.contains("D") { return Color.secondary }
        return Color(nsColor: .labelColor)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.gitFileAction(staged ? .unstage : .stage, path: change.path)
            } label: {
                Image(systemName: staged ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundStyle(staged ? Color.accentColor : Color.secondary.opacity(0.72))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .disabled(model.isGitBusy || change.isConflicted)
            .help(text(staged ? "取消暂存" : "勾选以加入提交", staged ? "Unstage" : "Stage to include in commit"))

            GitFileIconView(path: change.path)

            Text(filename)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(textColor)
                .lineLimit(1)

            if !dir.isEmpty {
                Text(dir)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondary.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if change.isConflicted {
                Text("!").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.red)
            } else if isHovering && !model.isGitBusy {
                HStack(spacing: 3) {
                    Button {
                        model.gitFileAction(staged ? .unstage : .stage, path: change.path)
                    } label: {
                        Image(systemName: staged ? "minus" : "plus")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 15, height: 15)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                    .help(text(staged ? "取消暂存" : "暂存文件", staged ? "Unstage" : "Stage"))

                    if !staged {
                        Button {
                            onPerformAction(.discard)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 15, height: 15)
                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                        }
                        .buttonStyle(.plain)
                        .help(text("回滚工作区修改…", "Rollback working changes…"))
                    }

                    Button {
                        onOpenWorkingFile()
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 15, height: 15)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                    .help(text("打开工作区文件", "Open working file"))
                }
                .transition(.opacity)
            }
        }
        .frame(height: 21)
        .padding(.vertical, 0.5)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(change.displayPath)
        .contextMenu {
            Button(text("查看差异", "Show diff")) { model.openDiff(change, staged: staged) }
            Button(text("打开工作区文件", "Open working file")) { onOpenWorkingFile() }
            Divider()
            Button(actionTitle(staged ? .unstage : .stage)) { onPerformAction(staged ? .unstage : .stage) }.disabled(model.isGitBusy || change.isConflicted)
            if change.state == "??", URL(fileURLWithPath: change.path).lastPathComponent != ".gitignore" {
                Button(text("忽略此文件", "Ignore this file")) { model.ignoreUntrackedFile(change.path) }.disabled(model.isGitBusy)
            }
            if change.isConflicted {
                Button(text("保留当前分支版本", "Keep ours")) { model.resolveConflict(change, using: .ours) }
                Button(text("保留对方版本", "Keep theirs")) { model.resolveConflict(change, using: .theirs) }
            }
            if !staged && !change.isConflicted {
                Button(actionTitle(.discard), role: .destructive) { onPerformAction(.discard) }.disabled(model.isGitBusy)
            }
        }
    }
}

/// JetBrains-style compact file badges and language icons
struct GitFileIconView: View {
    let path: String

    var body: some View {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let filename = URL(fileURLWithPath: path).lastPathComponent

        switch ext {
        case "php":
            if filename.contains("Controller") || filename.contains("Service") || filename.contains("Model") || filename.contains("Repository") || filename.hasSuffix(".class.php") {
                ZStack {
                    Circle().fill(Color(red: 0.25, green: 0.52, blue: 0.95))
                    Text("C").font(.system(size: 7.5, weight: .bold, design: .rounded)).foregroundStyle(.white)
                }
                .frame(width: 14, height: 14)
            } else if filename.contains("Test") {
                ZStack(alignment: .topTrailing) {
                    Circle().fill(Color(red: 0.25, green: 0.52, blue: 0.95))
                        .frame(width: 13, height: 13)
                    Text("C").font(.system(size: 7, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Circle().fill(Color.green).frame(width: 4, height: 4).offset(x: 2, y: -2)
                }
                .frame(width: 15, height: 14)
            } else {
                Text("php")
                    .font(.system(size: 7, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 2.5)
                    .padding(.vertical, 0.8)
                    .background(Color(red: 0.46, green: 0.48, blue: 0.74), in: RoundedRectangle(cornerRadius: 2.5))
            }
        case "js":
            Text("JS")
                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                .foregroundStyle(Color(red: 0.15, green: 0.15, blue: 0.15))
                .padding(.horizontal, 2.5)
                .padding(.vertical, 0.8)
                .background(Color(red: 0.96, green: 0.85, blue: 0.20), in: RoundedRectangle(cornerRadius: 2.5))
        case "ts":
            Text("TS")
                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 2.5)
                .padding(.vertical, 0.8)
                .background(Color(red: 0.18, green: 0.45, blue: 0.78), in: RoundedRectangle(cornerRadius: 2.5))
        case "vue":
            Text("V")
                .font(.system(size: 7.5, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 0.5)
                .background(Color(red: 0.25, green: 0.72, blue: 0.51), in: RoundedRectangle(cornerRadius: 2.5))
        case "swift":
            Image(systemName: "swift")
                .font(.system(size: 11))
                .foregroundStyle(Color.orange)
                .frame(width: 14, height: 14)
        case "py":
            Text("py")
                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 2.5)
                .padding(.vertical, 0.8)
                .background(Color(red: 0.22, green: 0.45, blue: 0.65), in: RoundedRectangle(cornerRadius: 2.5))
        case "go":
            Text("GO")
                .font(.system(size: 6.5, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 2)
                .padding(.vertical, 0.8)
                .background(Color(red: 0.0, green: 0.65, blue: 0.85), in: RoundedRectangle(cornerRadius: 2.5))
        case "json", "yaml", "yml":
            Image(systemName: "curlybraces.square")
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.95, green: 0.75, blue: 0.25))
                .frame(width: 14, height: 14)
        case "md", "markdown":
            Image(systemName: "doc.richtext")
                .font(.system(size: 11))
                .foregroundStyle(Color.blue.opacity(0.8))
                .frame(width: 14, height: 14)
        case "html":
            Text("<>")
                .font(.system(size: 6.5, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 2)
                .padding(.vertical, 0.8)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 2.5))
        case "css", "scss", "less":
            Text("#")
                .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 0.5)
                .background(Color.cyan, in: RoundedRectangle(cornerRadius: 2.5))
        case "sql":
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 11))
                .foregroundStyle(Color.purple)
                .frame(width: 14, height: 14)
        default:
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary)
                .frame(width: 14, height: 14)
        }
    }
}

struct GitDiffWorkspace: View {
    @ObservedObject var model: WorkbenchModel
    @AppStorage("splitGitDiff") private var split = true
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var change: GitChange? {
        guard model.historyCommit == nil, let root = model.selectedProject?.path, model.selectedFile.hasPrefix(root + "/") else { return nil }
        return model.gitChanges.first { $0.path == String(model.selectedFile.dropFirst(root.count + 1)) }
    }
    private var entries: [GitChangeSelection] {
        model.gitChanges.filter(\.isStaged).map { GitChangeSelection(path: $0.path, staged: true) } + model.gitChanges.filter(\.isUnstaged).map { GitChangeSelection(path: $0.path, staged: false) }
    }
    private var index: Int? { guard let change else { return nil }; return entries.firstIndex(of: GitChangeSelection(path: change.path, staged: model.diffIsStaged)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let hash = model.historyCommit {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                    Text(text("提交", "Commit") + " " + String(hash.prefix(8))).font(.system(size: 11, design: .monospaced))
                    Spacer()
                    if FileManager.default.fileExists(atPath: model.selectedFile) {
                        Button(text("打开工作区文件", "Open working file")) { model.openFilePath(model.selectedFile) }
                    }
                } else {
                    Button { move(-1) } label: { Image(systemName: "chevron.up") }.disabled(index == nil || index == 0).help(text("上一个文件", "Previous file"))
                    Button { move(1) } label: { Image(systemName: "chevron.down") }.disabled(index == nil || index == entries.count - 1).help(text("下一个文件", "Next file"))
                    if let index { Text("\(index + 1)/\(entries.count)").font(.system(size: 10)).foregroundStyle(.secondary) }
                    Divider().frame(height: 14)
                    if let change {
                        Picker("", selection: Binding(get: { model.diffIsStaged }, set: { model.openDiff(change, staged: $0) })) {
                            if change.isUnstaged { Text(text("工作区", "Working tree")).tag(false) }
                            if change.isStaged { Text(text("暂存区", "Staged")).tag(true) }
                        }.pickerStyle(.segmented).frame(maxWidth: 160).controlSize(.small)
                        Text(model.diffIsStaged ? "HEAD → Index" : change.state == "??" ? text("未跟踪文件", "Untracked file") : "Index → Working Tree").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        Button { model.openFilePath(model.selectedFile) } label: { Image(systemName: "doc.text") }.help(text("打开工作区文件", "Open working file"))
                        Button(model.diffIsStaged ? text("取消暂存", "Unstage") : text("暂存", "Stage")) { model.gitFileAction(model.diffIsStaged ? .unstage : .stage, path: change.path) }
                            .disabled(model.isGitBusy || change.isConflicted).controlSize(.small)
                    } else { Spacer() }
                }
                Picker("", selection: $split) {
                    Image(systemName: "rectangle.split.2x1").accessibilityLabel(text("双栏差异", "Side by side diff")).tag(true)
                    Image(systemName: "list.bullet").accessibilityLabel(text("统一差异", "Unified diff")).tag(false)
                }.pickerStyle(.segmented).frame(width: 64).controlSize(.small).help(text("双栏／统一差异", "Side by side / unified diff"))
            }.font(.system(size: 11)).buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 7)
            Divider().opacity(0.4)
            GitStructuredDiff(content: model.diffContent, language: model.language, split: split, canApply: !model.isGitBusy && change.map { [" M", "M ", "MM"].contains($0.state) } == true, staged: model.diffIsStaged, oldLabel: model.historyCommit == nil ? (model.diffIsStaged ? "HEAD" : "Index") : text("父提交", "Parent"), newLabel: model.historyCommit.map { String($0.prefix(8)) } ?? (model.diffIsStaged ? "Index" : text("工作区", "Working tree")), codeLanguage: URL(fileURLWithPath: model.selectedFile).pathExtension.lowercased(), discard: { index, expected in
                if let change { model.discardDiffHunk(index, file: change.path, expectedDiff: expected) }
            }) { index, expected, staged in
                if let change { model.applyDiffHunk(index, file: change.path, expectedDiff: expected, staged: staged) }
            }
        }
    }
    private func move(_ offset: Int) {
        guard let index, entries.indices.contains(index + offset) else { return }
        let entry = entries[index + offset]
        if let target = model.gitChanges.first(where: { $0.path == entry.path }) { model.openDiff(target, staged: entry.staged) }
    }
}

/// Use native controls for group actions instead of disabled section-header content.
private struct GitChangesIconButton: NSViewRepresentable {
    let symbol: String
    let label: String
    var enabled = true
    let action: () -> Void
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func invoke(_ sender: NSButton) { action() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = context.coordinator
        button.action = #selector(Coordinator.invoke(_:))
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.isEnabled = enabled
    }
}
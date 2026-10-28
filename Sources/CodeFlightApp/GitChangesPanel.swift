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
    @State private var selection: Set<GitChangeSelection> = []
    @State private var search = ""
    @AppStorage("layout.gitChanges.stagedExpanded") private var stagedExpanded = true
    @AppStorage("layout.gitChanges.unstagedExpanded") private var unstagedExpanded = true
    @FocusState private var messageFocused: Bool
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var staged: [GitChange] { model.gitChanges.filter { $0.isStaged && matches($0) } }
    private var unstaged: [GitChange] { model.gitChanges.filter { $0.isUnstaged && !$0.isConflicted && matches($0) } }
    private var conflicted: [GitChange] { model.gitChanges.filter { $0.isConflicted && matches($0) } }
    private var canCommit: Bool { !model.isGitBusy && model.gitChanges.contains(where: \.isStaged) && !model.gitChanges.contains(where: \.isConflicted) && !model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func matches(_ change: GitChange) -> Bool { search.isEmpty || change.displayPath.localizedCaseInsensitiveContains(search) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(text("提交", "Commit")).font(.system(size: 12, weight: .semibold))
                Text("\(model.gitChanges.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { if let project = model.selectedProject { Task { await model.refreshProject(project) } } } label: { Image(systemName: "arrow.clockwise") }
                    .help(text("刷新更改", "Refresh changes"))
                Menu {
                    Button(text("修改最近一次提交…", "Amend last commit…")) { showAmendSheet = true }
                        .disabled(model.gitCommits.isEmpty || model.gitOperationState != nil || model.gitChanges.contains(where: \.isConflicted))
                    Divider()
                    Button(text("暂存全部", "Stage all")) { model.gitAction(.stageAll) }
                    Button(text("取消全部暂存", "Unstage all")) { model.gitAction(.unstageAll) }
                    Divider()
                    Button(text("保存到 Stash…", "Stash changes…")) { showStashSheet = true }
                    Button(text("恢复最近 Stash", "Pop latest stash")) { model.gitAction(.stashPop) }
                    Button(text("管理 Stash…", "Manage stashes…")) { showStashSheet = true }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().disabled(model.isGitBusy || !model.isGitRepository)
            }.buttonStyle(.plain).padding(.horizontal, 12).frame(height: WorkbenchChrome.rowHeight)
                .background(WorkbenchChrome.raised)
            Rectangle().fill(WorkbenchChrome.quietSeparator).frame(height: 1)
            panelContent.padding(.horizontal, 12).padding(.vertical, 10)
        }.frame(maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showStashSheet) { StashSheet(model: model) }
        .sheet(isPresented: $showAmendSheet) { GitAmendSheet(model: model) }
        .onReceive(NotificationCenter.default.publisher(for: WorkbenchLayout.didReset)) { _ in
            stagedExpanded = true
            unstagedExpanded = true
        }
        .onChange(of: selection) { values in
            guard values.count == 1, let value = values.first, let change = model.gitChanges.first(where: { $0.path == value.path }) else { return }
            model.openDiff(change, staged: value.staged)
            if model.selectedFile != model.selectedProject.map({ URL(fileURLWithPath: $0.path).appendingPathComponent(value.path).path }) { syncSelection() }
        }
        .onChange(of: model.selectedProjectID) { _ in selection = []; search = "" }
        .onChange(of: search) { _ in pruneSelection() }
        .onChange(of: stagedExpanded) { _ in pruneSelection() }
        .onChange(of: unstagedExpanded) { _ in pruneSelection() }
        .onChange(of: model.gitChanges.map { $0.path + "\0" + $0.state }) { _ in pruneSelection() }
        .onChange(of: model.selectedFile) { _ in syncSelection() }
        .onChange(of: model.diffIsStaged) { _ in syncSelection() }
        .onChange(of: model.historyCommit) { _ in syncSelection() }
        .onAppear { syncSelection() }
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = model.gitStatusError {
                Label(text("无法读取 Git 状态", "Cannot read Git status"), systemImage: "exclamationmark.triangle").font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 6)
                Spacer()
            } else if model.isGitRepository {
                syncToolbar
                if let tracking = model.gitTracking { GitTrackingSummary(tracking: tracking, language: model.language).padding(.top, 6) }
                if model.gitOperationState != nil || model.gitChanges.contains(where: \.isConflicted) { operationBanner.padding(.top, 10) }
                Divider().padding(.vertical, 9)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField(text("筛选更改文件", "Filter changed files"), text: $search).textFieldStyle(.plain)
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
                }.font(.system(size: 11)).padding(6).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                WorkbenchSplit("changes.commit", axis: .horizontal, initial: 160,
                               minimum: 140, otherMinimum: 55, resizesSecond: true) {
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
                    commitArea.padding(.top, 10)
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

    private var syncToolbar: some View {
        HStack(spacing: 12) {
            Button { model.gitAction(.fetch) } label: { Image(systemName: "arrow.clockwise.icloud") }.help(text("获取远程更新（Fetch）", "Fetch remote updates"))
                .contextMenu { Button(text("选择远程仓库／身份验证…", "Remote / authentication…")) { model.gitSyncKind = .fetch } }
            Button { model.gitAction(.pull) } label: { Label(text("拉取", "Pull"), systemImage: "arrow.down") }
            Button { model.gitAction(.push) } label: { Label(text("推送", "Push"), systemImage: "arrow.up") }
            Spacer(minLength: 0)
            if model.isGitBusy { ProgressView().controlSize(.mini) }
        }.buttonStyle(.borderless).font(.system(size: 11)).disabled(model.isGitBusy)
    }

    private var changesList: some View {
        List(selection: $selection) {
            if !conflicted.isEmpty {
                Section {
                    ForEach(conflicted) { change in changeRow(change, staged: false).tag(GitChangeSelection(path: change.path, staged: false)) }
                } header: { Label(text("冲突", "Conflicts") + " (\(conflicted.count))", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.system(size: 11)) }
            }
            if !staged.isEmpty {
                groupLabel(text("已暂存", "Staged"), count: staged.count, expanded: $stagedExpanded, action: .unstageAll, icon: "minus", help: text("取消此组暂存", "Unstage this group"))
                    .listRowSeparator(.hidden)
                if stagedExpanded { ForEach(staged) { change in changeRow(change, staged: true).tag(GitChangeSelection(path: change.path, staged: true)) } }
            }
            if !unstaged.isEmpty {
                groupLabel(text("未暂存", "Unstaged"), count: unstaged.count, expanded: $unstagedExpanded, action: .stageAll, icon: "plus", help: text("暂存此组", "Stage this group"))
                    .listRowSeparator(.hidden)
                if unstagedExpanded { ForEach(unstaged) { change in changeRow(change, staged: false).tag(GitChangeSelection(path: change.path, staged: false)) } }
            }
            if staged.isEmpty && unstaged.isEmpty && conflicted.isEmpty { Text(text("没有匹配的文件", "No matching files")).font(.caption).foregroundStyle(.secondary) }
        // The sidebar list style intentionally mutes every row on macOS, which
        // makes the commit view look disabled in the light appearance. An inset
        // list keeps the compact Xcode spacing while preserving normal label
        // contrast for staged and unstaged files.
        }.listStyle(.inset).scrollContentBackground(.hidden)
            .padding(.horizontal, -10).padding(.vertical, 4)
    }

    private func groupLabel(_ title: String, count: Int, expanded: Binding<Bool>, action: GitAction, icon: String, help: String) -> some View {
        HStack(spacing: 5) {
            GitChangesIconButton(symbol: expanded.wrappedValue ? "chevron.down" : "chevron.right", label: (expanded.wrappedValue ? text("收起", "Collapse ") : text("展开", "Expand ")) + title) { expanded.wrappedValue.toggle() }.frame(width: 16, height: 20)
            Text(title).font(.system(size: 11, weight: .medium))
            Text("\(count)").font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            GitChangesIconButton(symbol: icon, label: help, enabled: !model.isGitBusy) { model.gitBatchFileAction(action == .stageAll ? .stage : .unstage, changes: action == .stageAll ? unstaged : staged) }.frame(width: 20, height: 20)
        }.accessibilityElement(children: .contain)
    }

    private func changeRow(_ change: GitChange, staged: Bool) -> some View {
        HStack(spacing: 6) {
            Toggle(text(staged ? "取消暂存" : "暂存文件", staged ? "Unstage file" : "Stage file") + " " + change.path,
                   isOn: Binding(get: { staged }, set: { _ in model.gitFileAction(staged ? .unstage : .stage, path: change.path) }))
                .toggleStyle(.checkbox).labelsHidden().controlSize(.small).disabled(model.isGitBusy || change.isConflicted)
                .help(text(staged ? "取消暂存" : "勾选暂存，加入提交", staged ? "Unstage" : "Stage to include in commit"))
            Image(systemName: change.isConflicted ? "exclamationmark.triangle" : "doc.text").font(.system(size: 11)).foregroundStyle(change.isConflicted ? Color.red : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: change.path).lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if change.path.contains("/") {
                    Text((change.path as NSString).deletingLastPathComponent).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            Text(change.isConflicted ? "!" : change.displayState).font(.system(size: 10, design: .monospaced)).foregroundStyle(selection.contains(GitChangeSelection(path: change.path, staged: staged)) ? Color.primary : change.isConflicted ? Color.red : change.state == "??" ? Color.secondary : Color.accentColor)
        }
        // SwiftUI's sidebar list applies a secondary tint to row content on macOS.
        // Keep the filename itself at the primary label contrast so changed files
        // remain readable in the light theme; path context and status still use
        // their intentionally softer/semantic colors above.
        .foregroundStyle(.primary)
        .padding(.vertical, 2).contentShape(Rectangle()).help(change.displayPath)
            .contextMenu {
                Button(text("查看差异", "Show diff")) { model.openDiff(change, staged: staged) }
                Button(text("打开工作区文件", "Open working file")) { openWorkingFile(change) }
                Divider()
                Button(actionTitle(staged ? .unstage : .stage, clicked: change, staged: staged)) { perform(staged ? .unstage : .stage, clicked: change, staged: staged) }.disabled(model.isGitBusy || change.isConflicted)
                if change.state == "??", URL(fileURLWithPath: change.path).lastPathComponent != ".gitignore" {
                    Button(text("忽略此文件", "Ignore this file")) { model.ignoreUntrackedFile(change.path) }.disabled(model.isGitBusy)
                }
                if change.isConflicted {
                    Button(text("保留当前分支版本", "Keep ours")) { model.resolveConflict(change, using: .ours) }
                    Button(text("保留对方版本", "Keep theirs")) { model.resolveConflict(change, using: .theirs) }
                }
                if !staged && !change.isConflicted {
                    Button(actionTitle(.discard, clicked: change, staged: staged), role: .destructive) { perform(.discard, clicked: change, staged: staged) }.disabled(model.isGitBusy)
                }
            }
    }

    private var commitArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(text("提交消息", "Commit message")).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(text("\(model.gitChanges.filter(\.isStaged).count) 个文件", "\(model.gitChanges.filter(\.isStaged).count) files")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.commitMessage).font(.system(size: 12)).focused($messageFocused)
                    .scrollContentBackground(.hidden).padding(4)
                if model.commitMessage.isEmpty { Text(text("输入本次修改的说明…", "Describe your changes…")).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.top, 8).allowsHitTesting(false) }
            }.frame(maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(messageFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12)))
            if model.gitChanges.contains(where: \.isConflicted) {
                Text(text("请先解决冲突，再提交。", "Resolve conflicts before committing.")).font(.system(size: 10)).foregroundStyle(.orange)
            }
            HStack(spacing: 5) {
                Button { model.commitChanges() } label: { Text(text("提交", "Commit")).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                Menu {
                    Button(text("提交并推送…", "Commit and push…")) { model.commitChanges(pushAfter: true) }
                } label: { Image(systemName: "chevron.down").font(.system(size: 9)) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.horizontal, 5)
            }.controlSize(.small).disabled(!canCommit)
            Text(text("勾选文件加入提交 · ⌘↩ 提交", "Check files to stage · ⌘↩ Commit")).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    private var visibleSelections: Set<GitChangeSelection> {
        Set((stagedExpanded ? staged : []).map { GitChangeSelection(path: $0.path, staged: true) } + ((unstagedExpanded ? unstaged : []) + conflicted).map { GitChangeSelection(path: $0.path, staged: false) })
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

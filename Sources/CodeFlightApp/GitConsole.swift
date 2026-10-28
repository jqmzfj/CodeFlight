import SwiftUI
import AppKit

struct GitConsoleReference: Equatable {
    let projectID: UUID
    let entryID: UUID
}

struct GitConsoleEntry: Identifiable {
    let id = UUID()
    let title: String
    let startedAt = Date()
    var endedAt: Date?
    var status: Int32?
    var output = ""
    var truncated = false
    var isRunning: Bool { status == nil }
    func summary(_ language: AppLanguage) -> String {
        if isRunning { return Copy.t("正在执行…", "Working…", language: language) }
        return status == 0 ? Copy.t("已完成", "Completed", language: language) : Copy.t("失败，退出码 ", "Failed, exit code ", language: language) + String(status ?? -1)
    }
}

extension WorkbenchModel {
    var selectedGitConsoleEntry: GitConsoleEntry? {
        guard let projectID = selectedProjectID else { return nil }
        let entries = gitConsoleEntries[projectID, default: []]
        return entries.first { $0.id == selectedGitConsoleEntryIDs[projectID] } ?? entries.last
    }

    @discardableResult
    func beginGitConsoleEntry(projectID: UUID, title: String) -> UUID {
        let entry = GitConsoleEntry(title: title)
        gitConsoleEntries[projectID, default: []].append(entry)
        selectedGitConsoleEntryIDs[projectID] = entry.id
        trimGitConsole(projectID: projectID)
        return entry.id
    }

    func finishGitConsoleEntry(_ id: UUID, projectID: UUID, result: CommandResult, presentError: Bool) {
        guard projects.contains(where: { $0.id == projectID }),
              let index = gitConsoleEntries[projectID]?.firstIndex(where: { $0.id == id }) else { return }
        let output = result.output.isEmpty
            ? Copy.t(result.status == 0 ? "Git 操作完成。" : "Git 操作失败。", result.status == 0 ? "Git operation completed." : "Git operation failed.", language: language)
            : GitDiagnosticRedactor.redact(result.output)
        gitConsoleEntries[projectID]?[index].output = String(String.UnicodeScalarView(output.unicodeScalars.suffix(12_000)))
        gitConsoleEntries[projectID]?[index].truncated = result.truncated || output.unicodeScalars.count > 12_000
        gitConsoleEntries[projectID]?[index].status = result.status
        gitConsoleEntries[projectID]?[index].endedAt = Date()
        trimGitConsole(projectID: projectID)
        guard selectedProjectID == projectID else { return }
        gitLastResult = result.status == 0 ? Copy.t("Git 操作完成", "Git operation completed", language: language) : Copy.t("Git 操作未完成", "Git operation failed", language: language)
        if presentError {
            errorMessage = result.status != 0 ? String(output.prefix(2000)) : nil
            if result.status != 0 { errorConsoleReference = GitConsoleReference(projectID: projectID, entryID: id) }
        }
    }

    func selectGitConsoleEntry(_ id: UUID) {
        guard let projectID = selectedProjectID, gitConsoleEntries[projectID]?.contains(where: { $0.id == id }) == true else { return }
        selectedGitConsoleEntryIDs[projectID] = id
    }

    func removeGitConsoleEntry(_ id: UUID) {
        guard let projectID = selectedProjectID,
              gitConsoleEntries[projectID]?.contains(where: { $0.id == id && !$0.isRunning }) == true else { return }
        gitConsoleEntries[projectID]?.removeAll { $0.id == id }
        if selectedGitConsoleEntryIDs[projectID] == id { selectedGitConsoleEntryIDs[projectID] = gitConsoleEntries[projectID]?.last?.id }
    }

    func clearGitConsole() {
        guard let projectID = selectedProjectID else { return }
        gitConsoleEntries[projectID]?.removeAll { !$0.isRunning }
        selectedGitConsoleEntryIDs[projectID] = gitConsoleEntries[projectID]?.last?.id
    }

    func revealErrorInConsole() {
        guard let projectID = selectedProjectID, let message = errorMessage else { return }
        if let reference = errorConsoleReference, reference.projectID == projectID,
           gitConsoleEntries[projectID]?.contains(where: { $0.id == reference.entryID }) == true {
            selectedGitConsoleEntryIDs[projectID] = reference.entryID
        } else {
            let id = beginGitConsoleEntry(projectID: projectID, title: Copy.t("诊断信息", "Diagnostic", language: language))
            finishGitConsoleEntry(id, projectID: projectID, result: CommandResult(output: message, status: 1), presentError: false)
        }
        errorMessage = nil
    }

    private func trimGitConsole(projectID: UUID) {
        var entries = gitConsoleEntries[projectID, default: []]
        var count = entries.reduce(0) { $0 + $1.output.unicodeScalars.count }
        while entries.count > 20 || count > 64_000 {
            guard let index = entries.firstIndex(where: { !$0.isRunning }) else { break }
            count -= entries[index].output.unicodeScalars.count
            entries.remove(at: index)
        }
        gitConsoleEntries[projectID] = entries
        if !entries.contains(where: { $0.id == selectedGitConsoleEntryIDs[projectID] }) { selectedGitConsoleEntryIDs[projectID] = entries.last?.id }
    }
}

enum GitConsoleTitle {
    static func title(_ source: String, language: AppLanguage) -> String {
        let name = String(source.prefix { $0 != "(" })
        let labels: [String: (String, String)] = [
            "checkoutBranch": ("切换分支", "Check out branch"), "checkoutRemoteBranch": ("切换远程分支", "Check out remote branch"),
            "createBranch": ("新建分支", "Create branch"), "deleteBranch": ("删除分支", "Delete branch"),
            "deleteRemoteBranch": ("删除远程分支", "Delete remote branch"), "renameBranch": ("重命名分支", "Rename branch"),
            "mergeBranch": ("合并分支", "Merge branch"), "rebaseBranch": ("变基", "Rebase"),
            "commitChanges": ("提交", "Commit"), "amendLastCommit": ("修改最近提交", "Amend commit"),
            "syncGit": ("远程同步", "Remote sync"), "gitAction": ("仓库操作", "Repository operation"),
            "gitFileAction": ("文件操作", "File operation"), "gitBatchFileAction": ("批量文件操作", "Batch file operation"),
            "initializeGit": ("初始化仓库", "Initialize repository"), "ignoreUntrackedFile": ("忽略文件", "Ignore file"),
            "gitAdvanced": ("Git 历史操作", "Git history operation"),
            "saveStash": ("保存暂存记录", "Save stash"), "stashAction": ("暂存记录操作", "Stash operation"),
            "remoteAction": ("管理远程仓库", "Manage remotes"), "setUpstream": ("设置上游", "Set upstream"),
            "createManagedTag": ("新建标签", "Create tag"), "deleteManagedTag": ("删除标签", "Delete tag"),
            "pushManagedTag": ("推送标签", "Push tag"), "checkoutManagedTag": ("切换标签", "Check out tag"),
            "interactiveRebase": ("交互式变基", "Interactive rebase"),
            "startInteractiveRebase": ("交互式变基", "Interactive rebase"),
            "addSubmodule": ("添加子模块", "Add submodule"), "removeSubmodule": ("移除子模块", "Remove submodule"),
            "submodule.update": ("更新子模块", "Update submodules"), "submodule.sync": ("同步子模块地址", "Sync submodule URLs"),
            "moveWorktree": ("移动工作树", "Move worktree"), "setWorktreeLocked": ("设置工作树锁定", "Set worktree lock"),
            "pruneWorktrees": ("清理工作树记录", "Prune worktrees"), "addWorktree": ("添加工作树", "Add worktree"), "removeWorktree": ("移除工作树", "Remove worktree"),
            "applyDiffHunk": ("暂存区修改块操作", "Update index hunk"), "discardDiffHunk": ("回滚修改块", "Revert hunk"),
            "saveConflictDocument": ("保存冲突结果", "Save conflict result"), "resolveConflict": ("选择冲突版本", "Choose conflict side"),
            "markConflictResolved": ("标记冲突已解决", "Mark conflict resolved"),
            "action.fetch": ("获取远程更新", "Fetch"), "action.stageAll": ("暂存全部", "Stage all"), "action.unstageAll": ("取消全部暂存", "Unstage all"),
            "action.stashSave": ("保存 Stash", "Save stash"), "action.stashPop": ("弹出 Stash", "Pop stash"), "action.stashApply": ("应用 Stash", "Apply stash"),
            "action.stashDrop": ("删除 Stash", "Drop stash"), "action.cleanPreview": ("预览清理文件", "Preview clean"),
            "file.stage": ("暂存文件", "Stage file"), "file.unstage": ("取消文件暂存", "Unstage file"), "file.discard": ("丢弃文件修改", "Discard file changes"),
            "batch.stage": ("批量暂存", "Stage selected files"), "batch.unstage": ("批量取消暂存", "Unstage selected files"), "batch.discard": ("批量丢弃修改", "Discard selected changes"),
            "stash.apply": ("应用 Stash", "Apply stash"), "stash.drop": ("删除 Stash", "Drop stash"),
            "remote.add": ("添加远程仓库", "Add remote"), "remote.remove": ("移除远程仓库", "Remove remote"), "remote.setURL": ("修改远程地址", "Change remote URL"),
            "sync.fetch": ("获取远程更新", "Fetch"), "sync.push": ("推送", "Push"), "sync.pull": ("拉取", "Pull"),
            "advanced.revert": ("还原提交", "Revert commit"), "advanced.cherryPick": ("拣选提交", "Cherry-pick commit"),
            "advanced.resetSoft": ("软重置", "Soft reset"), "advanced.resetMixed": ("混合重置", "Mixed reset"), "advanced.resetHard": ("硬重置", "Hard reset"),
            "advanced.tagCreate": ("新建标签", "Create tag"), "advanced.tagDelete": ("删除标签", "Delete tag"),
            "advanced.rebaseContinue": ("继续变基", "Continue rebase"), "advanced.rebaseAbort": ("中止变基", "Abort rebase"), "advanced.rebaseSkip": ("跳过变基提交", "Skip rebase commit"),
            "advanced.mergeContinue": ("继续合并", "Continue merge"), "advanced.mergeAbort": ("中止合并", "Abort merge"),
            "advanced.cherryPickContinue": ("继续拣选", "Continue cherry-pick"), "advanced.cherryPickAbort": ("中止拣选", "Abort cherry-pick"), "advanced.cherryPickSkip": ("跳过拣选提交", "Skip cherry-pick commit"),
            "advanced.revertContinue": ("继续还原", "Continue revert"), "advanced.revertAbort": ("中止还原", "Abort revert"), "advanced.revertSkip": ("跳过还原提交", "Skip revert commit")
        ]
        let label = labels[name] ?? ("Git 操作", "Git operation")
        return Copy.t(label.0, label.1, language: language)
    }
}

struct ConsoleTool: View {
    @ObservedObject var model: WorkbenchModel
    @State private var search = ""
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var entries: [GitConsoleEntry] { model.selectedProjectID.flatMap { model.gitConsoleEntries[$0] } ?? [] }

    var body: some View {
        WorkbenchSplit("console.operations", initial: 220, minimum: 180, otherMinimum: 300) {
            List(selection: Binding(get: { model.selectedGitConsoleEntry?.id }, set: { if let id = $0 { model.selectGitConsoleEntry(id) } })) {
                ForEach(entries.reversed()) { entry in
                    HStack(spacing: 7) {
                        if entry.isRunning { ProgressView().controlSize(.mini) }
                        else { Image(systemName: entry.status == 0 ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(entry.status == 0 ? Color.green : .orange) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            HStack(spacing: 5) { Text(entry.startedAt, style: .time); Text(entry.summary(model.language)) }
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.tag(entry.id)
                    .contextMenu { Button(text("删除记录", "Remove entry")) { model.removeGitConsoleEntry(entry.id) }.disabled(entry.isRunning) }
                }
                if entries.isEmpty { Text(text("暂无操作记录", "No operation history")).font(.caption).foregroundStyle(.secondary) }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
        } second: {
            if let entry = model.selectedGitConsoleEntry {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text(entry.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Text(entry.summary(model.language)).font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.output, forType: .string) } label: { Image(systemName: "doc.on.doc") }.disabled(entry.output.isEmpty).help(text("复制输出", "Copy output"))
                        Button { model.removeGitConsoleEntry(entry.id) } label: { Image(systemName: "trash") }.disabled(entry.isRunning).help(text("删除当前记录", "Remove current entry"))
                    }.buttonStyle(.plain).padding(10)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(text("筛选输出", "Filter output"), text: $search).textFieldStyle(.plain)
                        if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                    }.font(.system(size: 10)).padding(.horizontal, 10).padding(.bottom, 6)
                    if entry.truncated { Text(text("输出过长，仅保留末尾部分。", "Output truncated; showing the last portion.")).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10) }
                    Divider()
                    RunLogView(output: search.isEmpty ? entry.output : entry.output.components(separatedBy: .newlines).filter { $0.localizedCaseInsensitiveContains(search) }.joined(separator: "\n"), followsOutput: false, sessionID: entry.id, accessibilityLabel: "Git 控制台 / Git console")
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "terminal").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text(text("Git 操作与诊断信息显示在这里", "Git operations and diagnostics appear here")).font(.caption).foregroundStyle(.secondary)
                    Text(text("运行输出请查看“运行进程”", "View command output in Processes")).font(.caption2).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.onChange(of: model.selectedProjectID) { _ in search = "" }
        .onChange(of: model.selectedGitConsoleEntry?.id) { _ in search = "" }
    }
}

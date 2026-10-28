import Foundation
import AppKit

extension GitService {
    /// One index command per selection; preserve rename source paths and reject stale lists.
    static func batchFileAction(_ action: GitFileAction, changes expected: [GitChange], at root: String) async -> CommandResult {
        func failure(_ message: String) -> CommandResult { CommandResult(output: message, status: 1) }
        guard !expected.isEmpty else { return failure("请先选择文件。 / Select files first.") }
        let current = await status(at: root)
        guard current.isRepository, current.error == nil else { return failure(current.error ?? "无法读取仓库状态。 / Cannot read repository status.") }
        for change in expected {
            guard let live = current.changes.first(where: { $0.path == change.path }), live.state == change.state, live.originalPath == change.originalPath,
                  !live.isConflicted, action == .unstage ? live.isStaged : live.isUnstaged else {
                return failure("所选文件状态已改变或存在冲突，请刷新后重新选择。 / Selected file status changed or contains conflicts. Refresh and select again.")
            }
        }
        var paths = Set<String>()
        for change in expected {
            paths.insert(change.path)
            if let original = change.originalPath,
               (action == .unstage && change.state.first == "R") || (action == .stage && change.state.first != "R" && change.state.first != "C") { paths.insert(original) }
        }
        guard paths.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("/") && !$0.contains("\0") && !$0.split(separator: "/").contains("..") }) else { return failure("文件路径无效。 / Invalid file path.") }
        // Keep shell arguments bounded, with an explicit failure before any mutation.
        guard paths.reduce(0, { $0 + $1.utf8.count + 8 }) <= 60_000 else { return failure("所选路径过多，请分批操作。 / Too many selected paths; operate in smaller batches.") }
        let arguments = paths.sorted().map(Shell.quote).joined(separator: " ")
        switch action {
        case .stage:
            return await CommandRunner.run(command: "git --literal-pathspecs add -A -- \(arguments)", cwd: root)
        case .unstage:
            let hasHead = await CommandRunner.run(command: "git rev-parse --verify HEAD", cwd: root).status == 0
            return await CommandRunner.run(command: hasHead ? "git --literal-pathspecs restore --staged -- \(arguments)" : "git --literal-pathspecs rm -f --cached -- \(arguments)", cwd: root)
        case .discard:
            let tracked = expected.filter { $0.state != "??" }.map(\.path)
            let untracked = expected.filter { $0.state == "??" }.map(\.path)
            // A submodule is a repository, not a plain file to restore recursively.
            let index = await CommandRunner.run(command: "git --literal-pathspecs ls-files --stage -z -- \(arguments)", cwd: root, outputLimit: 4 * 1024 * 1024)
            guard index.status == 0, !index.truncated, !index.output.components(separatedBy: "\0").contains(where: { $0.hasPrefix("160000 ") }) else { return failure("所选项含子模块或无法读取索引，请单独处理。 / Selection contains a submodule or the index cannot be read. Handle it separately.") }
            if !tracked.isEmpty {
                let result = await CommandRunner.run(command: "git --literal-pathspecs restore --worktree -- \(tracked.map(Shell.quote).joined(separator: " "))", cwd: root)
                guard result.status == 0 else { return result }
            }
            if !untracked.isEmpty {
                let result = await CommandRunner.run(command: "git --literal-pathspecs clean -f -- \(untracked.map(Shell.quote).joined(separator: " "))", cwd: root)
                if result.status != 0 { return CommandResult(output: "部分已跟踪文件可能已回滚，请刷新检查。 / Some tracked files may have been restored. Refresh to inspect.\n" + result.output, status: result.status) }
                return result
            }
            return CommandResult(output: "已回滚所选工作区修改，暂存内容保留。 / Selected working changes restored; staged content kept.", status: 0)
        }
    }
}

extension WorkbenchModel {
    func gitBatchFileAction(_ action: GitFileAction, changes: [GitChange]) {
        guard let project = selectedProject, !isGitBusy, !changes.isEmpty, canLeaveConflict() else { return }
        if action == .discard {
            let alert = NSAlert()
            alert.messageText = Copy.t("回滚所选 \(changes.count) 个文件？", "Rollback \(changes.count) selected files?", language: language)
            alert.informativeText = changes.prefix(12).map(\.path).joined(separator: "\n") + (changes.count > 12 ? "\n…" : "") + "\n\n" + Copy.t("所选文件的未暂存修改将丢弃，未跟踪文件将删除。暂存内容保留。此操作无法通过 Git 撤销。", "Unstaged changes will be discarded and untracked files deleted. Staged content is kept. Git cannot undo this action.", language: language)
            alert.alertStyle = .warning
            alert.addButton(withTitle: Copy.t("取消", "Cancel", language: language)).keyEquivalent = "\u{1b}"
            alert.addButton(withTitle: Copy.t("回滚", "Rollback", language: language))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        runBatchGitOperation(project, action: action, changes: changes)
    }
}

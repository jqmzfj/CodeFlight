import Foundation

struct GitRebaseCommit: Identifiable, Equatable, Sendable {
    let hash: String
    let message: String
    var id: String { hash }
    var subject: String { message.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? "" }
}

enum GitRebaseAction: String, CaseIterable, Sendable {
    case pick, reword, squash, fixup, drop
    func title(_ language: AppLanguage) -> String {
        switch self {
        case .pick: return Copy.t("保留", "Pick", language: language)
        case .reword: return Copy.t("改写说明", "Reword", language: language)
        case .squash: return Copy.t("合并并保留说明", "Squash", language: language)
        case .fixup: return Copy.t("合并并丢弃说明", "Fixup", language: language)
        case .drop: return Copy.t("丢弃", "Drop", language: language)
        }
    }
}

struct GitRebaseStep: Identifiable, Equatable, Sendable {
    let commit: GitRebaseCommit
    var action: GitRebaseAction = .pick
    var message: String
    var id: String { commit.hash }
    init(commit: GitRebaseCommit) { self.commit = commit; message = commit.message }
}

struct GitRebaseSnapshot: Sendable {
    let base: String
    let head: String
    let branchRef: String
    let commits: [GitRebaseCommit]
    var steps: [GitRebaseStep] { commits.map { GitRebaseStep(commit: $0) } }
}

struct GitRebaseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension GitService {
    static func interactiveRebaseSnapshot(base reference: String, at path: String) async throws -> GitRebaseSnapshot {
        guard await operationState(at: path) == nil else {
            throw GitRebaseError(message: "请先完成或中止当前 Git 操作。 / Finish or abort the current Git operation first.")
        }
        let status = await status(at: path)
        guard status.isRepository, status.error == nil, status.changes.isEmpty else {
            throw GitRebaseError(message: status.error ?? "工作区和暂存区必须干净，请先提交或保存到 Stash。 / Commit or stash all working tree and index changes first.")
        }
        let branch = await CommandRunner.run(command: "git symbolic-ref -q HEAD", cwd: path)
        let branchRef = branch.output.trimmingCharacters(in: .newlines)
        guard branch.status == 0, branchRef.hasPrefix("refs/heads/"),
              let head = await commitHash("HEAD", at: path), let base = await commitHash(reference, at: path) else {
            throw GitRebaseError(message: "请选择本地分支及有效的基准提交；分离 HEAD 无法执行。 / Select a local branch and a valid base commit; detached HEAD is unsupported.")
        }
        let ancestor = await CommandRunner.run(command: "git merge-base --is-ancestor \(base) \(head)", cwd: path)
        guard ancestor.status == 0, base != head else {
            throw GitRebaseError(message: "基准必须是当前分支较早的祖先提交。所选提交本身不会被改写。 / Choose an earlier ancestor of the current branch. The base itself is not rewritten.")
        }
        let countResult = await CommandRunner.run(command: "git rev-list --count \(base)..\(head)", cwd: path)
        guard countResult.status == 0, let count = Int(countResult.output.trimmingCharacters(in: .whitespacesAndNewlines)), (1...200).contains(count) else {
            throw GitRebaseError(message: "一次最多编辑 200 个提交，请选择更近的基准。 / Choose a nearer base; at most 200 commits can be edited at once.")
        }
        let result = await CommandRunner.run(command: "git log --reverse --max-count=201 --format='%H%x00%P%x00%B%x00' \(base)..\(head) --", cwd: path, outputLimit: 2 * 1024 * 1024)
        guard result.status == 0, !result.truncated else {
            throw GitRebaseError(message: "无法读取变基范围，或提交说明超过 2 MB。 / Cannot read the rebase range, or messages exceed 2 MB.")
        }
        let fields = result.output.split(separator: "\0", omittingEmptySubsequences: false)
        var commits: [GitRebaseCommit] = []
        var previous = base
        for offset in stride(from: 0, to: fields.count - 1, by: 3) {
            guard offset + 2 < fields.count else { throw GitRebaseError(message: "提交记录不完整。 / Incomplete commit data.") }
            let hash = String(fields[offset]).trimmingCharacters(in: .newlines)
            let parents = fields[offset + 1].split(separator: " ").map(String.init)
            guard parents == [previous] else {
                throw GitRebaseError(message: "此范围包含合并提交。请选择合并之后的线性提交范围；当前编辑器不会展开或改写合并关系。 / This range contains merges. Choose a linear range after the merge.")
            }
            commits.append(GitRebaseCommit(hash: hash, message: String(fields[offset + 2]).trimmingCharacters(in: .newlines)))
            previous = hash
        }
        guard !commits.isEmpty, commits.count <= 200, previous == head else {
            throw GitRebaseError(message: "一次最多编辑 200 个提交，请选择更近的基准。 / Choose a nearer base; at most 200 commits can be edited at once.")
        }
        // Refuse a snapshot assembled across an external branch switch or commit.
        let finalBranch = await CommandRunner.run(command: "git symbolic-ref -q HEAD", cwd: path)
        let finalHead = await commitHash("HEAD", at: path)
        guard finalHead == head, finalBranch.output.trimmingCharacters(in: .newlines) == branchRef else {
            throw GitRebaseError(message: "分支已改变，请重新打开变基窗口。 / Branch changed. Reopen the rebase window.")
        }
        return GitRebaseSnapshot(base: base, head: head, branchRef: branchRef, commits: commits)
    }

    static func rebasePlanError(_ steps: [GitRebaseStep], snapshot: GitRebaseSnapshot) -> String? {
        guard steps.count == snapshot.commits.count,
              Set(steps.map(\.id)) == Set(snapshot.commits.map(\.id)), Set(steps.map(\.id)).count == steps.count else {
            return "提交列表已改变，请重新读取。 / The commit list changed. Reload it."
        }
        var kept = false
        for step in steps {
            if step.action == .drop { continue }
            if (step.action == .squash || step.action == .fixup) && !kept {
                return "第一个保留的提交不能合并到前一个提交，请调整顺序或操作。 / The first retained commit cannot squash or fixup. Change its action or order."
            }
            if step.action == .reword && (step.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || step.message.contains("\0") || step.message.utf8.count > 64 * 1024) {
                return "改写说明不能为空、包含空字符或超过 64 KB。 / Reword messages must be nonempty, contain no NUL, and stay within 64 KB."
            }
            kept = true
        }
        return nil
    }

    static func interactiveRebase(_ steps: [GitRebaseStep], snapshot: GitRebaseSnapshot, at path: String) async -> CommandResult {
        if let error = rebasePlanError(steps, snapshot: snapshot) { return CommandResult(output: error, status: 1) }
        do {
            let current = try await interactiveRebaseSnapshot(base: snapshot.base, at: path)
            guard current.head == snapshot.head, current.branchRef == snapshot.branchRef,
                  current.commits.map(\.hash) == snapshot.commits.map(\.hash) else {
                throw GitRebaseError(message: "分支或提交已改变，请关闭窗口并重新打开。 / Branch or commits changed. Reopen this window.")
            }
            var lines: [String] = []
            for step in steps {
                switch step.action {
                case .reword:
                    lines.append("pick \(step.id)")
                    // One physical todo line, including when the message contains
                    // quotes, newlines, shell syntax or Git instruction keywords.
                    let encoded = Data(step.message.utf8).base64EncodedString()
                    lines.append("exec printf %s \(Shell.quote(encoded)) | /usr/bin/base64 -D | git -c core.editor=true commit --amend --allow-empty --cleanup=verbatim --file=-")
                default: lines.append("\(step.action.rawValue) \(step.id)")
                }
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("git-workbench-rebase-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let todo = directory.appendingPathComponent("todo")
            let editor = directory.appendingPathComponent("sequence-editor")
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: todo)
            try Data(("#!/bin/sh\nexec /bin/cp \(Shell.quote(todo.path)) \"$1\"\n").utf8).write(to: editor)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: editor.path)
            let result = await CommandRunner.run(command: "git -c rebase.abbreviateCommands=false -c rebase.autoStash=false rebase --interactive --no-autosquash --no-autostash --no-update-refs --no-fork-point --no-rebase-merges --keep-empty --empty=keep --reapply-cherry-picks \(snapshot.base)", cwd: path, environment: ["GIT_SEQUENCE_EDITOR": Shell.quote(editor.path), "GIT_EDITOR": "true"])
            guard result.status == 0 else { return result }
            return CommandResult(output: "交互式变基完成 / Interactive rebase completed\n" + result.output, status: 0)
        } catch { return CommandResult(output: error.localizedDescription, status: 1) }
    }
}

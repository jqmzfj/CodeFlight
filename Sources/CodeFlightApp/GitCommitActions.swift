import Foundation

struct GitCommitTarget: Sendable {
    let hash: String
    let subject: String
    let parents: [String]
}

struct GitHistoryPrompt: Identifiable {
    let kind: GitPromptKind
    let commit: GitCommit
    var id: String { kind.rawValue + commit.hash }
}

extension GitService {
    static func commitTarget(_ reference: String, at path: String) async -> GitCommitTarget? {
        guard let hash = await commitHash(reference, at: path) else { return nil }
        let result = await CommandRunner.run(command: "git show -s --format='%P%x00%s' \(hash) --", cwd: path)
        guard result.status == 0, !result.truncated,
              let separator = result.output.firstIndex(of: "\0") else { return nil }
        return GitCommitTarget(hash: hash,
                               subject: String(result.output[result.output.index(after: separator)...]).trimmingCharacters(in: .newlines),
                               parents: result.output[..<separator].split(separator: " ").map(String.init))
    }

    static func revert(_ commit: String, mainline: Int? = nil, at path: String) async -> CommandResult {
        await applyCommit(commit, mainline: mainline, reverting: true, at: path)
    }

    static func cherryPick(_ commit: String, mainline: Int? = nil, at path: String) async -> CommandResult {
        await applyCommit(commit, mainline: mainline, reverting: false, at: path)
    }

    private static func applyCommit(_ reference: String, mainline: Int?, reverting: Bool, at path: String) async -> CommandResult {
        guard let target = await commitTarget(reference, at: path) else {
            return CommandResult(output: "无效的提交引用。 / Invalid commit reference.", status: 1)
        }
        guard await operationState(at: path) == nil else {
            return CommandResult(output: "请先完成或中止当前 Git 操作。 / Finish or abort the current Git operation first.", status: 1)
        }
        if target.parents.count > 1 {
            guard let mainline, (1...target.parents.count).contains(mainline) else {
                return CommandResult(output: "这是合并提交，请选择有效的主线父提交。 / This is a merge commit. Select a valid mainline parent.", status: 1)
            }
        } else if mainline != nil {
            return CommandResult(output: "普通提交无需选择主线父提交。 / A non-merge commit does not need a mainline parent.", status: 1)
        }
        let parent = mainline.map { "-m \($0) " } ?? ""
        let command = reverting ? "revert --no-edit" : "cherry-pick"
        return await CommandRunner.run(command: "git -c core.editor=true \(command) \(parent)\(target.hash)", cwd: path)
    }
}

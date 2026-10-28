import Foundation

struct GitCommitDetails: Sendable {
    var description = ""
    var files: [String] = []
    var error: String?
}

extension GitService {
    static func commitDetails(_ reference: String, at path: String, descriptionLimit: Int = 256 * 1024, fileLimit: Int = 2 * 1024 * 1024) async -> GitCommitDetails {
        guard let hash = await commitHash(reference, at: path) else {
            return GitCommitDetails(error: "无法读取此提交，提交可能已失效，请刷新历史后重试。 / Cannot read this commit. Refresh history and retry.")
        }
        let description = await CommandRunner.run(command: "git --no-pager show -s --format=fuller \(hash) --", cwd: path, outputLimit: descriptionLimit)
        guard description.status == 0, !description.truncated else {
            return GitCommitDetails(error: description.truncated ? "提交说明超过读取限制。 / Commit description exceeds the read limit." : description.output)
        }
        // Resolve once and use the same immutable commit for both commands.
        // A moved branch must not combine one commit's message with another's files.
        let files = await CommandRunner.run(command: "git diff-tree --root --diff-merges=first-parent -r --no-commit-id --name-only -z \(hash) --", cwd: path, outputLimit: fileLimit)
        guard files.status == 0, !files.truncated else {
            return GitCommitDetails(description: description.output, error: files.truncated ? "提交文件列表超过读取限制。 / Commit file list exceeds the read limit." : files.output)
        }
        return GitCommitDetails(description: description.output, files: Array(Set(files.output.split(separator: "\0").map(String.init))).sorted())
    }
}

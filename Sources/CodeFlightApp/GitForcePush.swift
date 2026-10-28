import Foundation

struct GitForcePushSnapshot: Sendable {
    let destination: GitRemoteBranchSnapshot
    let sourceBranch: String
    let sourceHash: String
}

extension GitService {
    static func forcePushSnapshot(remote: String, branch: String, at path: String) async -> GitForcePushSnapshot? {
        guard let destination = await remoteBranchSnapshot(remote + "/" + branch, at: path), destination.remote == remote, destination.branch == branch else { return nil }
        let info = await syncInfo(at: path)
        guard !info.branch.isEmpty, let source = await commitHash("refs/heads/" + info.branch, at: path) else { return nil }
        return GitForcePushSnapshot(destination: destination, sourceBranch: info.branch, sourceHash: source)
    }

    static func forcePush(_ snapshot: GitForcePushSnapshot, setUpstream: Bool, at path: String, credentials: GitCredentials = GitCredentials()) async -> CommandResult {
        let target = snapshot.destination
        guard let current = await forcePushSnapshot(remote: target.remote, branch: target.branch, at: path),
              current.sourceBranch == snapshot.sourceBranch, current.sourceHash == snapshot.sourceHash,
              current.destination.hash == target.hash, current.destination.pushURL == target.pushURL else {
            return CommandResult(output: "本地提交、分支或推送地址已改变，请重新打开推送窗口。 / Local commits, branch, or push URL changed. Reopen the push dialog.", status: 1)
        }
        let lease = "--force-with-lease=" + target.branchRef + ":" + target.hash
        let refspec = snapshot.sourceHash + ":" + target.branchRef
        let result = await CommandRunner.run(command: "\(credentials.git) push \(Shell.quote(lease)) -- \(Shell.quote(target.pushURL)) \(Shell.quote(refspec))", cwd: path, environment: credentials.environment)
        guard result.status == 0 else {
            if result.output.contains("stale info") {
                return CommandResult(output: "远程已有新的提交，未执行强制推送。请 Fetch 并检查后重试。 / Remote has new commits; force push was refused. Fetch and inspect before retrying.\n\n" + result.output, status: result.status)
            }
            return result
        }
        let tracking = await CommandRunner.run(command: "git update-ref \(Shell.quote(target.trackingRef)) \(snapshot.sourceHash) \(target.hash)", cwd: path)
        guard tracking.status == 0 else {
            return CommandResult(output: result.output + "\n推送成功，本地跟踪引用已在其他操作中改变，请 Fetch 刷新。 / Push succeeded; local tracking ref changed. Fetch to refresh.", status: 0)
        }
        if setUpstream {
            let upstream = await CommandRunner.run(command: "git branch --set-upstream-to=\(Shell.quote(target.remote + "/" + target.branch)) -- \(Shell.quote(snapshot.sourceBranch))", cwd: path)
            if upstream.status != 0 { return CommandResult(output: result.output + "\n推送成功，上游设置未完成。 / Push succeeded; upstream setup failed.\n" + upstream.output, status: 0) }
        }
        return result
    }
}

import SwiftUI

struct GitRemoteBranchSnapshot: Sendable {
    let remote: String
    let branch: String
    let hash: String
    let pushURL: String
    var trackingRef: String { "refs/remotes/\(remote)/\(branch)" }
    var branchRef: String { "refs/heads/" + branch }
    var displayPushURL: String {
        guard var value = URLComponents(string: pushURL), value.host != nil else { return pushURL }
        value.user = nil; value.password = nil; value.query = nil; value.fragment = nil
        return value.string ?? ""
    }
}

extension GitService {
    private static func singlePushURL(remote: String, at path: String) async -> String? {
        guard !remote.isEmpty, !remote.hasPrefix("-"), !remote.contains("\0"), await remotes(at: path).contains(where: { $0.name == remote }) else { return nil }
        let result = await CommandRunner.run(command: "git remote get-url --push --all -- \(Shell.quote(remote))", cwd: path)
        let urls = result.output.split(whereSeparator: \.isNewline).map(String.init)
        guard result.status == 0, !result.truncated, urls.count == 1, !urls[0].hasPrefix("-") else { return nil }
        return urls[0]
    }

    static func remoteBranchSnapshot(_ name: String, at path: String) async -> GitRemoteBranchSnapshot? {
        let remotes = await remotes(at: path).sorted { $0.name.count > $1.name.count }
        guard let remote = remotes.first(where: { name.hasPrefix($0.name + "/") }) else { return nil }
        let branch = String(name.dropFirst(remote.name.count + 1))
        guard !branch.isEmpty, branch != "HEAD", !branch.contains("\0"),
              await CommandRunner.run(command: "git check-ref-format \(Shell.quote("refs/heads/" + branch))", cwd: path).status == 0,
              let hash = await commitHash("refs/remotes/" + name, at: path),
              let url = await singlePushURL(remote: remote.name, at: path) else { return nil }
        return GitRemoteBranchSnapshot(remote: remote.name, branch: branch, hash: hash, pushURL: url)
    }

    static func deleteRemoteBranch(_ snapshot: GitRemoteBranchSnapshot, at path: String, credentials: GitCredentials = GitCredentials()) async -> CommandResult {
        guard let current = await remoteBranchSnapshot(snapshot.remote + "/" + snapshot.branch, at: path),
              current.remote == snapshot.remote, current.branch == snapshot.branch,
              current.hash == snapshot.hash, current.pushURL == snapshot.pushURL else {
            return CommandResult(output: "分支或推送地址已改变，请关闭并重新打开删除窗口。 / The branch or push URL changed. Reopen this dialog.", status: 1)
        }
        // Lease protects against deleting a branch that advanced since the last fetch.
        // Use the captured URL so a concurrent remote-config edit cannot redirect this push.
        let result = await CommandRunner.run(command: "\(credentials.git) push \(Shell.quote("--force-with-lease=" + snapshot.branchRef + ":" + snapshot.hash)) -- \(Shell.quote(snapshot.pushURL)) \(Shell.quote(":" + snapshot.branchRef))", cwd: path, environment: credentials.environment)
        guard result.status == 0 else {
            if result.output.contains("stale info") {
                return CommandResult(output: "远程分支已更新，未执行删除。请先 Fetch 并检查新的提交，再重新打开删除窗口。 / Remote branch changed; nothing was deleted. Fetch, inspect the new commits, and reopen this dialog.\n\n" + result.output, status: result.status)
            }
            return result
        }
        let cleanup = await CommandRunner.run(command: "git update-ref -d \(Shell.quote(snapshot.trackingRef)) \(snapshot.hash)", cwd: path)
        if cleanup.status != 0 {
            return CommandResult(output: result.output + "\n远程分支已删除；本地跟踪引用在操作期间发生变化，已保留，请 Fetch 刷新。 / Remote branch deleted; the tracking ref changed and was kept. Fetch to refresh.", status: 0)
        }
        return result
    }
}

struct GitRemoteBranchDeleteSheet: View {
    @ObservedObject var model: WorkbenchModel
    let target: String
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: GitRemoteBranchSnapshot?
    @State private var credentials = GitCredentials()
    @State private var loading = true
    @State private var failure: String?
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }

    @State private var loadRevision = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(text("删除远程分支", "Delete remote branch"), systemImage: "cloud")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(text("关闭", "Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(model.isGitBusy)
            }.padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(target).font(.system(size: 14, weight: .medium))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).id("branch")
                        if loading { ProgressView().controlSize(.small) }
                        else if let snapshot {
                            Text(text("推送地址：", "Push URL: ") + snapshot.displayPushURL)
                                .font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Text(text("将从远程仓库删除此分支。其他协作者将受到影响，本地分支和工作区会保留。", "Deletes this branch from the remote repository and affects collaborators. Local branches and worktree are kept."))
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                            Text(text("最近获取的提交：", "Last fetched commit: ") + String(snapshot.hash.prefix(12)))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(text("若远程分支已有更新，将拒绝删除。请先 Fetch 并检查改动。", "Deletion is refused if the remote branch has changed. Fetch and inspect changes first."))
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            GitCredentialsFields(language: model.language, credentials: $credentials)
                                .disabled(model.isGitBusy)
                        }
                        if let failure {
                            Text(failure).font(.caption).foregroundStyle(.orange)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).id("failure")
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: failure) { value in
                    guard value != nil else { return }
                    DispatchQueue.main.async { proxy.scrollTo("failure", anchor: .top) }
                }
                .onChange(of: loading) { value in
                    if value { proxy.scrollTo("branch", anchor: .top) }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Button(text("重新读取", "Reload")) { loadRevision = UUID() }
                    .disabled(loading || model.isGitBusy)
                    .help(text("重新读取本地跟踪引用和推送地址；不会执行 Fetch 或删除。", "Reloads the local tracking ref and push URL; does not fetch or delete."))
                if model.isGitBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button(text("取消", "Cancel")) { dismiss() }.disabled(model.isGitBusy)
                Button(text("删除远程分支", "Delete remote branch"), role: .destructive) { remove() }
                    .disabled(snapshot == nil || loading || model.isGitBusy)
            }.padding(16)
        }
        .frame(minWidth: 520, idealWidth: 600, maxWidth: .infinity,
               minHeight: 320, idealHeight: 440, maxHeight: .infinity)
        .resizableSheet(minimumWidth: 520, minimumHeight: 320, language: model.language)
        .interactiveDismissDisabled(model.isGitBusy)
        .task(id: loadRevision) { await reload() }
        .onChange(of: model.selectedProjectID) { _ in dismiss() }
        .onDisappear { credentials = GitCredentials() }
    }

    private func remove() {
        guard !loading, !model.isGitBusy, let snapshot else { return }
        failure = nil
        model.deleteRemoteBranch(snapshot, credentials: credentials) { result in
            credentials = GitCredentials()
            if result.status == 0 { dismiss() } else { failure = result.output }
        }
    }

    private func reload() async {
        loading = true; snapshot = nil; failure = nil
        guard let project = model.selectedProject else {
            loading = false
            failure = text("请先打开项目。", "Open a project first.")
            return
        }
        let value = await GitService.remoteBranchSnapshot(target, at: project.path)
        guard !Task.isCancelled, model.selectedProjectID == project.id else { return }
        snapshot = value; loading = false
        if value == nil {
            failure = text("无法读取分支或推送地址。请先 Fetch 并检查分支，或检查远程仓库配置后重新读取。配置了多个推送地址的远程仓库需要分别处理。", "Cannot read the branch or push URL. Fetch and inspect the branch, or check remote configuration and reload. Remotes with multiple push URLs must be handled separately.")
        }
    }
}

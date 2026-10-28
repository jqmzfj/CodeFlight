import SwiftUI

enum GitSyncKind: String, Identifiable {
    case push, pull, fetch
    var id: String { rawValue }
}

enum GitPullStrategy: String, CaseIterable, Identifiable {
    case fastForward, merge, rebase
    var id: String { rawValue }
    var arguments: String {
        switch self {
        case .fastForward: return "--ff-only --no-rebase"
        case .merge: return "--no-rebase --no-edit --ff"
        case .rebase: return "--rebase --no-autostash --ff"
        }
    }
}

struct GitSyncInfo {
    var branch = ""
    var hasHead = false
    var upstream = ""
    var remote = ""
    var remoteBranch = ""
    var ahead: Int?
    var behind: Int?
}

extension GitService {
    static func syncInfo(at path: String) async -> GitSyncInfo {
        var info = GitSyncInfo()
        let branch = await CommandRunner.run(command: "git symbolic-ref --quiet --short HEAD", cwd: path)
        info.branch = branch.status == 0 ? branch.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        info.hasHead = await CommandRunner.run(command: "git rev-parse --verify HEAD", cwd: path).status == 0
        guard !info.branch.isEmpty else { return info }
        let metadata = await CommandRunner.run(command: "git for-each-ref --format='%(upstream:short)%00%(upstream:remotename)%00%(upstream:remoteref)' \(Shell.quote("refs/heads/" + info.branch))", cwd: path)
        let fields = metadata.output.trimmingCharacters(in: .newlines).components(separatedBy: "\0")
        if fields.count == 3 {
            info.upstream = fields[0]
            info.remote = fields[1]
            info.remoteBranch = fields[2].hasPrefix("refs/heads/") ? String(fields[2].dropFirst(11)) : fields[2]
        }
        if !info.upstream.isEmpty {
            let counts = await CommandRunner.run(command: "git rev-list --left-right --count HEAD...@{upstream}", cwd: path)
            let values = counts.output.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }
            if counts.status == 0, values.count == 2 { info.ahead = values[0]; info.behind = values[1] }
        }
        return info
    }

    static func push(remote: String, branch: String, setUpstream: Bool, at path: String, credentials: GitCredentials = GitCredentials()) async -> CommandResult {
        guard await validSyncTarget(remote: remote, branch: branch, at: path) else {
            return CommandResult(output: "请选择有效的远程仓库和目标分支。 / Select a valid remote and branch.", status: 1)
        }
        return await CommandRunner.run(command: "\(credentials.git) push \(setUpstream ? "--set-upstream " : "")-- \(Shell.quote(remote)) \(Shell.quote("HEAD:refs/heads/" + branch))", cwd: path, environment: credentials.environment)
    }

    static func pull(remote: String, branch: String, strategy: GitPullStrategy, at path: String, credentials: GitCredentials = GitCredentials()) async -> CommandResult {
        guard await validSyncTarget(remote: remote, branch: branch, at: path) else {
            return CommandResult(output: "请选择有效的远程仓库和来源分支。 / Select a valid remote and branch.", status: 1)
        }
        return await CommandRunner.run(command: "\(credentials.git) -c core.editor=true pull \(strategy.arguments) -- \(Shell.quote(remote)) \(Shell.quote("refs/heads/" + branch))", cwd: path, environment: credentials.environment.merging(["GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true"]) { _, value in value })
    }

    static func fetch(remote: String, at path: String, credentials: GitCredentials = GitCredentials()) async -> CommandResult {
        guard await remotes(at: path).contains(where: { $0.name == remote }) else { return CommandResult(output: "请选择有效的远程仓库。 / Select a valid remote.", status: 1) }
        return await CommandRunner.run(command: "\(credentials.git) fetch --prune -- \(Shell.quote(remote))", cwd: path, environment: credentials.environment)
    }

    private static func validSyncTarget(remote: String, branch: String, at path: String) async -> Bool {
        guard !remote.isEmpty, !branch.isEmpty, !remote.hasPrefix("-"), !branch.hasPrefix("-") else { return false }
        let names = await remotes(at: path).map(\.name)
        guard names.contains(remote) else { return false }
        return await CommandRunner.run(command: "git check-ref-format \(Shell.quote("refs/heads/" + branch))", cwd: path).status == 0
    }
}

struct GitSyncSheet: View {
    @ObservedObject var model: WorkbenchModel
    let kind: GitSyncKind
    @Environment(\.dismiss) private var dismiss
    @State private var remote = ""
    @State private var branch = ""
    @State private var setUpstream = true
    @State private var strategy: GitPullStrategy = .fastForward
    @State private var info = GitSyncInfo()
    @State private var remotes: [GitRemote] = []
    @State private var loading = true
    @State private var projectID: UUID?
    @State private var credentials = GitCredentials()
    @State private var failure: String?
    @State private var submitting = false
    @State private var isVisible = true
    @State private var forcePush = false
    @State private var forceSnapshot: GitForcePushSnapshot?
    @State private var forceLoading = false
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var isPush: Bool { kind == .push }
    private var canSubmit: Bool {
        !loading && !submitting && !model.isGitBusy && !remote.isEmpty && (!forcePush || (!forceLoading && forceSnapshot?.destination.remote == remote && forceSnapshot?.destination.branch == branch.trimmingCharacters(in: .whitespacesAndNewlines))) && (kind == .fetch || ((!isPush || info.hasHead) && !info.branch.isEmpty && !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(kind == .fetch ? text("获取远程更新", "Fetch updates") : isPush ? text("推送", "Push") : text("拉取更新", "Pull updates"), systemImage: isPush ? "arrow.up.circle" : "arrow.down.circle").font(.title3.bold())
                Spacer()
                Button(text("关闭", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if loading { ProgressView().controlSize(.small) }
            else if remotes.isEmpty { Text(text("尚未配置远程仓库，请先在分支菜单中添加远程仓库。", "Add a remote repository from the branch menu first.")).foregroundStyle(.secondary) }
            else if isPush && !info.hasHead { Text(text("先创建一次提交，再进行远程同步。", "Create the first commit before syncing.")).foregroundStyle(.secondary) }
            else if kind != .fetch && info.branch.isEmpty { Text(text("当前处于分离 HEAD 状态，请先创建或切换到一个分支。", "HEAD is detached. Create or switch to a branch first.")).foregroundStyle(.secondary) }
            else {
                LabeledContent(text("当前分支", "Current branch"), value: info.branch)
                LabeledContent(text("上游分支", "Upstream"), value: info.upstream.isEmpty ? text("未设置", "Not set") : info.upstream)
                if let ahead = info.ahead, let behind = info.behind {
                    Text(text("本地领先 \(ahead) 个提交，落后 \(behind) 个提交（基于上次 Fetch）", "Ahead \(ahead), behind \(behind) commits (last fetch)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Picker(text("远程仓库", "Remote"), selection: $remote) { ForEach(remotes) { Text($0.name).tag($0.name) } }.disabled(submitting)
                if kind != .fetch {
                LabeledContent(isPush ? text("目标分支", "Target branch") : text("来源分支", "Source branch")) {
                    TextField("", text: $branch).textFieldStyle(.roundedBorder).disabled(submitting)
                        .accessibilityLabel(isPush ? text("目标分支", "Target branch") : text("来源分支", "Source branch"))
                }
                if isPush {
                    Toggle(text("设置为当前分支的上游", "Set as upstream for the current branch"), isOn: $setUpstream).disabled(submitting)
                    Toggle(text("强制推送（带提交校验）", "Force push with lease"), isOn: $forcePush).disabled(submitting)
                    if forcePush {
                        if forceLoading { ProgressView().controlSize(.small) }
                        else if let forceSnapshot {
                            Text(text("推送地址：", "Push URL: ") + forceSnapshot.destination.displayPushURL).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            Text(text("将用本地 \(forceSnapshot.sourceHash.prefix(8)) 改写 \(remote)/\(branch) 的历史，预期远程提交为 \(forceSnapshot.destination.hash.prefix(8))。这会影响其他协作者；远程有更新时会拒绝推送。", "Rewrites \(remote)/\(branch) with local \(forceSnapshot.sourceHash.prefix(8)), expecting remote \(forceSnapshot.destination.hash.prefix(8)). This affects collaborators. Refused if the remote changed."))
                                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(text("无法读取目标分支快照。请先 Fetch；首次推送请关闭强制推送。多个推送地址需分别处理。", "Cannot read the target snapshot. Fetch first; use a normal push for new branches. Multiple push URLs must be handled separately."))
                                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    Picker(text("更新方式", "Update strategy"), selection: $strategy) {
                        Text(text("仅快进", "Fast-forward only")).tag(GitPullStrategy.fastForward)
                        Text(text("合并", "Merge")).tag(GitPullStrategy.merge)
                        Text(text("变基", "Rebase")).tag(GitPullStrategy.rebase)
                    }.pickerStyle(.segmented).disabled(submitting)
                    Text(strategy == .fastForward ? text("有分叉时停止，由你选择合并或变基。", "Stops on diverged history so you can choose merge or rebase.") : strategy == .merge ? text("保留本地提交，必要时创建合并提交。", "Preserves local commits and creates a merge commit when needed.") : text("将本地提交重放在远程提交之后，提交哈希会改变。", "Replays local commits on the remote history; commit hashes change."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                }
                GitCredentialsFields(language: model.language, credentials: $credentials).disabled(submitting)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange).lineLimit(6).textSelection(.enabled) }
            HStack {
                if submitting { ProgressView().controlSize(.small) }
                Spacer()
                Button(text("取消", "Cancel")) { dismiss() }
                Button(kind == .fetch ? "Fetch" : isPush ? (forcePush ? text("强制推送", "Force push") : text("推送", "Push")) : text("拉取", "Pull")) {
                    guard model.selectedProjectID == projectID else { return }
                    submitting = true; failure = nil
                    model.syncGit(kind, remote: remote, branch: branch.trimmingCharacters(in: .whitespacesAndNewlines), setUpstream: setUpstream, strategy: strategy, credentials: credentials, forceSnapshot: forcePush ? forceSnapshot : nil) { result in
                        guard isVisible else { return }
                        submitting = false
                        credentials.secret = ""
                        if result.status == 0 { dismiss() } else { failure = result.output }
                    }
                }.buttonStyle(.borderedProminent).disabled(!canSubmit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 520, idealWidth: 600, maxWidth: .infinity,
               minHeight: 360, idealHeight: 520, maxHeight: .infinity,
               alignment: .topLeading)
        .resizableSheet(minimumWidth: 520, minimumHeight: 360, language: model.language)
        .task(id: "\(forcePush)-\(remote)-\(branch)") {
            forceSnapshot = nil; forceLoading = false
            guard forcePush, isPush, let project = model.selectedProject else { return }
            forceLoading = true
            let value = await GitService.forcePushSnapshot(remote: remote, branch: branch.trimmingCharacters(in: .whitespacesAndNewlines), at: project.path)
            guard !Task.isCancelled else { return }
            forceSnapshot = value; forceLoading = false
        }
        .task {
            guard let project = model.selectedProject else { return }
            projectID = project.id
            info = await GitService.syncInfo(at: project.path)
            remotes = await GitService.remotes(at: project.path)
            remote = remotes.contains(where: { $0.name == info.remote }) ? info.remote : remotes.first?.name ?? ""
            branch = info.remoteBranch.isEmpty ? info.branch : info.remoteBranch
            setUpstream = info.upstream.isEmpty
            loading = false
        }
        .onDisappear { isVisible = false; credentials = GitCredentials() }
        .onChange(of: forcePush) { _ in failure = nil }
        .onChange(of: remote) { _ in failure = nil }
        .onChange(of: branch) { _ in failure = nil }
        .onChange(of: model.selectedProjectID) { _ in dismiss() }
    }
}

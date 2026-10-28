import SwiftUI

struct GitSubmodule: Identifiable, Sendable {
    let root: String
    let path: String
    let url: String
    let expectedHash: String
    var id: String { path }
    var absolutePath: String { URL(fileURLWithPath: root).appendingPathComponent(path).path }
    var displayURL: String {
        guard var value = URLComponents(string: url), value.host != nil else { return url }
        value.user = nil; value.password = nil; value.query = nil; value.fragment = nil
        return value.string ?? ""
    }
}

struct GitSubmoduleState: Sendable {
    let initialized: Bool
    let hash: String?
    let dirty: Bool
    let error: String?
}

enum GitSubmoduleAction { case update, sync }

extension GitService {
    static func submodules(at path: String) async -> ([GitSubmodule], String?) {
        let location = await CommandRunner.run(command: "git rev-parse --show-toplevel", cwd: path)
        guard location.status == 0 else { return ([], location.output) }
        let root = location.output.hasSuffix("\n") ? String(location.output.dropLast()) : location.output
        let file = URL(fileURLWithPath: root).appendingPathComponent(".gitmodules")
        guard FileManager.default.fileExists(atPath: file.path) else { return ([], nil) }
        guard let info = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]),
              info.isSymbolicLink != true, info.isRegularFile == true, (info.fileSize ?? Int.max) <= 1024 * 1024 else {
            return ([], "无法读取 .gitmodules：需要不超过 1 MB 的普通文件。 / .gitmodules must be a regular file up to 1 MB.")
        }
        let config = await CommandRunner.run(command: "git config --null --file .gitmodules --get-regexp '^submodule\\..*\\.(path|url)$'", cwd: root, outputLimit: 1024 * 1024)
        if config.status == 1, config.output.isEmpty { return ([], nil) }
        guard config.status == 0, !config.truncated else { return ([], config.truncated ? "子模块配置超过读取限制。 / Submodule configuration exceeds the read limit." : config.output) }
        var sections: [String: (path: String, url: String)] = [:]
        for record in config.output.split(separator: "\0") {
            guard let newline = record.firstIndex(of: "\n") else { continue }
            let key = String(record[..<newline]), value = String(record[record.index(after: newline)...])
            let isPath = key.hasSuffix(".path")
            let section = String(key.dropLast(isPath ? 5 : 4))
            var item = sections[section] ?? ("", "")
            if isPath { item.path = value } else { item.url = value }
            sections[section] = item
        }
        let values = sections.values.sorted { $0.path < $1.path }
        guard values.count <= 500 else { return ([], "子模块数量超过 500 项，请使用 Git 命令管理此仓库。 / More than 500 submodules; use Git commands for this repository.") }
        guard values.allSatisfy({ item in
            !item.path.isEmpty && !item.path.hasPrefix("/") && !item.path.contains("\0") && !item.path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git" })
        }) else { return ([], "子模块配置包含无效路径。 / Submodule configuration contains an invalid path.") }
        guard !values.isEmpty else { return ([], nil) }
        let paths = values.map { Shell.quote($0.path) }.joined(separator: " ")
        let index = await CommandRunner.run(command: "git --literal-pathspecs ls-files --stage -z -- \(paths)", cwd: root, outputLimit: 1024 * 1024)
        guard index.status == 0, !index.truncated else { return ([], index.output) }
        var hashes: [String: String] = [:]
        for record in index.output.split(separator: "\0") {
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let metadata = record[..<tab].split(separator: " ")
            if metadata.count == 3, metadata[0] == "160000", metadata[2] == "0" { hashes[String(record[record.index(after: tab)...])] = String(metadata[1]) }
        }
        var seen = Set<String>()
        let modules = values.compactMap { item -> GitSubmodule? in
            guard let hash = hashes[item.path], seen.insert(item.path).inserted else { return nil }
            let absolute = URL(fileURLWithPath: root).appendingPathComponent(item.path).resolvingSymlinksInPath().path
            guard absolute.hasPrefix(URL(fileURLWithPath: root).resolvingSymlinksInPath().path + "/") else { return nil }
            return GitSubmodule(root: root, path: item.path, url: item.url, expectedHash: hash)
        }
        return (modules, modules.count == values.count ? nil : "部分子模块配置没有对应的索引记录，或路径位于仓库外，请检查 .gitmodules。 / Some submodules have no matching gitlink or resolve outside the repository. Check .gitmodules.")
    }

    static func submoduleState(_ module: GitSubmodule) async -> GitSubmoduleState {
        let location = URL(fileURLWithPath: module.absolutePath)
        guard FileManager.default.fileExists(atPath: location.appendingPathComponent(".git").path) else { return GitSubmoduleState(initialized: false, hash: nil, dirty: false, error: nil) }
        let root = await CommandRunner.run(command: "git rev-parse --show-toplevel", cwd: module.absolutePath)
        let resolved = root.output.hasSuffix("\n") ? String(root.output.dropLast()) : root.output
        guard root.status == 0, URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path == location.resolvingSymlinksInPath().path else { return GitSubmoduleState(initialized: false, hash: nil, dirty: false, error: root.output) }
        let hash = await commitHash("HEAD", at: module.absolutePath)
        let status = await CommandRunner.run(command: "git status --porcelain=v1 -z --untracked-files=normal --ignore-submodules=none", cwd: module.absolutePath)
        return GitSubmoduleState(initialized: true, hash: hash, dirty: !status.output.isEmpty || status.truncated, error: status.status == 0 ? nil : status.output)
    }

    static func submoduleAction(_ action: GitSubmoduleAction, module: GitSubmodule, recursive: Bool, credentials: GitCredentials = GitCredentials()) async -> CommandResult {
        let latest = await submodules(at: module.root)
        guard let current = latest.0.first(where: { $0.path == module.path }), current.expectedHash == module.expectedHash, current.url == module.url else {
            return CommandResult(output: "子模块配置或固定提交已改变，请刷新后重试。 / Submodule configuration or pinned commit changed. Refresh and retry.", status: 1)
        }
        let flags = recursive ? "--recursive " : ""
        let command = action == .update ? "update --init --checkout " : "sync "
        return await CommandRunner.run(command: "\(credentials.git) submodule \(command)\(flags)-- \(Shell.quote(current.path))", cwd: current.root, environment: credentials.environment)
    }
}

struct GitSubmodulesSheet: View {
    @ObservedObject var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draftGuard = SheetDraftGuard()
    @State private var modules: [GitSubmodule] = []
    @State private var selection: String?
    @State private var state: GitSubmoduleState?
    @State private var loading = true
    @State private var readingState = false
    @State private var recursive = true
    @State private var failure: String?
    @State private var success: String?
    @State private var credentials = GitCredentials()
    @State private var revision = UUID()
    @State private var stateRevision = UUID()
    @State private var adding = false
    @State private var newSource = ""
    @State private var newDestination = ""
    @State private var confirmingRemoval = false
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var dirty: Bool { !newSource.isEmpty || !newDestination.isEmpty }
    private var selectionBinding: Binding<String?> {
        Binding(get: { selection }, set: { value in
            guard !model.isGitBusy, !loading else { return }
            selection = value; failure = nil; success = nil
        })
    }
    private var selected: GitSubmodule? { modules.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(text("子模块", "Submodules"), systemImage: "shippingbox").font(.headline)
                if dirty { Text(text("未保存", "Unsaved")).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if model.isGitBusy || loading { ProgressView().controlSize(.small) }
                Button { failure = nil; success = nil; revision = UUID() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).accessibilityLabel(text("刷新子模块", "Refresh submodules")).help(text("刷新子模块", "Refresh submodules")).disabled(model.isGitBusy || loading)
                Button(text("关闭", "Close")) { draftGuard.request(dirty: dirty) { dismiss() } }.keyboardShortcut(.cancelAction).disabled(model.isGitBusy)
            }.padding(16)
            Divider()
            WorkbenchSplit("submodules", initial: 210, minimum: 180, otherMinimum: 450) {
                VStack(spacing: 0) {
                    List(modules, selection: selectionBinding) { module in Label(module.path, systemImage: "folder").font(.system(size: 12)).lineLimit(2).tag(module.id).help(module.path) }.listStyle(.sidebar).disabled(model.isGitBusy || loading)
                    Divider()
                    HStack {
                        Button {
                            adding = true; selection = nil; confirmingRemoval = false
                            credentials = GitCredentials(); failure = nil; success = nil
                        } label: { Image(systemName: "plus") }.help(text("添加子模块", "Add submodule")).accessibilityLabel(text("添加子模块", "Add submodule"))
                        Spacer()
                    }.buttonStyle(.borderless).padding(10).disabled(model.isGitBusy || loading)
                }.frame(maxWidth: .infinity)
                } second: {
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if adding { addForm }
                        else if let selected {
                            Text(selected.path).font(.headline).textSelection(.enabled)
                            Text(selected.displayURL).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            Text(text("父仓库索引中的固定提交：", "Pinned commit in parent index: ") + String(selected.expectedHash.prefix(12))).font(.caption).foregroundStyle(.secondary)
                            if readingState { ProgressView().controlSize(.small) }
                            else if let state {
                                Text(!state.initialized ? text("尚未初始化", "Not initialized") : state.hash == selected.expectedHash ? text("已检出固定提交", "At pinned commit") : text("当前检出与固定提交不同", "Checkout differs from pinned commit")).font(.callout)
                                if let hash = state.hash { Text(hash).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                                if state.dirty { Text(text("子模块内有未提交修改；更新遇到覆盖时 Git 会拒绝。", "Submodule has local changes; Git refuses an update that would overwrite them.")).font(.caption).foregroundStyle(.orange) }
                                if let error = state.error { Text(error).font(.caption).foregroundStyle(.orange) }
                                Button(text("作为项目打开", "Open as project")) { draftGuard.request(dirty: dirty) { model.confirmSheetQuit = nil; dismiss(); model.openProject(at: URL(fileURLWithPath: selected.absolutePath)) } }.disabled(!state.initialized)
                            }
                            Divider()
                            Toggle(text("包含嵌套子模块", "Include nested submodules"), isOn: $recursive)
                            GitCredentialsFields(language: model.language, credentials: $credentials)
                            Text(text("更新会初始化并检出父仓库指定的提交，不更新到远程最新分支。同步地址会将 .gitmodules 中的地址写入本机子模块配置。", "Update initializes and checks out the pinned commit. Sync URLs copies .gitmodules URLs into local submodule configuration.")).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button(text("同步地址", "Sync URLs")) { perform(.sync, module: selected) }
                                Spacer()
                                Button(text("初始化／更新", "Initialize / Update")) { perform(.update, module: selected) }.buttonStyle(.borderedProminent)
                            }
                            Divider()
                            if confirmingRemoval {
                                Text(text("移除工作目录并暂存父仓库中的删除。修改、未跟踪及忽略文件会阻止移除；Git 对象历史保留在父仓库中。操作后仍需提交父仓库。", "Remove the checkout and stage its removal in the parent. Modified, untracked and ignored files block removal. Git object history is retained. Commit the parent afterward."))
                                    .font(.caption).foregroundStyle(.orange)
                                HStack {
                                    Button(text("取消", "Cancel")) { confirmingRemoval = false }
                                    Spacer()
                                    Button(text("确认移除", "Remove Submodule"), role: .destructive) { remove(selected) }
                                }
                            } else {
                                Button(text("移除此子模块…", "Remove this submodule…"), role: .destructive) { confirmingRemoval = true }
                                    .disabled(readingState || state?.error != nil)
                            }
                        } else if !loading { Text(text("当前没有已注册的子模块，点击左下角 + 添加。", "No registered submodules. Use + below the list to add one.")).font(.callout).foregroundStyle(.secondary) }
                        if let failure {
                            Text(failure).font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.orange).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                                .id("failure")
                        }
                        if let success { Text(success).font(.caption).foregroundStyle(.secondary) }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).disabled(model.isGitBusy || loading).id("content")
                }
                .onChange(of: failure) { value in
                    guard value != nil else { return }
                    DispatchQueue.main.async { proxy.scrollTo("failure", anchor: .top) }
                }
                .onChange(of: selection) { _ in proxy.scrollTo("content", anchor: .top) }
                .onChange(of: adding) { _ in proxy.scrollTo("content", anchor: .top) }
                }.frame(minWidth: 450, maxWidth: .infinity)
            }
        }.frame(minWidth: 680, idealWidth: 780, maxWidth: .infinity, minHeight: 420, idealHeight: 550, maxHeight: .infinity)
        .resizableSheet(minimumWidth: 680, minimumHeight: 420, language: model.language)
        .task(id: revision) {
            guard let project = model.selectedProject else { loading = false; return }
            loading = true
            let result = await GitService.submodules(at: project.path)
            guard !Task.isCancelled, model.selectedProjectID == project.id else { return }
            modules = result.0; loading = false
            if let error = result.1 { failure = error }
            if !modules.contains(where: { $0.id == selection }) { selection = modules.first?.id }
            stateRevision = UUID()
        }
        .task(id: "\(selection ?? "")-\(stateRevision)") {
            state = nil; readingState = false; credentials = GitCredentials()
            guard let selected else { return }
            readingState = true
            let result = await GitService.submoduleState(selected)
            guard !Task.isCancelled else { return }
            state = result; readingState = false
        }
        .onChange(of: selection) { value in
            confirmingRemoval = false
            if value != nil { adding = false }
        }
        .protectDraft(using: draftGuard, model: model, dirty: { dirty }, busy: { model.isGitBusy }, context: {
            text("添加子模块中有未完成的地址或目录。放弃后将清空这些内容，仓库文件不会改变。", "The new submodule has an unfinished URL or directory. Discarding clears the input and keeps repository files.")
        })
        .onChange(of: model.selectedProjectID) { _ in dismiss() }
        .onDisappear { credentials = GitCredentials() }
    }

    private var request: GitSubmoduleAddRequest {
        GitSubmoduleAddRequest(source: newSource.trimmingCharacters(in: .whitespacesAndNewlines), destination: newDestination.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text("添加子模块", "Add Submodule")).font(.headline)
            Text(text("仓库地址", "Repository URL")).font(.caption).foregroundStyle(.secondary)
            TextField("https://… / git@… / /path/to/repository", text: $newSource).textFieldStyle(.roundedBorder)
                .accessibilityLabel(text("子模块仓库地址", "Submodule repository URL"))
            Text(text("父仓库内的相对目录", "Directory relative to the repository root")).font(.caption).foregroundStyle(.secondary)
            TextField("modules/library", text: $newDestination).textFieldStyle(.roundedBorder)
                .accessibilityLabel(text("子模块目录", "Submodule directory"))
            GitCredentialsFields(language: model.language, credentials: $credentials)
            Text(text("克隆到新目录，并暂存 .gitmodules 和固定提交记录；完成后需提交父仓库。失败时保留已生成的文件，方便检查。", "Clone into a new directory and stage .gitmodules plus the pinned commit. Commit the parent afterward. Files produced by a failed attempt are kept for inspection."))
                .font(.caption).foregroundStyle(.secondary)
            if let error = request.validationError, !newSource.isEmpty || !newDestination.isEmpty {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button(text("取消添加", "Cancel Add")) { adding = false; selection = modules.first?.id; newSource = ""; newDestination = ""; credentials = GitCredentials(); failure = nil }
                Spacer()
                Button(text("添加子模块", "Add Submodule")) { add() }.buttonStyle(.borderedProminent)
                    .disabled(request.validationError != nil || loading || model.isGitBusy)
            }
        }
    }

    private func add() {
        failure = nil; success = nil
        let destination = request.destination
        model.addSubmodule(request, credentials: credentials) { result in
            credentials = GitCredentials()
            if result.status == 0 {
                adding = false; selection = destination; newSource = ""; newDestination = ""
                success = text("已添加，请提交父仓库中的更改。", "Added. Commit the changes in the parent repository.")
                revision = UUID()
            } else { failure = result.output }
        }
    }

    private func remove(_ module: GitSubmodule) {
        failure = nil; success = nil; confirmingRemoval = false
        model.removeSubmodule(module) { result in
            if result.status == 0 {
                selection = nil
                success = text("已移除，请提交父仓库中的更改。", "Removed. Commit the changes in the parent repository.")
                revision = UUID()
            } else { failure = result.output }
        }
    }

    private func perform(_ action: GitSubmoduleAction, module: GitSubmodule) {
        failure = nil; success = nil
        model.submoduleAction(action, module: module, recursive: recursive, credentials: credentials) { result in
            credentials = GitCredentials()
            failure = result.status == 0 ? nil : result.output
            success = result.status == 0 ? text("操作完成", "Operation completed") : nil
            revision = UUID()
        }
    }
}

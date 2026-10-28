import SwiftUI

struct GitTagDetails: Sendable {
    let name: String
    let objectID: String
    let commitID: String?
    let annotated: Bool
    let message: String
}

extension GitService {
    static func tagDetails(_ name: String, at path: String) async -> GitTagDetails? {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("\0") else { return nil }
        let ref = "refs/tags/" + name
        let result = await CommandRunner.run(command: "git for-each-ref --format='%(refname)%00%(objectname)%00%(objecttype)%00%(contents)' -- \(Shell.quote(ref))", cwd: path)
        guard result.status == 0, !result.truncated else { return nil }
        let fields = result.output.components(separatedBy: "\0")
        guard fields.count >= 4, fields[0] == ref, [40, 64].contains(fields[1].count), fields[1].allSatisfy(\.isHexDigit) else { return nil }
        let commit = await commitHash(fields[1], at: path)
        return GitTagDetails(name: name, objectID: fields[1], commitID: commit, annotated: fields[2] == "tag", message: fields[3].trimmingCharacters(in: .newlines))
    }

    static func deleteTag(_ tag: GitTagDetails, at path: String) async -> CommandResult {
        guard let current = await tagDetails(tag.name, at: path), current.objectID == tag.objectID else { return staleTag() }
        return await CommandRunner.run(command: "git update-ref -d \(Shell.quote("refs/tags/" + tag.name)) \(Shell.quote(tag.objectID))", cwd: path)
    }

    static func pushTag(_ tag: GitTagDetails, remote: String, at path: String, credentials: GitCredentials = GitCredentials()) async -> CommandResult {
        guard !remote.hasPrefix("-"), await remotes(at: path).contains(where: { $0.name == remote }) else { return CommandResult(output: "请选择有效的远程仓库。 / Select a valid remote.", status: 1) }
        guard let current = await tagDetails(tag.name, at: path), current.objectID == tag.objectID else { return staleTag() }
        return await CommandRunner.run(command: "\(credentials.git) push -- \(Shell.quote(remote)) \(Shell.quote(tag.objectID + ":refs/tags/" + tag.name))", cwd: path, environment: credentials.environment)
    }

    static func checkoutTag(_ tag: GitTagDetails, at path: String) async -> CommandResult {
        guard let current = await tagDetails(tag.name, at: path), current.objectID == tag.objectID, let hash = current.commitID else { return staleTag() }
        return await CommandRunner.run(command: "git switch --detach \(hash)", cwd: path)
    }

    private static func staleTag() -> CommandResult { CommandResult(output: "标签已改变或不再指向提交，请刷新后重试。 / The tag changed or no longer points to a commit. Refresh and retry.", status: 1) }
}

struct GitTagsSheet: View {
    @ObservedObject var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draftGuard = SheetDraftGuard()
    @State private var selection: String?
    @State private var search = ""
    @State private var details: GitTagDetails?
    @State private var name = ""
    @State private var target = "HEAD"
    @State private var message = ""
    @State private var remote = ""
    @State private var credentials = GitCredentials()
    @State private var loading = false
    @State private var refreshing = false
    @State private var failure: String?
    @State private var success: String?
    @State private var revision = UUID()
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var busy: Bool { model.isGitBusy || refreshing }
    private var dirty: Bool { !name.isEmpty || target != "HEAD" || !message.isEmpty }
    private var filtered: [String] { model.gitTags.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) } }
    private func finish(_ result: CommandResult) {
        failure = result.status == 0 ? nil : result.output
        success = result.status == 0 ? text("操作完成", "Operation completed") : nil
        credentials.secret = ""
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(text("标签管理", "Tags"), systemImage: "tag").font(.system(size: 14, weight: .semibold))
                Spacer()
                if busy || model.isLoading { ProgressView().controlSize(.small) }
                Button {
                    guard let project = model.selectedProject else { return }
                    refreshing = true
                    Task { await model.refreshProject(project); refreshing = false; revision = UUID() }
                } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).accessibilityLabel(text("刷新标签", "Refresh tags")).help(text("刷新标签", "Refresh tags")).disabled(busy || model.isLoading)
                if dirty { Text(text("未保存", "Unsaved")).font(.caption).foregroundStyle(.secondary) }
                Button(text("关闭", "Close")) { draftGuard.request(dirty: dirty) { dismiss() } }.keyboardShortcut(.cancelAction).disabled(busy)
            }.padding(16)
            Divider()
            WorkbenchSplit("tags", initial: 220, minimum: 160, otherMinimum: 380) {
                VStack(spacing: 0) {
                    TextField(text("搜索标签", "Search tags"), text: $search).textFieldStyle(.roundedBorder).controlSize(.small).padding(10).disabled(busy)
                    if filtered.isEmpty {
                        Text(model.gitTags.isEmpty ? text("暂无标签", "No tags") : text("没有匹配的标签", "No matching tags"))
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(filtered, id: \.self, selection: $selection) { tag in
                            Label(tag, systemImage: "tag").font(.system(size: 12)).tag(tag)
                        }.listStyle(.sidebar).disabled(busy)
                    }
                    Divider()
                    HStack {
                        Button { selection = nil; failure = nil; success = nil } label: { Image(systemName: "plus") }.accessibilityLabel(text("新建标签", "New tag")).help(text("新建标签", "New tag"))
                        Button { if let details { model.deleteManagedTag(details) { result in finish(result); if result.status == 0 { selection = nil } } } } label: { Image(systemName: "minus") }.accessibilityLabel(text("删除本地标签", "Delete local tag")).help(text("删除本地标签", "Delete local tag")).disabled(details == nil)
                        Spacer()
                    }.buttonStyle(.borderless).padding(10).disabled(busy)
                }.frame(maxWidth: .infinity)
                } second: {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if selection == nil { createForm }
                            else if loading { ProgressView().controlSize(.small) }
                            else if let details { tagInfo(details) }
                            if let failure {
                                Text(failure).font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.orange).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                    .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                                    .id("failure")
                            }
                            if let success { Text(success).font(.caption).foregroundStyle(.secondary) }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).id("content")
                    }
                    .onChange(of: failure) { value in
                        guard value != nil else { return }
                        DispatchQueue.main.async { proxy.scrollTo("failure", anchor: .top) }
                    }
                    .onChange(of: selection) { _ in proxy.scrollTo("content", anchor: .top) }
                }.frame(minWidth: 380, maxWidth: .infinity)

            }
        }.frame(minWidth: 600, idealWidth: 720, maxWidth: .infinity, minHeight: 400, idealHeight: 520, maxHeight: .infinity)
        .resizableSheet(minimumWidth: 600, minimumHeight: 400, language: model.language)
        .protectDraft(using: draftGuard, model: model, dirty: { dirty }, busy: { busy }, context: {
            text("新建标签中有未完成的输入。放弃后将清空这些内容，已有标签不受影响。", "The new tag has unfinished input. Discarding clears it and keeps existing tags.")
        })
        .onAppear { selection = model.gitTags.first; remote = model.gitRemotes.first?.name ?? "" }
        .task(id: "\(selection ?? "")-\(revision)") {
            details = nil; failure = nil; success = nil; credentials = GitCredentials()
            guard let selection, let project = model.selectedProject else { loading = false; return }
            loading = true
            let value = await GitService.tagDetails(selection, at: project.path)
            guard !Task.isCancelled, model.selectedProjectID == project.id else { return }
            details = value; loading = false
            if value == nil { failure = text("无法读取标签，可能已在外部删除。请刷新后重试。", "Cannot read the tag; it may have been deleted. Refresh and retry.") }
        }
        .onChange(of: model.gitTags) { tags in if let selection, !tags.contains(selection) { self.selection = nil } }
        .onChange(of: model.selectedProjectID) { _ in dismiss() }
        .onDisappear { credentials = GitCredentials() }
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text("新建标签", "Create tag")).font(.headline)
            TextField(text("标签名称", "Tag name"), text: $name).textFieldStyle(.roundedBorder).accessibilityLabel(text("标签名称", "Tag name"))
            TextField(text("目标提交或分支", "Target commit or branch"), text: $target).textFieldStyle(.roundedBorder).accessibilityLabel(text("目标提交或分支", "Target commit or branch"))
            Text(text("附注（留空创建轻量标签）", "Annotation (leave empty for a lightweight tag)")).font(.caption).foregroundStyle(.secondary)
            ResizableFormArea("tags.annotation", initial: 100) { TextEditor(text: $message).font(.system(size: 12)) }.padding(5).overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.12))).accessibilityLabel(text("标签附注", "Tag annotation"))
            HStack {
                Spacer()
                Button(text("创建标签", "Create tag")) {
                    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.createManagedTag(name: value, target: target.trimmingCharacters(in: .whitespacesAndNewlines), message: message) { result in finish(result); if result.status == 0 { name = ""; target = "HEAD"; message = ""; selection = value } }
                }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.disabled(busy)
    }

    private func tagInfo(_ tag: GitTagDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tag.name).font(.headline).textSelection(.enabled)
            Text(tag.annotated ? text("附注标签", "Annotated tag") : text("轻量标签", "Lightweight tag")).font(.caption).foregroundStyle(.secondary)
            Text(tag.commitID ?? tag.objectID).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Text(tag.message).font(.system(size: 12)).textSelection(.enabled)
            HStack {
                Button(text("切换到标签…", "Check out tag…")) { model.checkoutManagedTag(tag) { result in finish(result); if result.status == 0 { dismiss() } } }.disabled(tag.commitID == nil)
                Spacer()
            }
            Divider()
            if model.gitRemotes.isEmpty { Text(text("配置远程仓库后可推送此标签。", "Configure a remote to push this tag.")).font(.caption).foregroundStyle(.secondary) }
            else {
                Picker(text("远程仓库", "Remote"), selection: $remote) { ForEach(model.gitRemotes) { Text($0.name).tag($0.name) } }
                GitCredentialsFields(language: model.language, credentials: $credentials)
                Text(text("只推送此标签，远程已有不同标签时会拒绝覆盖。", "Pushes only this tag; refuses to replace a different remote tag.")).font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button(text("推送标签", "Push tag")) { model.pushManagedTag(tag, remote: remote, credentials: credentials) { finish($0) } }.buttonStyle(.borderedProminent).disabled(remote.isEmpty) }
            }
        }.disabled(busy)
    }
}

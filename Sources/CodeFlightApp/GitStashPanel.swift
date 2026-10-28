import SwiftUI

struct StashSheet: View {
    @ObservedObject var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draftGuard = SheetDraftGuard()
    @State private var selectedHash: String?
    @State private var diff = ""
    @State private var message = ""
    @State private var includeUntracked = true
    @State private var keepIndex = false
    @State private var savedIncludeUntracked = true
    @State private var savedKeepIndex = false
    @State private var loading = false
    @State private var refreshing = false
    @State private var restoreIndex = false
    @State private var failure: String?
    @State private var success: Notice?
    @State private var revision = UUID()
    private enum Notice {
        case applied, dropped, saved, noChanges
        func label(_ language: AppLanguage) -> String {
            switch self {
            case .applied: return Copy.t("已应用，Stash 已保留", "Applied; stash kept", language: language)
            case .dropped: return Copy.t("已丢弃所选 Stash", "Selected stash dropped", language: language)
            case .saved: return Copy.t("已保存到 Stash", "Changes stashed", language: language)
            case .noChanges: return Copy.t("没有新的可保存修改", "No new changes to stash", language: language)
            }
        }
    }
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var selected: GitStash? { model.gitStashes.first { $0.hash == selectedHash } }
    private var busy: Bool { model.isGitBusy || refreshing }
    private var dirty: Bool { !message.isEmpty || includeUntracked != savedIncludeUntracked || keepIndex != savedKeepIndex }
    private func failureMessage(_ result: CommandResult) -> String? {
        guard result.status != 0 else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text("Stash 操作失败，请查看 Git 操作记录。", "Stash operation failed. Check the Git operation log.") : result.output
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(text("Stash 暂存架", "Stashes"), systemImage: "archivebox").font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.isGitBusy || refreshing { ProgressView().controlSize(.small) }
                Button {
                    guard let project = model.selectedProject else { return }
                    failure = nil; success = nil
                    refreshing = true
                    Task { await model.refreshProject(project); refreshing = false; revision = UUID() }
                } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).accessibilityLabel(text("刷新 Stash", "Refresh stashes")).help(text("刷新 Stash", "Refresh stashes")).disabled(busy)
                if dirty { Text(text("未保存", "Unsaved")).font(.caption).foregroundStyle(.secondary) }
                Button(text("关闭", "Close")) { draftGuard.request(dirty: dirty) { dismiss() } }.keyboardShortcut(.cancelAction).disabled(busy)
            }.padding(16)
            Divider()
            WorkbenchSplit("stash.form", axis: .horizontal, initial: 160, minimum: 120, otherMinimum: 150, resizesSecond: true) {
                stashBrowser
            } second: {
                ScrollViewReader { proxy in
                    ScrollView { saveForm }
                        .onChange(of: failure) { value in
                            guard value != nil else { return }
                            DispatchQueue.main.async { proxy.scrollTo("failure", anchor: .top) }
                        }
                }
            }

        }.frame(minWidth: 620, idealWidth: 820, maxWidth: .infinity, minHeight: 400, idealHeight: 540, maxHeight: .infinity)
        .resizableSheet(minimumWidth: 620, minimumHeight: 400, language: model.language)
        .protectDraft(using: draftGuard, model: model, dirty: { dirty }, busy: { busy }, context: {
            text("保存到 Stash 的说明或选项尚未应用。放弃后将清空输入，已有 Stash 和工作区不受影响。", "The stash message or options have not been applied. Discarding clears the form and keeps existing stashes and the worktree.")
        })
        .task(id: "\(selectedHash ?? "")-\(revision)") {
            diff = ""; loading = false
            guard let selected, let project = model.selectedProject else { return }
            loading = true
            let value = await GitService.stashDiff(selected, at: project.path)
            guard !Task.isCancelled, model.selectedProjectID == project.id else { return }
            diff = value; loading = false
        }
        .onAppear { selectedHash = model.gitStashes.first?.hash }
        .onChange(of: model.gitStashes.map(\.hash)) { hashes in if selectedHash == nil || !hashes.contains(selectedHash ?? "") { selectedHash = hashes.first } }
        .onChange(of: model.selectedProjectID) { _ in dismiss() }
    }
    private var stashBrowser: some View {
        WorkbenchSplit("stash", initial: 250, minimum: 200, otherMinimum: 320) {
                VStack(alignment: .leading, spacing: 0) {
                    if model.gitStashes.isEmpty {
                        Text(text("暂无 Stash", "No stashes")).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(model.gitStashes, selection: $selectedHash) { stash in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(stash.message).font(.system(size: 11)).lineLimit(2)
                                Text(stash.reference).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }.padding(.vertical, 4).tag(stash.hash)
                        }.listStyle(.sidebar).disabled(busy)
                    }
                    Divider()
                    HStack {
                        Button(text("应用到工作区", "Apply to worktree")) {
                            if let selected {
                                failure = nil; success = nil
                                model.stashAction(.apply, stash: selected, restoreIndex: restoreIndex) { result in
                                    failure = failureMessage(result)
                                    success = result.status == 0 ? .applied : nil
                                }
                            }
                        }.buttonStyle(.borderedProminent)
                        Spacer(minLength: 4)
                        Button {
                            if let selected {
                                failure = nil; success = nil
                                model.stashAction(.drop, stash: selected) { result in failure = failureMessage(result); success = result.status == 0 ? .dropped : nil }
                            }
                        } label: { Image(systemName: "trash") }.accessibilityLabel(text("丢弃所选 Stash", "Drop selected stash")).help(text("丢弃所选 Stash", "Drop selected stash"))
                    }.controlSize(.small).padding(10).disabled(selected == nil || busy)
                    Toggle(text("应用时恢复暂存状态", "Restore index when applying"), isOn: $restoreIndex).font(.system(size: 11)).padding(.horizontal, 10).padding(.bottom, 10).disabled(busy)
                }.frame(maxWidth: .infinity)
                } second: {
                Group {
                    if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else if selected != nil { DiffPreview(content: diff.isEmpty ? text("没有文本差异", "No text diff") : diff) }
                    else { Text(text("选择 Stash 预览修改", "Select a stash to preview changes")).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
    }

    private var saveForm: some View {
        VStack(alignment: .leading, spacing: 10) {
                if let success { Text(success.label(model.language)).font(.caption).foregroundStyle(.secondary) }
                Text(text("保存当前修改", "Stash current changes")).font(.system(size: 11, weight: .medium))
                HStack {
                    TextField(text("说明（可选）", "Message (optional)"), text: $message).textFieldStyle(.roundedBorder).accessibilityLabel(text("Stash 说明", "Stash message")).disabled(busy)
                    Button(text("保存到 Stash", "Save stash")) {
                        let previousCount = model.gitStashes.count, previousHash = model.gitStashes.first?.hash
                        failure = nil; success = nil
                        model.saveStash(message: message, includeUntracked: includeUntracked, keepIndex: keepIndex) { result in
                            failure = failureMessage(result)
                            if result.status == 0 {
                                if model.gitStashes.count > previousCount || model.gitStashes.first?.hash != previousHash {
                                    message = ""; selectedHash = model.gitStashes.first?.hash
                                    savedIncludeUntracked = includeUntracked; savedKeepIndex = keepIndex
                                    success = .saved
                                } else { success = .noChanges }
                            }
                        }
                    }.disabled(model.isGitBusy || refreshing || model.gitChanges.isEmpty || model.gitChanges.contains(where: \.isConflicted))
                }
                HStack(spacing: 18) {
                    Toggle(text("包含未跟踪文件", "Include untracked files"), isOn: $includeUntracked)
                    Toggle(text("保留已暂存修改", "Keep staged changes"), isOn: $keepIndex)
                    Spacer()
                    Text(text("应用后保留 Stash", "Apply keeps the stash")).foregroundStyle(.secondary)
                }.font(.system(size: 11)).disabled(busy)
                if let failure {
                    Text(failure).font(.system(.caption, design: .monospaced)).foregroundStyle(.orange)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                        .id("failure")
                }
            }.padding(14)
    }

}

import SwiftUI
import AppKit

struct RemoteSheet: View {
    @ObservedObject var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var name = "origin"
    @State private var url = ""
    @State private var failure: String?
    @State private var feedback: String?
    @State private var snapshot: GitRemote?
    @State private var refreshing = false
    @State private var baselineName = "origin"
    @State private var baselineURL = ""
    @State private var pendingNavigation: Navigation?
    @State private var showDiscardConfirmation = false

    private enum Navigation {
        case select(String?), refresh, close, remove
    }
    private var dirty: Bool { name != baselineName || url != baselineURL }
    private var busy: Bool { model.isGitBusy || refreshing }
    private var selectionBinding: Binding<String?> {
        Binding(get: { selection }, set: { value in
            guard value != selection else { return }
            navigate(.select(value))
        })
    }
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var existing: GitRemote? { model.gitRemotes.first { $0.name == selection } }
    private var inputError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text("请填写名称和地址。", "Enter a name and URL.") }
        if name.hasPrefix("-") || name.contains(where: { $0.isWhitespace }) || name.contains("\0") { return text("远程名称不能包含空白或以 - 开头。", "Remote names cannot contain whitespace or start with -.") }
        if let error = GitRepositoryAddress.validationError(url.trimmingCharacters(in: .whitespacesAndNewlines)) { return error }
        if selection == nil && model.gitRemotes.contains(where: { $0.name == name }) { return text("远程名称已存在，请从列表选择后编辑。", "This name already exists. Select it in the list to edit.") }
        return nil
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(text("远程仓库", "Remotes"), systemImage: "cloud").font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.isGitBusy || refreshing { ProgressView().controlSize(.small) }
                Button { navigate(.refresh) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                    .accessibilityLabel(text("刷新远程仓库", "Refresh remotes")).help(text("刷新远程仓库，重新读取当前配置", "Refresh remotes and reload current configuration")).disabled(model.isGitBusy || refreshing)
                Button(text("关闭", "Close")) { navigate(.close) }.keyboardShortcut(.cancelAction).disabled(model.isGitBusy || refreshing)
            }.padding(16)
            Divider()
            WorkbenchSplit("remotes", initial: 170, minimum: 150, otherMinimum: 350) {
                VStack(spacing: 0) {
                    List(model.gitRemotes, selection: selectionBinding) { remote in
                        Label(remote.name, systemImage: "cloud").font(.system(size: 12)).tag(remote.name)
                    }.listStyle(.sidebar).disabled(model.isGitBusy || refreshing)
                    Divider()
                    HStack(spacing: 15) {
                        Button { navigate(.select(nil)) } label: { Image(systemName: "plus") }.accessibilityLabel(text("添加远程仓库", "Add remote")).help(text("添加远程仓库", "Add remote"))
                        Button { navigate(.remove) } label: { Image(systemName: "minus") }.disabled(existing == nil).accessibilityLabel(text("移除远程仓库", "Remove remote")).help(text("移除远程仓库", "Remove remote"))
                        Spacer()
                    }.buttonStyle(.borderless).padding(10).disabled(model.isGitBusy || refreshing)
                }.frame(maxWidth: .infinity)
                } second: {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(existing == nil ? text("添加远程仓库", "Add remote") : text("编辑远程仓库", "Edit remote")).font(.system(size: 12, weight: .medium))
                            Text(text("名称", "Name")).font(.caption).foregroundStyle(.secondary)
                            TextField("origin", text: $name).textFieldStyle(.roundedBorder).disabled(existing != nil).accessibilityLabel(text("远程名称", "Remote name"))
                            Text(text("仓库地址", "Repository URL")).font(.caption).foregroundStyle(.secondary)
                            TextField("https://… / git@…", text: $url).textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced)).accessibilityLabel(text("仓库地址", "Repository URL"))
                            if let existing, existing.pushURL != existing.fetchURL {
                                Text(text("单独的推送地址：", "Separate push URL: ") + existing.pushURL).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            if let error = failure ?? inputError { Text(error).font(.caption).foregroundStyle(failure == nil ? Color.secondary : Color.orange).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                            if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    HStack {
                        if dirty { Text(text("未保存", "Unsaved changes")).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button(existing == nil ? text("添加", "Add") : text("保存地址", "Save URL")) { save() }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .disabled(inputError != nil || (existing != nil && !dirty))
                    }.padding(14)
                }.frame(minWidth: 350, maxWidth: .infinity).disabled(busy)
            }
        }.frame(minWidth: 580, idealWidth: 650, maxWidth: .infinity, minHeight: 340, idealHeight: 380, maxHeight: .infinity)
        .resizableSheet(minimumWidth: 580, minimumHeight: 340, language: model.language)
        .interactiveDismissDisabled(busy || dirty)
        .alert(text("放弃未保存的远程配置？", "Discard unsaved remote configuration?"), isPresented: $showDiscardConfirmation) {
            Button(text("继续编辑", "Keep Editing"), role: .cancel) { pendingNavigation = nil }
            Button(text("放弃修改", "Discard Changes"), role: .destructive) {
                guard let navigation = pendingNavigation else { return }
                pendingNavigation = nil
                perform(navigation)
            }
        } message: {
            Text(text("当前输入尚未保存。你可以继续编辑，或放弃修改后继续。", "Your input has not been saved. Keep editing or discard it to continue."))
        }
        .onAppear {
            selection = model.gitRemotes.first?.name; loadSelection()
            model.confirmSheetQuit = { confirmQuit() }
        }
        .onDisappear { model.confirmSheetQuit = nil }
        .onChange(of: model.selectedProjectID) { _ in dismiss() }
    }
    private func confirmQuit() -> Bool {
        guard dirty else { dismiss(); return true }
        let alert = NSAlert()
        alert.messageText = text("放弃未保存的远程配置并退出？", "Discard unsaved remote configuration and quit?")
        alert.informativeText = text("选择继续编辑后，可以先保存远程配置。", "Keep editing to save your remote configuration first.")
        alert.addButton(withTitle: text("继续编辑", "Keep Editing")).keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: text("放弃并退出", "Discard and Quit"))
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        dismiss(); return true
    }
    private func navigate(_ navigation: Navigation) {
        guard !busy else { return }
        if dirty {
            pendingNavigation = navigation
            showDiscardConfirmation = true
        } else { perform(navigation) }
    }
    private func perform(_ navigation: Navigation) {
        switch navigation {
        case .select(let value): selection = value; loadSelection()
        case .refresh: refresh()
        case .close: dismiss()
        case .remove:
            guard let existing else { return }
            model.remoteAction(.remove, name: existing.name, expected: snapshot) { result in
                failure = result.status == 0 ? nil : result.output
                if result.status == 0 {
                    selection = nil; loadSelection()
                    feedback = text("已移除本地远程配置。", "Local remote configuration removed.")
                }
            }
        }
    }
    private func save() {
        guard !busy, inputError == nil else { return }
        let remoteName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        model.remoteAction(existing == nil ? .add : .setURL, name: remoteName, url: url.trimmingCharacters(in: .whitespacesAndNewlines), expected: snapshot) { result in
            failure = result.status == 0 ? nil : result.output
            if result.status == 0 {
                selection = remoteName; loadSelection()
                feedback = text("远程配置已保存。", "Remote configuration saved.")
            }
        }
    }
    private func loadSelection() {
        failure = nil; feedback = nil
        snapshot = existing
        if let existing { name = existing.name; url = existing.fetchURL }
        else { name = model.gitRemotes.contains { $0.name == "origin" } ? "" : "origin"; url = "" }
        baselineName = name; baselineURL = url
    }
    private func refresh() {
        guard let project = model.selectedProject else { return }
        refreshing = true; failure = nil; feedback = nil
        Task {
            let remotes = await GitService.remotes(at: project.path)
            guard model.selectedProjectID == project.id else { refreshing = false; return }
            model.gitRemotes = remotes
            if !remotes.contains(where: { $0.name == selection }) { selection = nil }
            loadSelection(); refreshing = false
        }
    }
}

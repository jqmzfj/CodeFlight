import SwiftUI

/// Selecting a reference only changes the log scope. Repository mutations are
/// explicit context-menu actions using the existing checked model operations.
struct GitHistoryNavigator: View {
    @ObservedObject var model: WorkbenchModel
    @Binding var selection: String
    let compare: (String) -> Void
    let newBranch: () -> Void
    let manageTags: () -> Void
    @State private var search = ""
    @AppStorage("layout.gitHistory.localExpanded") private var localExpanded = true
    @AppStorage("layout.gitHistory.remoteExpanded") private var remoteExpanded = true
    @AppStorage("layout.gitHistory.tagsExpanded") private var tagsExpanded = false

    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private func filtered(_ names: [String]) -> [String] {
        names.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(text("分支", "Branches")).font(.system(size: 11, weight: .medium))
                Spacer()
                Button(action: newBranch) { Image(systemName: "plus") }
                    .disabled(model.isGitBusy).help(text("新建分支", "New branch"))
                    .accessibilityLabel(text("新建分支", "New branch"))
                Button(action: manageTags) { Image(systemName: "tag") }
                    .help(text("管理标签", "Manage tags"))
                    .accessibilityLabel(text("管理标签", "Manage tags"))
            }.buttonStyle(.borderless).padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
            TextField(text("筛选分支和标签", "Filter branches and tags"), text: $search)
                .textFieldStyle(.roundedBorder).controlSize(.small).padding(.horizontal, 8).padding(.bottom, 6)
                .onSubmit { selectFirstMatch() }
                .onExitCommand { search = "" }
                .accessibilityHint(text("回车选中第一个匹配的分支或标签，Esc 清空筛选。", "Return selects the first matching branch or tag. Escape clears the filter."))
            List(selection: $selection) {
                Label(text("所有分支", "All branches"), systemImage: "tray.full").tag("--all")
                Label(text("当前分支", "Current branch"), systemImage: "location").tag("HEAD")
                DisclosureGroup(isExpanded: $localExpanded) {
                    referenceRows(filtered(model.gitBranches), prefix: "refs/heads/", icon: "arrow.triangle.branch")
                } label: { Text(text("本地分支", "Local branches")) }
                DisclosureGroup(isExpanded: $remoteExpanded) {
                    referenceRows(filtered(model.gitRemoteBranches), prefix: "refs/remotes/", icon: "cloud")
                } label: { Text(text("远程分支", "Remote branches")) }
                DisclosureGroup(isExpanded: $tagsExpanded) {
                    referenceRows(filtered(model.gitTags), prefix: "refs/tags/", icon: "tag")
                } label: { Text(text("标签", "Tags")) }
                if !search.isEmpty && filtered(model.gitBranches + model.gitRemoteBranches + model.gitTags).isEmpty {
                    Text(text("没有匹配的引用", "No matching references")).foregroundStyle(.secondary)
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
                .accessibilityLabel(text("分支导航", "Branch navigator"))
                .font(.system(size: 11)).controlSize(.small).environment(\.defaultMinListRowHeight, GitGraphCell.rowHeight)
        }.frame(maxHeight: .infinity).background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        .onReceive(NotificationCenter.default.publisher(for: WorkbenchLayout.didReset)) { _ in
            localExpanded = true
            remoteExpanded = true
            tagsExpanded = false
        }
        .onChange(of: search) { value in
            if !value.isEmpty { localExpanded = true; remoteExpanded = true; tagsExpanded = true }
        }
    }

    private func selectFirstMatch() {
        if let name = filtered(model.gitBranches).first { selection = "refs/heads/" + name; return }
        if let name = filtered(model.gitRemoteBranches).first { selection = "refs/remotes/" + name; return }
        if let name = filtered(model.gitTags).first { selection = "refs/tags/" + name }
    }

    private func referenceRows(_ names: [String], prefix: String, icon: String) -> some View {
        ForEach(names, id: \.self) { name in
            let reference = prefix + name
            let current = prefix == "refs/heads/" && name == model.gitBranch
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 12).accessibilityHidden(true)
                Text(name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).font(.system(size: 9)).accessibilityHidden(true) }
            }.frame(height: 20).tag(reference).help(name)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name + (current ? text("，当前检出分支", ", checked out branch") : ""))
            .contextMenu {
                Button(text("显示提交历史", "Show history")) { selection = reference }
                Button(text("与当前分支比较…", "Compare with current branch…")) { compare(reference) }
                if prefix != "refs/tags/" {
                    Divider()
                    if !current {
                        Button(text("切换分支", "Checkout branch")) {
                            if prefix == "refs/remotes/" { model.checkoutRemoteBranch(name) }
                            else { model.checkoutBranch(name) }
                        }.disabled(model.isGitBusy || model.gitOperationState != nil)
                        Button(text("合并到当前分支…", "Merge into current branch…")) { model.mergeBranch(reference) }
                            .disabled(model.isGitBusy || model.gitOperationState != nil)
                        Button(text("将当前分支变基到此处…", "Rebase current branch onto this…")) { model.rebaseBranch(reference) }
                            .disabled(model.isGitBusy || model.gitOperationState != nil)
                        if prefix == "refs/heads/" && current {
                            Divider()
                            Button(text("推送…", "Push…")) { model.gitAction(.push) }
                                .disabled(model.isGitBusy || model.gitOperationState != nil)
                        }
                        if prefix == "refs/heads/" {
                            Divider()
                            Button(text("删除分支…", "Delete branch…"), role: .destructive) { model.deleteBranch(name) }
                                .disabled(model.isGitBusy)
                        }
                    }
                } else {
                    Button(text("管理标签…", "Manage tags…"), action: manageTags)
                }
            }
        }
    }
}

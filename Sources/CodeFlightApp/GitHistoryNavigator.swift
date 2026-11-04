import SwiftUI

/// Keeps the checked-out branch at the top of the local list without
/// re-sorting the remaining ones, so the list stays stable across refreshes.
enum GitBranchOrdering {
    static func currentFirst(_ branches: [String], current: String) -> [String] {
        guard !current.isEmpty, let index = branches.firstIndex(of: current), index > 0 else { return branches }
        var values = branches
        let branch = values.remove(at: index)
        values.insert(branch, at: 0)
        return values
    }
}

/// Selecting a reference only changes the log scope. Repository mutations are
/// explicit context-menu actions using the existing checked model operations.
struct GitHistoryNavigator: View {
    @ObservedObject var model: WorkbenchModel
    @Binding var selection: String
    let compare: (String) -> Void
    let newBranch: () -> Void
    let manageTags: () -> Void
    var onCollapse: (() -> Void)? = nil
    var onNavigateToBranchHead: ((String) -> Void)? = nil

    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @AppStorage("layout.gitHistory.localExpanded") private var localExpanded = true
    @AppStorage("layout.gitHistory.remoteExpanded") private var remoteExpanded = true
    @AppStorage("layout.gitHistory.tagsExpanded") private var tagsExpanded = false
    @AppStorage("git.favoriteBranches") private var favoriteBranchesJSON: String = "[]"
    @State private var showOnlyFavorites = false
    @State private var groupByDirectory = true
    @State private var expandedFolders: Set<String> = ["origin"]
    @State private var branchToDelete: String? = nil

    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private func filtered(_ names: [String]) -> [String] {
        names.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
    }

    private var favoriteBranches: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: Data(favoriteBranchesJSON.utf8))) ?? []
    }
    private func toggleFavorite(_ branch: String) {
        var set = favoriteBranches
        if set.contains(branch) { set.remove(branch) } else { set.insert(branch) }
        if let data = try? JSONEncoder().encode(set), let str = String(data: data, encoding: .utf8) {
            favoriteBranchesJSON = str
        }
    }

    private var selectedReference: String? {
        selection.isEmpty ? nil : selection
    }
    private var selectedBranchName: String? {
        for prefix in ["refs/heads/", "refs/remotes/"] {
            if selection.hasPrefix(prefix) { return String(selection.dropFirst(prefix.count)) }
        }
        return selection == "HEAD" ? model.gitBranch : nil
    }
    private var isSelectedFavorite: Bool {
        guard let name = selectedBranchName else { return false }
        return favoriteBranches.contains(name)
    }

    private func handleCheckoutSelected() {
        guard let name = selectedBranchName else { return }
        if selection.hasPrefix("refs/remotes/") {
            model.checkoutRemoteBranch(name)
        } else {
            model.checkoutBranch(name)
        }
    }

    private func handleSelectCurrentBranch() {
        localExpanded = true
        let currentRef = "refs/heads/" + model.gitBranch
        selection = currentRef
        onNavigateToBranchHead?(currentRef)
    }

    private func handleFilterLogBySelected() {
        guard let ref = selectedReference else { return }
        onNavigateToBranchHead?(ref)
    }

    private func expandAll() {
        localExpanded = true
        remoteExpanded = true
        tagsExpanded = true
        expandedFolders = Set(allRemoteFolders)
    }

    private func collapseAll() {
        localExpanded = false
        remoteExpanded = false
        tagsExpanded = false
        expandedFolders.removeAll()
    }

    private var allRemoteFolders: [String] {
        var folders: Set<String> = []
        for branch in model.gitRemoteBranches {
            let parts = branch.split(separator: "/")
            if parts.count > 1 {
                folders.insert(String(parts[0]))
                if parts.count > 2 {
                    folders.insert("\(parts[0])/\(parts[1])")
                }
            }
        }
        return Array(folders)
    }

    var body: some View {
        HStack(spacing: 0) {
            verticalRail
            Rectangle().fill(WorkbenchChrome.quietSeparator).frame(width: 0.5)

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        TextField(text("分支或标签", "Branch or tag"), text: $search)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .focused($searchFocused)
                        if !search.isEmpty {
                            Button { search = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3.5)
                    .background(WorkbenchChrome.editor, in: Capsule())
                    .overlay(Capsule().stroke(WorkbenchChrome.subtleDivider, lineWidth: 0.5))
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(WorkbenchChrome.panel)
                .onSubmit { selectFirstMatch() }
                .onExitCommand { search = "" }

                List(selection: $selection) {
                    Label("HEAD(\(text("当前分支", "current branch")))", systemImage: "arrow.triangle.branch")
                        .tag("HEAD")
                        .font(.system(size: 11))

                    DisclosureGroup(isExpanded: $localExpanded) {
                        localBranchesTree
                    } label: { Text(text("本地", "Local")) }

                    DisclosureGroup(isExpanded: $remoteExpanded) {
                        remoteBranchesTree
                    } label: { Text(text("远程", "Remote")) }

                    DisclosureGroup(isExpanded: $tagsExpanded) {
                        tagsTree
                    } label: { Text(text("标签", "Tags")) }

                    if !search.isEmpty && filtered(model.gitBranches + model.gitRemoteBranches + model.gitTags).isEmpty {
                        Text(text("没有匹配的引用", "No matching references")).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .accessibilityLabel(text("分支导航", "Branch navigator"))
                .font(.system(size: 11)).foregroundStyle(.primary).controlSize(.small)
                .environment(\.defaultMinListRowHeight, GitGraphCell.rowHeight)
            }
        }
        .frame(maxHeight: .infinity)
        .background(WorkbenchChrome.panel)
        .onReceive(NotificationCenter.default.publisher(for: WorkbenchLayout.didReset)) { _ in
            localExpanded = true
            remoteExpanded = true
            tagsExpanded = false
        }
        .onChange(of: search) { value in
            if !value.isEmpty { expandAll() }
        }
    }

    private var canDeleteSelected: Bool {
        guard let name = selectedBranchName, !selection.hasPrefix("refs/remotes/"), name != model.gitBranch else { return false }
        return !model.isGitBusy
    }

    private var verticalRail: some View {
        VStack(spacing: 2) {
            // 1. 折叠分支面板 <
            railButton(icon: "chevron.left", helpText: text("收起分支面板", "Collapse branches panel")) {
                onCollapse?()
            }

            // 2. 新建分支 +
            railButton(icon: "plus", helpText: text("新建分支…", "New branch…")) {
                newBranch()
            }
            .disabled(model.isGitBusy)

            // 3. 检出分支 ↙
            railButton(icon: "arrow.down.left", helpText: text("检出选中分支", "Checkout selected branch")) {
                handleCheckoutSelected()
            }
            .disabled(model.isGitBusy || selectedBranchName == nil || selectedBranchName == model.gitBranch)

            // 4. 删除分支 🗑
            railButton(icon: "trash", helpText: text("删除选中分支…", "Delete selected branch…")) {
                if let name = selectedBranchName {
                    branchToDelete = name
                }
            }
            .disabled(!canDeleteSelected)

            // 5. 与当前分支比较 ⇄
            railButton(icon: "arrow.left.arrow.right", helpText: text("与当前分支比较…", "Compare with current branch…")) {
                if let ref = selectedReference {
                    compare(ref)
                }
            }
            .disabled(selectedReference == nil)

            // 6. 在日志中按此分支筛选 🔍
            railButton(icon: "magnifyingglass", helpText: text("在日志中按此分支筛选", "Filter log by selected branch")) {
                handleFilterLogBySelected()
            }
            .disabled(selectedReference == nil)

            // 7. 在日志中导航到所选分支的 HEAD ⌞↙
            Button {
                if let ref = selectedReference {
                    onNavigateToBranchHead?(ref)
                }
            } label: {
                NavigateToHeadIcon(color: selectedReference == nil ? .secondary.opacity(0.35) : .secondary)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(selectedReference == nil)
            .help(text("在日志中导航到所选分支的 HEAD", "Navigate Log to Selected Branch Head"))

            // 8. 收藏分支 ⭐
            railButton(
                icon: isSelectedFavorite ? "star.fill" : "star",
                iconColor: isSelectedFavorite ? .yellow : .secondary,
                helpText: text("收藏 / 取消收藏分支", "Favorite / unfavorite branch")
            ) {
                if let name = selectedBranchName {
                    toggleFavorite(name)
                } else {
                    showOnlyFavorites.toggle()
                }
            }

            // 9. 定位到当前检出的分支 ⌖
            railButton(icon: "scope", helpText: text("定位到当前分支", "Select currently checked out branch")) {
                handleSelectCurrentBranch()
            }
            .disabled(model.gitBranch.isEmpty)

            // 10. 分支视图设置 ⚙▾
            Menu {
                Toggle(text("按目录分组", "Group by directory"), isOn: $groupByDirectory)
                Toggle(text("仅显示收藏分支", "Show only favorites"), isOn: $showOnlyFavorites)
                Toggle(text("展开本地分支", "Expand local branches"), isOn: $localExpanded)
                Toggle(text("展开远程分支", "Expand remote branches"), isOn: $remoteExpanded)
                Toggle(text("展开标签", "Expand tags"), isOn: $tagsExpanded)
                Divider()
                Button(text("全部展开", "Expand all")) { expandAll() }
                Button(text("全部折叠", "Collapse all")) { collapseAll() }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(text("分支选项", "Branch view options"))

            Spacer()

            Rectangle().fill(WorkbenchChrome.quietSeparator).frame(height: 1).padding(.horizontal, 4)

            // 11. 独立目录分组 📁
            railButton(
                icon: "folder",
                iconColor: groupByDirectory ? Color.accentColor : .secondary,
                helpText: groupByDirectory ? text("切换为扁平列表", "Switch to flat list") : text("按目录分组", "Group by directory")
            ) {
                groupByDirectory.toggle()
            }

            // 12. 全部展开 ↕
            railButton(icon: "arrow.up.and.down", helpText: text("全部展开", "Expand all")) {
                expandAll()
            }

            // 13. 全部收起 ><
            railButton(icon: "arrow.down.and.line.horizontal.and.arrow.up", helpText: text("全部折叠", "Collapse all")) {
                collapseAll()
            }
        }
        .padding(.vertical, 4)
        .frame(width: 26)
        .background(WorkbenchChrome.bar)
        .alert(isPresented: Binding(get: { branchToDelete != nil }, set: { if !$0 { branchToDelete = nil } })) {
            let target = branchToDelete ?? ""
            return Alert(
                title: Text(text("删除分支", "Delete Branch")),
                message: Text(text("确定要删除分支“\(target)”吗？此操作无法撤销。", "Are you sure you want to delete branch “\(target)”? This action cannot be undone.")),
                primaryButton: .destructive(Text(text("删除", "Delete"))) {
                    model.deleteBranch(target)
                    branchToDelete = nil
                },
                secondaryButton: .cancel(Text(text("取消", "Cancel"))) {
                    branchToDelete = nil
                }
            )
        }
    }

    private func railButton(icon: String, iconColor: Color = .secondary, helpText: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(iconColor)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private func selectFirstMatch() {
        if let name = GitBranchOrdering.currentFirst(filtered(model.gitBranches), current: model.gitBranch).first {
            selection = "refs/heads/" + name
            return
        }
        if let name = filtered(model.gitRemoteBranches).first { selection = "refs/remotes/" + name; return }
        if let name = filtered(model.gitTags).first { selection = "refs/tags/" + name }
    }

    @ViewBuilder
    private var localBranchesTree: some View {
        let allLocal = filtered(model.gitBranches)
        let visible = showOnlyFavorites ? allLocal.filter { favoriteBranches.contains($0) } : allLocal
        let list = GitBranchOrdering.currentFirst(visible, current: model.gitBranch)
        ForEach(list, id: \.self) { branch in
            branchRow(name: branch, displayName: branch, prefix: "refs/heads/")
        }
    }

    @ViewBuilder
    private var remoteBranchesTree: some View {
        let allRemotes = filtered(model.gitRemoteBranches)
        let list = showOnlyFavorites ? allRemotes.filter { favoriteBranches.contains($0) } : allRemotes
        if groupByDirectory {
            let grouped = Dictionary(grouping: list) { branch -> String in
                branch.split(separator: "/", maxSplits: 1).first.map(String.init) ?? "origin"
            }
            ForEach(grouped.keys.sorted(), id: \.self) { remoteName in
                let isExpandedBinding = Binding(
                    get: { expandedFolders.contains(remoteName) },
                    set: { expanded in
                        if expanded { expandedFolders.insert(remoteName) }
                        else { expandedFolders.remove(remoteName) }
                    }
                )
                DisclosureGroup(isExpanded: isExpandedBinding) {
                    let branchesInRemote = (grouped[remoteName] ?? []).sorted()
                    // Sub-group by subfolder if any (like feature/...)
                    let subGrouped = Dictionary(grouping: branchesInRemote) { branch -> String in
                        let rest = branch.hasPrefix(remoteName + "/") ? String(branch.dropFirst(remoteName.count + 1)) : branch
                        if rest.contains("/") {
                            return String(rest.split(separator: "/").first ?? "")
                        }
                        return ""
                    }
                    // Direct branches without subfolder
                    ForEach(subGrouped[""] ?? [], id: \.self) { branch in
                        let displayName = branch.hasPrefix(remoteName + "/") ? String(branch.dropFirst(remoteName.count + 1)) : branch
                        branchRow(name: branch, displayName: displayName, prefix: "refs/remotes/")
                    }
                    // Subfolders (e.g. feature)
                    ForEach(subGrouped.keys.filter { !$0.isEmpty }.sorted(), id: \.self) { subFolder in
                        let subFolderKey = "\(remoteName)/\(subFolder)"
                        let subExpandedBinding = Binding(
                            get: { expandedFolders.contains(subFolderKey) },
                            set: { expanded in
                                if expanded { expandedFolders.insert(subFolderKey) }
                                else { expandedFolders.remove(subFolderKey) }
                            }
                        )
                        DisclosureGroup(isExpanded: subExpandedBinding) {
                            ForEach(subGrouped[subFolder] ?? [], id: \.self) { branch in
                                let fullSub = "\(remoteName)/\(subFolder)/"
                                let displayName = branch.hasPrefix(fullSub) ? String(branch.dropFirst(fullSub.count)) : branch
                                branchRow(name: branch, displayName: displayName, prefix: "refs/remotes/")
                            }
                        } label: {
                            Label(subFolder, systemImage: "folder")
                                .font(.system(size: 11))
                        }
                    }
                } label: {
                    Label(remoteName, systemImage: "folder")
                        .font(.system(size: 11))
                }
            }
        } else {
            ForEach(list, id: \.self) { branch in
                branchRow(name: branch, displayName: branch, prefix: "refs/remotes/")
            }
        }
    }

    @ViewBuilder
    private var tagsTree: some View {
        let allTags = filtered(model.gitTags)
        ForEach(allTags, id: \.self) { tag in
            branchRow(name: tag, displayName: tag, prefix: "refs/tags/")
        }
    }

    private func branchRow(name: String, displayName: String, prefix: String) -> some View {
        let reference = prefix + name
        let current = prefix == "refs/heads/" && name == model.gitBranch
        let isFav = favoriteBranches.contains(name) || favoriteBranches.contains(displayName)

        return HStack(spacing: 6) {
            if isFav {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .frame(width: 12)
                    .font(.system(size: 10))
            } else if prefix == "refs/tags/" {
                Image(systemName: "tag")
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }

            Text(displayName)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            if current {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 9))
            }
        }
        .frame(height: 20)
        .tag(reference)
        .help(name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayName + (current ? text("，当前检出分支", ", checked out branch") : ""))
        .contextMenu {
            Button(text("显示提交历史", "Show history")) { selection = reference }
            Button(text("与当前分支比较…", "Compare with current branch…")) { compare(reference) }
            Divider()
            Button(isFav ? text("取消收藏", "Remove from Favorites") : text("添加到收藏", "Add to Favorites")) {
                toggleFavorite(name)
            }
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

/// Matches JetBrains "Navigate Log to Selected Branch Head" icon:
/// a dashed corner box with a dashed diagonal arrow pointing into it.
struct NavigateToHeadIcon: View {
    var color: Color = .secondary
    var size: CGFloat = 13

    var body: some View {
        Canvas { context, sz in
            let w = sz.width
            let h = sz.height
            let solidStroke = StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
            let dashStroke = StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round, dash: [2.5, 2.0])

            // Left vertical dashed line
            var leftLine = Path()
            leftLine.move(to: CGPoint(x: w * 0.20, y: h * 0.35))
            leftLine.addLine(to: CGPoint(x: w * 0.20, y: h * 0.85))
            context.stroke(leftLine, with: .color(color), style: dashStroke)

            // Bottom horizontal dashed line
            var bottomLine = Path()
            bottomLine.move(to: CGPoint(x: w * 0.20, y: h * 0.85))
            bottomLine.addLine(to: CGPoint(x: w * 0.82, y: h * 0.85))
            context.stroke(bottomLine, with: .color(color), style: dashStroke)

            // Diagonal dashed arrow shaft
            var diag = Path()
            diag.move(to: CGPoint(x: w * 0.80, y: h * 0.20))
            diag.addLine(to: CGPoint(x: w * 0.34, y: h * 0.68))
            context.stroke(diag, with: .color(color), style: dashStroke)

            // Arrow head pointing to bottom-left corner
            var head = Path()
            head.move(to: CGPoint(x: w * 0.32, y: h * 0.46))
            head.addLine(to: CGPoint(x: w * 0.30, y: h * 0.72))
            head.addLine(to: CGPoint(x: w * 0.56, y: h * 0.72))
            context.stroke(head, with: .color(color), style: solidStroke)
        }
        .frame(width: size, height: size)
    }
}

import SwiftUI
import AppKit

struct WorkbenchView: View {
    @ObservedObject var model: WorkbenchModel
    @StateObject private var backdrop = WorkbenchBackdrop()
    @Environment(\.colorScheme) private var colorScheme
    @State private var showBranches = false
    @State private var showBranchSheet = false
    @State private var showRenameBranchSheet = false
    @State private var showUpstreamSheet = false
    @State private var showRemoteSheet = false
    @State private var showTagSheet = false
    @State private var comparisonTarget: GitComparisonTarget?
    @State private var remoteBranchToDelete: GitComparisonTarget?
    @State private var showWorktrees = false
    @State private var showSubmodules = false
    @State private var gitPromptKind: GitPromptKind?
    @State private var topPanel: TopPanel = .files
    @State private var bottomTool: BottomTool = .console
    @State private var bottomToolExpanded = false
    @State private var gitHistoryRevision = UUID()
    @State private var showGitOperations = false
    @State private var sidebarVisible = true
    @State private var settingsHovering = false
    @State private var sidebarWidth: CGFloat = 252
    @State private var toolRailWidth: CGFloat = 44
    @State private var bottomToolHeight: CGFloat = 180
    @State private var toolHeights: [BottomTool: CGFloat] = [:]
    @State private var expandedFileItems: [UUID: Set<String>] = [:]
    @State private var fileSearch = ""
    @State private var showEditorSearch = false
    @State private var editorSearch = ""
    @State private var editorNavigation: FileSearchNavigation?
    @FocusState private var editorSearchFocused: Bool
    @FocusState private var fileSearchFocused: Bool
    @State private var previewSnapshot: PreviewSearchSnapshot?
    private var searchableDocument: PreparedCodeDocument? {
        previewSnapshot?.document(file: model.selectedFile, source: model.fileContent)
    }
    private var fileLineCount: Int { searchableDocument?.offsets.count ?? 0 }
    private var canSearchPreview: Bool {
        guard !model.selectedFile.isEmpty, model.diffContent.isEmpty, model.conflictDocument == nil else { return false }
        guard let kind = model.filePreviewDocument?.kind else { return true }
        return kind == .text || kind == .empty
    }

    init(model: WorkbenchModel) {
        self.model = model
        let defaults = UserDefaults.standard
        let savedSidebar = defaults.double(forKey: "sidebarWidth")
        let savedRail = defaults.double(forKey: "layout.toolRailWidth")
        let savedTool = defaults.string(forKey: "bottomTool") ?? BottomTool.console.rawValue
        let savedTopPanel = TopPanel(rawValue: defaults.string(forKey: "topPanel") ?? "") ?? .files
        let perTool = defaults.double(forKey: "layout.split.main.bottom." + savedTool)
        let savedBottom = perTool > 0 ? perTool : defaults.double(forKey: "bottomToolHeight")
        _sidebarWidth = State(initialValue: savedSidebar > 0 ? max(180, savedSidebar) : 285)
        _toolRailWidth = State(initialValue: savedRail > 0 ? min(72, max(36, savedRail)) : 44)
        _bottomToolHeight = State(initialValue: savedBottom > 0 ? max(160, savedBottom) : 180)
        _bottomToolExpanded = State(initialValue: defaults.bool(forKey: "bottomToolExpanded"))
        _bottomTool = State(initialValue: BottomTool(rawValue: defaults.string(forKey: "bottomTool") ?? "") ?? .console)
        _topPanel = State(initialValue: savedTopPanel)
        _sidebarVisible = State(initialValue: defaults.object(forKey: "layout.sidebarVisible") as? Bool ?? true)
    }

    var body: some View {
        ZStack {
            backgroundView
            VStack(alignment: .leading, spacing: 0) {
                projectTabs
                Rectangle().fill(WorkbenchChrome.quietSeparator).frame(height: 1)
                HStack(spacing: 0) {
                    toolRail
                    SplitDivider(axis: .vertical, dimension: $toolRailWidth, range: 36...72,
                                 reset: { toolRailWidth = 44 },
                                 commit: { UserDefaults.standard.set(toolRailWidth, forKey: "layout.toolRailWidth") })
                    Rectangle().fill(WorkbenchChrome.quietSeparator).frame(width: 1)
                    if bottomToolExpanded {
                        WorkbenchSplit("main.bottom.\(bottomTool.rawValue)", axis: .horizontal,
                            initial: bottomTool == .gitTree ? 280 : 180, minimum: 160, otherMinimum: upperWorkspaceMinimumHeight,
                            resizesSecond: true, dimension: $bottomToolHeight) {
                            upperWorkspace
                        } second: {
                            bottomToolWindow
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .layoutPriority(1)
                    } else {
                        upperWorkspace
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .layoutPriority(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                statusBar
            }
        }
        .background(WorkbenchWindowAnchor().frame(width: 0, height: 0))
        .toolbarRole(.editor)
        .toolbar { workbenchToolbar }
        .task(id: model.background) { await backdrop.load(backgroundURL) }
        .preferredColorScheme(model.theme.colorScheme)
        .onChange(of: model.fileNavigatorFocusRequest) { _ in topPanel = .files; sidebarVisible = true }
        .onChange(of: model.gitNavigatorFocusRequest) { _ in topPanel = .git; sidebarVisible = true }
        .onChange(of: model.fileSearchFocusRequest) { _ in
            topPanel = .files
            sidebarVisible = true
            DispatchQueue.main.async { fileSearchFocused = true }
        }
        .onChange(of: model.terminalFocusRequest) { _ in revealBottomTool(.console) }
        .onChange(of: model.bottomToolFocusRequest) { request in handleBottomToolFocus(request) }
        .onChange(of: model.bottomToolToggleRequest) { _ in
            guard model.selectedProjectID != nil else { return }
            withAnimation(.easeInOut(duration: 0.18)) { bottomToolExpanded.toggle() }
        }
        .sheet(isPresented: $model.showRunSettings) { RunCommandSettings(model: model) }
        .sheet(item: $model.gitBlameTarget) { target in GitBlameSheet(model: model, target: target) }
        .sheet(isPresented: $model.showCloneSheet) { GitCloneSheet(model: model) }
        .sheet(item: $model.gitSyncKind) { kind in GitSyncSheet(model: model, kind: kind) }
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model, backdrop: backdrop) }
        .sheet(isPresented: $model.showCommandPalette, onDismiss: { model.completePaletteDismissal() }) { CommandPaletteView(model: model) }
        .sheet(isPresented: $showBranchSheet) { BranchSheet(model: model) }
        .sheet(isPresented: $showRenameBranchSheet) { RenameBranchSheet(model: model) }
        .sheet(isPresented: $showUpstreamSheet) { GitUpstreamSheet(model: model) }
        .sheet(isPresented: $showRemoteSheet) { RemoteSheet(model: model) }
        .sheet(isPresented: $showTagSheet) { GitTagsSheet(model: model) }
        .sheet(item: $comparisonTarget) { target in GitBranchComparisonSheet(model: model, target: target.id) }
        .sheet(item: $remoteBranchToDelete) { target in GitRemoteBranchDeleteSheet(model: model, target: target.id) }
        .sheet(isPresented: $showWorktrees) { GitWorktreesSheet(model: model) }
        .sheet(isPresented: $showSubmodules) { GitSubmodulesSheet(model: model) }
        .sheet(item: $gitPromptKind) { kind in GitPromptSheet(model: model, kind: kind) }
        .overlay(alignment: .topTrailing) {
            if let error = model.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(Copy.t("操作未完成", "Operation failed", language: model.language), systemImage: "exclamationmark.circle").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                        Spacer()
                        Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(Copy.t("关闭提示", "Dismiss", language: model.language))
                    }
                    Text(error).font(.system(size: 11)).lineLimit(3).textSelection(.enabled)
                    Button(Copy.t("查看详细信息", "Show details", language: model.language)) {
                        model.revealErrorInConsole()
                        showGitOperations = true; revealBottomTool(.gitTree)
                    }.buttonStyle(.link).font(.system(size: 11))
                }.padding(12).frame(width: 320).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.12)))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4).padding(.top, 58).padding(.trailing, 16)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WorkbenchLayout.didReset)) { _ in resetLayoutState() }
        .onChange(of: sidebarWidth) { _ in UserDefaults.standard.set(sidebarWidth, forKey: "sidebarWidth") }
        .onChange(of: toolRailWidth) { value in UserDefaults.standard.set(min(72, max(36, value)), forKey: "layout.toolRailWidth") }
        .onChange(of: bottomToolHeight) { _ in UserDefaults.standard.set(bottomToolHeight, forKey: "bottomToolHeight") }
        .onChange(of: bottomToolExpanded) { UserDefaults.standard.set($0, forKey: "bottomToolExpanded") }
        .onChange(of: topPanel) { UserDefaults.standard.set($0.rawValue, forKey: "topPanel") }
        .onChange(of: sidebarVisible) { UserDefaults.standard.set($0, forKey: "layout.sidebarVisible") }
        .onChange(of: bottomTool) { UserDefaults.standard.set($0.rawValue, forKey: "bottomTool") }
        .onChange(of: model.projects.map(\.id)) { ids in
            expandedFileItems = expandedFileItems.filter { ids.contains($0.key) }
        }
        .onChange(of: model.selectedFile) { file in
            editorNavigation = nil
            if previewSnapshot?.file != file { previewSnapshot = nil }
        }
        .onChange(of: model.fileContent) { content in
            editorNavigation = nil
            if previewSnapshot?.source != content { previewSnapshot = nil }
        }
        .onChange(of: canSearchPreview) { canSearch in if !canSearch { closeEditorSearch() } }
        .onChange(of: model.selectedProjectID) { _ in
            fileSearch = ""
            editorSearch = ""
            showEditorSearch = false
            if model.selectedProjectID == nil {
                withAnimation(.easeInOut(duration: 0.18)) { bottomToolExpanded = false }
            }
        }
        .onChange(of: model.runRequestID) { _ in
            revealBottomTool(.processes)
        }
        .onChange(of: model.gitFileHistoryRequest) { _ in
            showGitOperations = false
            revealBottomTool(.gitTree)
        }
    }

    private var backgroundURL: URL? {
        if case .image(let url) = model.background { return url }
        return nil
    }

    private var backgroundView: some View {
        Group {
            switch model.background {
            case .plain: Color(nsColor: .windowBackgroundColor)
            case .aurora:
                LinearGradient(colors: colorScheme == .dark ? [Color(red: 0.035, green: 0.045, blue: 0.07), Color(red: 0.09, green: 0.07, blue: 0.14)] : [Color.white, Color(red: 0.92, green: 0.95, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            case .image:
                if let image = backdrop.image {
                    GeometryReader { geometry in
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                            .overlay(Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.62 : 0.76))
                            .accessibilityHidden(true)
                    }
                } else { Color(nsColor: .windowBackgroundColor) }
            }
        }.ignoresSafeArea()
    }

    @ToolbarContentBuilder private var workbenchToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                .accessibilityLabel(Copy.t("显示或隐藏导航栏", "Toggle navigator", language: model.language)).help(Copy.t("显示或隐藏导航栏", "Toggle navigator", language: model.language))
            RunToolbar(model: model)
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(model.selectedProject?.name ?? "CodeFlight").font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180).help(model.selectedProject?.path ?? "CodeFlight")
                if model.selectedProjectID != nil {
                    Divider().frame(height: 14)
                    branchControl
                }
                if model.isGitBusy { ProgressView().controlSize(.mini) }
            }.fixedSize(horizontal: true, vertical: false)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            runConfigurationMenu
            Button { model.showCommandPalette = true } label: { Image(systemName: "magnifyingglass") }
                .accessibilityLabel(Copy.t("命令面板 ⌘K", "Command palette ⌘K", language: model.language)).help(Copy.t("命令面板 ⌘K", "Command palette ⌘K", language: model.language))
        }
    }

    private var branchControl: some View {
            Button { showBranches.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(model.gitBranch.isEmpty ? (model.isGitRepository ? "HEAD" : Copy.t("未初始化 Git", "Git not initialized", language: model.language)) : model.gitBranch).lineLimit(1).truncationMode(.middle).frame(maxWidth: 200)
                    if let tracking = model.gitTracking {
                        if tracking.gone {
                            Text("!").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.orange)
                                .help(Copy.t("上游分支已失效", "Upstream branch is gone", language: model.language))
                        } else {
                            if let ahead = tracking.ahead, ahead > 0 {
                                Text("↑\(ahead)").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(Color.accentColor)
                                    .help(Copy.t("领先 \(ahead) 个提交，可推送", "Ahead by \(ahead) commits; ready to push", language: model.language))
                            }
                            if let behind = tracking.behind, behind > 0 {
                                Text("↓\(behind)").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.orange)
                                    .help(Copy.t("落后 \(behind) 个提交，可拉取", "Behind by \(behind) commits; ready to pull", language: model.language))
                            }
                        }
                    }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.clear)
            }.buttonStyle(.plain).accessibilityLabel(Copy.t("切换与管理分支", "Switch and manage branches", language: model.language))
                .accessibilityValue(model.gitBranch)
                .help(model.gitBranch.isEmpty ? Copy.t("切换与管理分支", "Switch and manage branches", language: model.language) : model.gitBranch)
                .disabled(model.selectedProjectID == nil)
                .popover(isPresented: $showBranches, arrowEdge: .bottom) {
                    GitBranchPopover(model: model, newBranch: { showBranches = false; showBranchSheet = true }, renameBranch: { showBranches = false; showRenameBranchSheet = true }, manageTags: { showBranches = false; showTagSheet = true }, manageUpstream: { showBranches = false; showUpstreamSheet = true }, compareBranch: { ref in showBranches = false; comparisonTarget = GitComparisonTarget(id: ref) }, deleteRemoteBranch: { name in showBranches = false; remoteBranchToDelete = GitComparisonTarget(id: name) }) {
                Group {
                    Button(Copy.t("撤销提交…", "Revert commit…", language: model.language)) { showBranches = false; gitPromptKind = .revert }
                    Button(Copy.t("拣选提交…", "Cherry-pick commit…", language: model.language)) { showBranches = false; gitPromptKind = .cherryPick }
                    Menu(Copy.t("重置当前分支…", "Reset current branch…", language: model.language)) {
                        Button(Copy.t("软重置", "Soft reset", language: model.language)) { showBranches = false; gitPromptKind = .resetSoft }
                        Button(Copy.t("混合重置", "Mixed reset", language: model.language)) { showBranches = false; gitPromptKind = .resetMixed }
                        Button(Copy.t("硬重置（危险）", "Hard reset (destructive)", language: model.language)) { showBranches = false; gitPromptKind = .resetHard }
                    }
                    Divider()
                    Button(Copy.t("继续变基", "Continue rebase", language: model.language)) { showBranches = false; model.gitAdvanced(.rebaseContinue) }
                    Button(Copy.t("中止变基", "Abort rebase", language: model.language)) { showBranches = false; model.gitAdvanced(.rebaseAbort) }
                    Button(Copy.t("中止合并", "Abort merge", language: model.language)) { showBranches = false; model.gitAdvanced(.mergeAbort) }
                    Divider()
                    Button(Copy.t("远程仓库…", "Remotes…", language: model.language)) { showBranches = false; showRemoteSheet = true }
                    Button(Copy.t("工作树…", "Worktrees…", language: model.language)) { showBranches = false; showWorktrees = true }
                    Button(Copy.t("子模块…", "Submodules…", language: model.language)) { showBranches = false; showSubmodules = true }
                }
                    }
                }

    }

    private var runConfigurationMenu: some View {
            Menu {
                if let configurations = model.selectedProject?.runConfigurations {
                    ForEach(configurations) { config in Button { model.selectRunConfiguration(config) } label: { if config.id == model.selectedRunConfigurationID { Label(config.name, systemImage: "checkmark") } else { Text(config.name) } } }
                }
                Divider()
                Button(Copy.t("编辑运行配置…", "Edit configurations…", language: model.language)) { model.showRunSettings = true }
            } label: { Text(model.selectedRunConfiguration?.name ?? Copy.t("运行配置", "Run configuration", language: model.language)).lineLimit(1).frame(maxWidth: 130) }.menuStyle(.borderlessButton).fixedSize().disabled(model.selectedProjectID == nil)
    }

    private var projectTabs: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(model.projects) { project in
                            ProjectTab(project: project, active: model.selectedProjectID == project.id, language: model.language, onSelect: { model.selectProject(project) }, onClose: { model.closeProject(project.id) }, onReveal: {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
                            })
                                .id(project.id)
                        }
                    }
                }
                .onAppear { if let id = model.selectedProjectID { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: model.selectedProjectID) { id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Rectangle().fill(WorkbenchChrome.quietSeparator).frame(width: 1).padding(.vertical, 7)
            Button { model.addProject() } label: { Image(systemName: "plus").frame(width: 34, height: 30) }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(Copy.t("添加项目", "Add project", language: model.language)).help(Copy.t("添加项目", "Add project", language: model.language))
                .contextMenu {
                    Button(Copy.t("打开本地项目…", "Open local project…", language: model.language)) { model.addProject() }
                    Button(Copy.t("克隆仓库…", "Clone repository…", language: model.language)) { model.showCloneSheet = true }
                }
        }
        .frame(height: 34)
        .background(WorkbenchChrome.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(WorkbenchChrome.quietSeparator).frame(height: 1) }
    }

    private var toolRail: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Button { if topPanel == .files { sidebarVisible.toggle() } else { topPanel = .files; sidebarVisible = true } } label: { Image(systemName: "folder") }.buttonStyle(RailButtonStyle(active: topPanel == .files && sidebarVisible)).accessibilityLabel(Copy.t("项目文件 ⌘1", "Project ⌘1", language: model.language)).help(Copy.t("项目文件 ⌘1", "Project ⌘1", language: model.language))
                Button { if topPanel == .git { sidebarVisible.toggle() } else { topPanel = .git; sidebarVisible = true } } label: { Image(systemName: "arrow.triangle.branch") }.buttonStyle(RailButtonStyle(active: topPanel == .git && sidebarVisible)).accessibilityLabel(Copy.t("提交 ⌘0", "Commit ⌘0", language: model.language)).help(Copy.t("提交 ⌘0", "Commit ⌘0", language: model.language)).keyboardShortcut("0", modifiers: .command)
            }
            Rectangle().fill(WorkbenchChrome.quietSeparator).frame(width: 20, height: 1).padding(.vertical, 6)
            VStack(spacing: 0) {
                ForEach(BottomTool.allCases) { tool in
                    if tool == .console {
                        Button { selectBottomTool(tool) } label: { Image(systemName: tool.icon) }
                            .buttonStyle(RailButtonStyle(active: bottomTool == tool && bottomToolExpanded))
                            .accessibilityLabel(Copy.t("终端 ⌘2", "Terminal ⌘2", language: model.language)).help(Copy.t("终端 ⌘2", "Terminal ⌘2", language: model.language))
                            .disabled(model.selectedProjectID == nil)
                    } else {
                        Button { selectBottomTool(tool) } label: { Image(systemName: tool.icon) }.buttonStyle(RailButtonStyle(active: bottomTool == tool && bottomToolExpanded)).accessibilityLabel(bottomToolName(tool)).help(bottomToolName(tool)).disabled(model.selectedProjectID == nil)
                    }
                }
            }
            Spacer(minLength: 0)
            Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .background(settingsHovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .onHover { settingsHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: settingsHovering)
                .accessibilityLabel(Copy.t("设置", "Settings", language: model.language)).help(Copy.t("设置", "Settings", language: model.language))
        }
        .padding(.vertical, 8)
        .frame(width: toolRailWidth)
        .background(WorkbenchChrome.bar)
        .overlay(alignment: .trailing) { Rectangle().fill(WorkbenchChrome.quietSeparator).frame(width: 1) }
    }

    private func preferredToolHeight(_ tool: BottomTool) -> CGFloat {
        if let height = toolHeights[tool] { return height }
        let saved = UserDefaults.standard.double(forKey: "layout.split.main.bottom." + tool.rawValue)
        return saved.isFinite && saved > 0 ? max(160, saved) : (tool == .gitTree ? 280 : 180)
    }

    private func handleBottomToolFocus(_ request: BottomToolFocusRequest?) {
        guard let request else { return }
        if request.tool == .gitTree { showGitOperations = false }
        revealBottomTool(request.tool)
    }

    private func resetLayoutState() {
        sidebarWidth = 285
        toolRailWidth = 44
        bottomToolHeight = bottomTool == .gitTree ? 280 : 180
        toolHeights.removeAll()
        topPanel = .files
        sidebarVisible = true
        bottomTool = .console
        bottomToolExpanded = false
    }

    private func selectBottomTool(_ tool: BottomTool) {
        if bottomTool == tool {
            withAnimation(.easeInOut(duration: 0.18)) { bottomToolExpanded.toggle() }
            return
        }
        revealBottomTool(tool)
    }

    private func revealBottomTool(_ tool: BottomTool) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if bottomTool != tool {
                toolHeights[bottomTool] = bottomToolHeight
                bottomToolHeight = preferredToolHeight(tool)
                bottomTool = tool
            }
            bottomToolExpanded = true
        }
    }

    private func bottomToolName(_ tool: BottomTool) -> String {
        switch tool { case .processes: return Copy.t("运行进程", "Processes", language: model.language); case .services: return Copy.t("服务与 Docker", "Services & Docker", language: model.language); case .console: return Copy.t("终端", "Terminal", language: model.language); case .gitTree: return Copy.t("Git 树", "Git Tree", language: model.language) }
    }

    private var upperWorkspaceMinimumHeight: CGFloat {
        guard sidebarVisible && topPanel == .git else { return 180 }
        return model.gitOperationState != nil || model.gitChanges.contains(where: \.isConflicted) ? 430 : 360
    }

    @ViewBuilder private var upperWorkspace: some View {
        if sidebarVisible {
            WorkbenchSplit("main.sidebar", initial: 285, minimum: topPanel == .git ? 240 : 180, otherMinimum: 360,
                           dimension: $sidebarWidth) {
                topSidebar
            } second: {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var topSidebar: some View {
        if topPanel == .files {
            VStack(spacing: 0) {
                HStack {
                    Text(Copy.t("项目导航", "Project Navigator", language: model.language)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button { if let project = model.selectedProject { Task { await model.refreshProject(project) } } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(Copy.t("刷新文件", "Refresh files", language: model.language)).help(Copy.t("刷新文件", "Refresh files", language: model.language))
                }.padding(.horizontal, 12).frame(height: WorkbenchChrome.rowHeight)
                Rectangle().fill(WorkbenchChrome.quietSeparator).frame(height: 1)
                if let project = model.selectedProject {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(project.name, systemImage: "folder")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(project.path)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8).help(project.path)
                    FileTree(items: model.fileItems, model: model, search: fileSearch, expandedItems: Binding(
                        get: { expandedFileItems[project.id, default: []] },
                        set: { expandedFileItems[project.id] = $0 }))
                } else {
                    Text(Copy.t("打开项目以浏览文件", "Open a project to browse files", language: model.language))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Rectangle().fill(WorkbenchChrome.quietSeparator).frame(height: 1)
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                    TextField(Copy.t("筛选文件", "Filter files", language: model.language), text: $fileSearch)
                        .textFieldStyle(.plain)
                        .focused($fileSearchFocused)
                        .onExitCommand { fileSearchFocused = false }
                    if !fileSearch.isEmpty { Button { fileSearch = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }.font(.system(size: 11)).padding(.horizontal, 10).frame(height: WorkbenchChrome.rowHeight)
            }.background(WorkbenchChrome.panel)
        } else {
            GitChangesPanel(model: model).background(WorkbenchChrome.panel)
        }
    }

    @ViewBuilder private var bottomToolWindow: some View {
        if bottomToolExpanded {
            if bottomTool == .console {
                TerminalTool(model: model, terminals: model.terminals, onHide: { withAnimation(.easeInOut(duration: 0.18)) { bottomToolExpanded = false } })
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        if bottomTool == .gitTree {
                            Picker("Git", selection: $showGitOperations) {
                                Text(Copy.t("提交日志", "Commits", language: model.language)).tag(false)
                                Text(Copy.t("操作记录", "Operations", language: model.language)).tag(true)
                            }.labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(width: 190)
                        } else {
                            Text(bottomToolName(bottomTool)).font(.system(size: 11, weight: .semibold))
                        }
                        Spacer()
                        Menu {
                            switch bottomTool {
                            case .services:
                                Button(Copy.t("刷新服务与 Docker", "Refresh services & Docker", language: model.language)) { model.refreshEnvironment(); model.refreshDocker() }
                            case .gitTree:
                                Button(Copy.t("刷新 Git 历史", "Refresh Git history", language: model.language)) { gitHistoryRevision = UUID() }
                                if showGitOperations { Button(Copy.t("清空记录", "Clear History", language: model.language)) { model.clearGitConsole() } }
                            case .processes:
                                Button(Copy.t("运行配置…", "Run configurations…", language: model.language)) { model.showRunSettings = true }
                            case .console: EmptyView()
                            }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).foregroundStyle(.secondary).fixedSize()
                        Button { withAnimation(.easeInOut(duration: 0.18)) { bottomToolExpanded = false } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel(Copy.t("隐藏工具窗口", "Hide tool window", language: model.language)).help(Copy.t("隐藏工具窗口", "Hide tool window", language: model.language))
                    }.padding(.horizontal, 12).frame(height: WorkbenchChrome.rowHeight).background(WorkbenchChrome.bar)
                    Rectangle().fill(WorkbenchChrome.quietSeparator).frame(height: 1)
                    Group {
                        switch bottomTool {
                        case .processes: ProcessTool(model: model)
                        case .services: ServicesTool(model: model)
                        case .gitTree:
                            if showGitOperations { ConsoleTool(model: model) }
                            else { GitHistoryPanel(model: model, externalRefresh: gitHistoryRevision) }
                        case .console: EmptyView()
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(WorkbenchChrome.editor)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        } else { Color.clear.frame(height: 0).transition(.opacity) }
    }

    private var content: some View {
        VStack(spacing: 0) {
            editorTabs
            Divider().opacity(0.3)
            if model.selectedProjectID == nil { EmptyWorkspaceView(model: model) } else if let document = model.conflictDocument { GitConflictEditor(model: model, document: document).id(document.id) } else if model.diffContent.isEmpty { CodePreview(file: model.selectedFile, content: model.fileContent, search: editorSearch, appLanguage: model.language, fontSize: model.editorFontSize, document: model.filePreviewDocument, navigation: editorNavigation, onPrepared: { previewSnapshot = $0 }) } else { GitDiffWorkspace(model: model) }
        }.frame(maxWidth: .infinity).background(Color(nsColor: .textBackgroundColor))
    }

    private var editorTabs: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: model.selectedFile.isEmpty ? "doc" : fileIcon(for: model.selectedFile))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(model.selectedFile.isEmpty ? Copy.t("未打开文件", "No file open", language: model.language) : displayFileName)
                    .font(.system(size: 11)).foregroundStyle(model.selectedFile.isEmpty ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(model.selectedFile)
                if !model.selectedFile.isEmpty {
                    Button { model.closePreview() } label: {
                        Image(systemName: "xmark").font(.system(size: 9)).frame(width: 18, height: 24)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel(Copy.t("关闭文件", "Close file", language: model.language))
                        .help(Copy.t("关闭文件", "Close file", language: model.language))
                }
            }.padding(.horizontal, 12).frame(height: WorkbenchChrome.rowHeight)
                .background(WorkbenchChrome.editor)
                .contextMenu {
                    if !model.selectedFile.isEmpty {
                        Button(Copy.t("复制完整路径", "Copy Full Path", language: model.language)) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.selectedFile, forType: .string)
                        }
                        Button(Copy.t("在 Finder 中显示", "Reveal in Finder", language: model.language)) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.selectedFile)])
                        }
                        Divider()
                    }
                    Button(Copy.t("关闭文件", "Close File", language: model.language)) { model.closePreview() }
                        .disabled(model.selectedFile.isEmpty)
                }
            Spacer(minLength: 8)
            if showEditorSearch && canSearchPreview {
                HStack(spacing: 5) {
                    TextField(Copy.t("搜索当前文件", "Find in file", language: model.language), text: $editorSearch)
                        .textFieldStyle(.plain).font(.system(size: 11))
                        .frame(minWidth: 70, idealWidth: 140, maxWidth: 170)
                        .focused($editorSearchFocused)
                        .onAppear { DispatchQueue.main.async { editorSearchFocused = true } }
                        .onExitCommand { closeEditorSearch() }
                        .onSubmit { navigateSearch(.next) }
                    if !editorSearch.isEmpty {
                        FileSearchCount(content: model.filePreviewDocument?.kind == .empty ? "" : searchableDocument?.text, query: editorSearch, language: model.language)
                        Button { navigateSearch(.previous) } label: { Image(systemName: "chevron.up").font(.system(size: 10)).frame(width: 18, height: 24) }
                            .buttonStyle(.plain).accessibilityLabel(Copy.t("上一个匹配", "Previous match", language: model.language))
                            .help(Copy.t("上一个匹配 ⇧⌘G", "Previous match ⇧⌘G", language: model.language))
                            .keyboardShortcut("g", modifiers: [.command, .shift])
                            .disabled(searchableDocument == nil)
                        Button { navigateSearch(.next) } label: { Image(systemName: "chevron.down").font(.system(size: 10)).frame(width: 18, height: 24) }
                            .buttonStyle(.plain).accessibilityLabel(Copy.t("下一个匹配", "Next match", language: model.language))
                            .help(Copy.t("下一个匹配 ⌘G", "Next match ⌘G", language: model.language))
                            .keyboardShortcut("g", modifiers: .command)
                            .disabled(searchableDocument == nil)
                    }
                    Button(action: closeEditorSearch) { Image(systemName: "xmark").font(.system(size: 9)).frame(width: 18, height: 24) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel(Copy.t("关闭搜索", "Close search", language: model.language))
                }.padding(.horizontal, 8)
            }
                Button {
                    guard canSearchPreview else { return }
                    if showEditorSearch { editorSearchFocused = true } else { showEditorSearch = true }
                } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 12)
                    .accessibilityLabel(Copy.t("搜索当前文件", "Find in file", language: model.language))
                    .help(Copy.t("搜索当前文件 ⌘F", "Find in file ⌘F", language: model.language))
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(!canSearchPreview)
        }
        .frame(height: WorkbenchChrome.rowHeight)
        .background(WorkbenchChrome.bar)
        .overlay(alignment: .top) { Rectangle().fill(WorkbenchChrome.quietSeparator).frame(height: 1) }
    }

    private func navigateSearch(_ direction: FileSearchNavigation.Direction) {
        guard searchableDocument != nil, !editorSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        editorNavigation = FileSearchNavigation(file: model.selectedFile, direction: direction)
    }

    private func closeEditorSearch() {
        editorNavigation = nil
        showEditorSearch = false
        editorSearch = ""
        editorSearchFocused = false
    }

    private var displayFileName: String {
        guard let project = model.selectedProject else { return URL(fileURLWithPath: model.selectedFile).lastPathComponent }
        let root = URL(fileURLWithPath: project.path).path
        let path = URL(fileURLWithPath: model.selectedFile).path
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func fileIcon(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "swift": return "swift"
        case "js", "ts", "tsx", "jsx": return "curlybraces"
        case "json", "yaml", "yml": return "curlybraces.square"
        case "md": return "doc.richtext"
        default: return "doc.text"
        }
    }

    private var statusBar: some View {
        HStack { Text(model.selectedFile.isEmpty ? "" : "UTF-8"); Text(fileLanguageLabel); if !model.gitLastResult.isEmpty { Text(model.gitLastResult).lineLimit(1).truncationMode(.tail).frame(maxWidth: 360, alignment: .leading).help(model.selectedGitConsoleEntry?.output ?? "") }; Spacer(); if !model.selectedFile.isEmpty { Text(model.diffContent.isEmpty ? (searchableDocument != nil || model.filePreviewDocument?.kind == .empty ? Copy.t("\(fileLineCount) 行", "\(fileLineCount) lines", language: model.language) : "—") : Copy.t("差异", "Diff", language: model.language)) }; Text(Copy.t("⌘K  命令面板", "⌘K  Command palette", language: model.language)); Text(Copy.t("⌘R  运行", "⌘R  Run", language: model.language)) }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6).background(Color(nsColor: .controlBackgroundColor))
    }

    private var fileLanguageLabel: String {
        guard !model.selectedFile.isEmpty else { return "" }
        switch URL(fileURLWithPath: model.selectedFile).pathExtension.lowercased() {
        case "swift": return "Swift"
        case "js": return "JavaScript"
        case "ts", "tsx": return "TypeScript"
        case "jsx": return "JSX"
        case "py": return "Python"
        case "go": return "Go"
        case "rs": return "Rust"
        case "java": return "Java"
        case "php": return "PHP"
        case "json": return "JSON"
        case "yaml", "yml": return "YAML"
        case "md": return "Markdown"
        case "sh", "zsh": return "Shell"
        case "sql": return "SQL"
        default: return URL(fileURLWithPath: model.selectedFile).pathExtension.uppercased()
        }
    }


}

struct ProjectTab: View {
    let project: Project
    let active: Bool
    let language: AppLanguage
    let onSelect: () -> Void
    let onClose: () -> Void
    let onReveal: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Image(systemName: project.isRunning ? "circle.fill" : "folder").font(.system(size: 11)).foregroundStyle(project.isRunning ? .green : .secondary)
                    Text(project.name).font(.system(size: 11, weight: active ? .medium : .regular)).lineLimit(1).truncationMode(.middle)
                }.padding(.horizontal, 10).frame(minWidth: 112, idealWidth: 156, maxWidth: 210, alignment: .leading).frame(height: 32)
            }.buttonStyle(.plain)
                .accessibilityAddTraits(active ? AccessibilityTraits.isSelected : [])
                .accessibilityLabel(project.name)
                .accessibilityValue(active ? Copy.t("当前项目", "Selected project", language: language) : Copy.t("项目标签", "Project tab", language: language))
                .accessibilityHint(Copy.t("切换到此项目", "Switch to this project", language: language))
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 9)).frame(width: 18, height: 24) }
                .buttonStyle(.plain).foregroundStyle(.secondary).opacity(hovering || active ? 1 : 0)
                .help(Copy.t("关闭项目", "Close project", language: language))
                .accessibilityLabel(Copy.t("关闭项目 ", "Close project ", language: language) + project.name)
            Divider().padding(.vertical, 8)
        }.fixedSize(horizontal: true, vertical: false)
        .background(active ? WorkbenchChrome.selectedSurface : (hovering ? Color.primary.opacity(0.035) : .clear))
        .overlay(alignment: .bottom) { if active { Rectangle().fill(Color.accentColor.opacity(0.65)).frame(height: 2) } }
        .overlay(alignment: .top) { Rectangle().fill(WorkbenchChrome.quietSeparator).frame(height: 1) }
        .contentShape(Rectangle())
        .help(project.path)
        .contextMenu {
            Button(Copy.t("在 Finder 中显示", "Reveal in Finder", language: language), action: onReveal)
            Divider()
            Button(Copy.t("关闭项目", "Close Project", language: language), action: onClose)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: active)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct RailButtonStyle: ButtonStyle {
    let active: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .frame(width: 28, height: 28)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(active ? Color.accentColor : .secondary)
            .background(
                active ? WorkbenchChrome.selectedSurface : hovering ? Color.primary.opacity(0.06) : .clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(WorkbenchChrome.selectedBorder, lineWidth: 0.5)
                }
            }
            .overlay(alignment: .leading) {
                if active {
                    Capsule().fill(Color.accentColor).frame(width: 2, height: 16)
                        .offset(x: -5)
                }
            }
            .opacity(configuration.isPressed ? 0.65 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}


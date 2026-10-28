import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Darwin

@main
struct CodeFlightApp: App {
    @StateObject private var model = WorkbenchModel(restoringSession: ProcessInfo.processInfo.environment["CODEFLIGHT_SMOKE_TEST"] != "1")
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("CodeFlight") {
            WorkbenchView(model: model)
                .onAppear { appDelegate.model = model }
                .background(WorkbenchWindowMinimumSize(minimum: NSSize(width: 1120, height: 720)))
                .frame(minWidth: 1120, minHeight: 720)
        }
        .defaultSize(width: 1320, height: 840)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands { WorkbenchCommands(model: model) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: WorkbenchModel?
    private var isTerminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.canLeaveConflict() != false else { return .terminateCancel }
        if isTerminating { return .terminateLater }
        guard model?.confirmSheetQuit?() != false else { return .terminateCancel }
        model?.prepareForTermination()
        guard CommandRunner.hasRunningCommands || model?.terminals.hasSessions == true else { return .terminateNow }
        isTerminating = true
        CommandRunner.stopAll()
        model?.terminals.closeAll()
        // Keep the run loop alive through process-group escalation so a child
        // ignoring TERM cannot outlive the application after Quit.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false

    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let model, !model.isLoading, !model.isGitBusy, let project = model.selectedProject else { return }
        Task { await model.refreshProject(project) }
    }

    func applicationWillTerminate(_ notification: Notification) { CommandRunner.stopAll(); model?.terminals.closeAll() }


}

@MainActor
final class WorkbenchModel: ObservableObject {
    let terminals = WorkbenchTerminals()
    var projectEditorLocations: [UUID: ProjectEditorLocation] = [:]
    @Published var language: AppLanguage = .chinese
    @Published var theme: AppTheme = .system
    @Published var background: BackgroundStyle = .plain
    /// Editor text size is a bounded preference so large previews keep the
    /// same sparse layout and memory policy.
    @Published var editorFontSize: Double = 13
    @Published var selectedFile = ""
    @Published var fileNavigatorFocusRequest: UUID?
    @Published var gitNavigatorFocusRequest: UUID?
    @Published var fileSearchFocusRequest: UUID?
    @Published var terminalFocusRequest: UUID?
    /// Requests a visible bottom tool window without coupling the command menu
    /// to WorkbenchView's local SwiftUI state.
    @Published var bottomToolFocusRequest: BottomToolFocusRequest?
    @Published var bottomToolToggleRequest: UUID?

    func focusTerminal(newSession: Bool = false) {
        guard !isTerminating, let project = selectedProject else { return }
        if newSession || terminals.sessions[project.id, default: []].isEmpty {
            terminals.add(project: project)
        }
        terminalFocusRequest = UUID()
    }

    func adjustEditorFontSize(by delta: Double) {
        editorFontSize = min(20, max(11, editorFontSize + delta))
        persistPreferences()
    }

    func resetEditorFontSize() {
        editorFontSize = 13
        persistPreferences()
    }

    func focusBottomTool(_ tool: BottomTool) {
        guard selectedProjectID != nil else { return }
        bottomToolFocusRequest = BottomToolFocusRequest(tool: tool)
    }

    func toggleBottomTool() {
        guard selectedProjectID != nil else { return }
        bottomToolToggleRequest = UUID()
    }
    @Published var projects: [Project]
    @Published var selectedProjectID: UUID?
    @Published var selectedSection: SidebarSection = .overview
    @Published var showRunSettings = false
    var confirmSheetQuit: (() -> Bool)?
    var quitRequestPending = false

    func requestApplicationQuit() {
        guard !quitRequestPending else { return }
        let hadEditingSheet = confirmSheetQuit != nil
        guard confirmSheetQuit?() != false else { return }
        confirmSheetQuit = nil
        if hadEditingSheet {
            quitRequestPending = true
            Task { @MainActor in
                // Let SwiftUI dismiss its sheet before AppKit handles Quit.
                try? await Task.sleep(nanoseconds: 250_000_000)
                NSApp.terminate(nil)
                quitRequestPending = false
            }
        } else { NSApp.terminate(nil) }
    }
    @Published var selectedRunConfigurationID: UUID?
    private var activeRunConfigurations: [String: UUID] = [:]
    @Published var showCloneSheet = false
    @Published var showCommandSheet = false
    @Published var showCommandPalette = false
    var pendingPaletteAction: PendingPaletteAction?
    @Published var showSettings = false
    @Published var errorMessage: String? { didSet { errorConsoleReference = nil } }
    var errorConsoleReference: GitConsoleReference?
    @Published var gitConsoleEntries: [UUID: [GitConsoleEntry]] = [:]
    @Published var selectedGitConsoleEntryIDs: [UUID: UUID] = [:]
    private var quickCommandDrafts: [UUID: String] = [:]
    private var restoringQuickCommand = false
    @Published var commandText = "" {
        didSet {
            if !restoringQuickCommand, let id = selectedProjectID { quickCommandDrafts[id] = commandText }
        }
    }
    @Published var commandOutput = "准备运行项目命令。"
    @Published var commitMessage = ""
    @Published var gitLastResult = ""
    private var commitDrafts: [String: String] = [:]
    @Published var fileItems: [FileItem] = []
    @Published var fileTreeRevision = UUID()
    @Published var fileContent = ""
    @Published var filePreviewDocument: FilePreviewDocument?
    @Published var diffContent = ""
    @Published var diffIsStaged = false
    @Published var historyCommit: String?
    @Published var gitFileHistoryPath: String?
    @Published var gitFileHistoryRequest = UUID()
    @Published var gitBlameTarget: GitBlameTarget?
    @Published var conflictDocument: GitConflictDocument?
    @Published var gitOperationState: GitOperationState?
    @Published var gitSyncKind: GitSyncKind?
    @Published private(set) var gitBusyProjects = Set<UUID>()
    var isGitBusy: Bool { selectedProjectID.map { gitBusyProjects.contains($0) } ?? false }
    @Published var gitStatusError: String?
    @Published var gitBranch = ""
    @Published var gitTracking: GitBranchTracking?
    @Published var isGitRepository = false
    @Published var gitChanges: [GitChange] = []
    @Published var gitBranches: [String] = []
    @Published var gitRemoteBranches: [String] = []
    @Published var gitCommits: [GitCommit] = []
    @Published var gitTags: [String] = []
    @Published var gitStashes: [GitStash] = []
    @Published var gitRemotes: [GitRemote] = []
    @Published var dockerContainers: [DockerContainer] = []
    @Published var isDockerLoading = false
    @Published var dockerError: String?
    @Published var dockerBusyContainer: String?
    @Published var dockerActionErrors: [String: String] = [:]
    @Published var dockerLastActions: [String: DockerAction] = [:]
    @Published var dockerNotice: String?
    @Published var isEnvironmentLoading = false
    @Published var environmentError: String?
    var dockerClient = DockerClient.live
    @Published var environments: [EnvironmentItem] = []
    @Published var isLoading = false
    @Published var runningTasks: [UUID: [RunningTask]] = [:]
    var runOutputStreams: [UUID: RunOutputStream] = [:]
    @Published var runRequestID = UUID()
    @Published var selectedTaskIDs: [UUID: UUID] = [:]
    @Published var restartingTaskIDs: Set<UUID> = []
    var isTerminating = false
    private var previewTask: Task<Void, Never>?
    var previewWasClosed = false
    private var refreshID = UUID()
    private var environmentLoaded = false
    private var dockerLoaded = false
    private var environmentTask: Task<Void, Never>?
    private var dockerTask: Task<Void, Never>?
    private var autoStartedProjects = Set<UUID>()

    init(restoringSession: Bool = true) {
        if !restoringSession { projects = []; selectedProjectID = nil; return }
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "appLanguage"), let value = AppLanguage(rawValue: raw) { language = value }
        if let raw = defaults.string(forKey: "appTheme"), let value = AppTheme(rawValue: raw) { theme = value }
        let savedFontSize = defaults.double(forKey: "editorFontSize")
        if savedFontSize > 0 { editorFontSize = min(20, max(11, savedFontSize)) }
        let backgroundStyle = defaults.string(forKey: "backgroundStyle") ?? "plain"
        if backgroundStyle == "aurora" { background = .aurora }
        else if backgroundStyle == "image", let path = defaults.string(forKey: "backgroundImagePath"), !path.isEmpty { background = .image(URL(fileURLWithPath: path)) }
        let paths = UserDefaults.standard.stringArray(forKey: "recentProjectPaths") ?? []
        projects = paths.compactMap { path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return Project(name: URL(fileURLWithPath: path).lastPathComponent, path: path)
        }
        for index in projects.indices {
            projects[index].runConfigurations = loadRunConfigurations(for: projects[index].path)
            projects[index].runConfigurationsLoaded = runConfigFileExists(for: projects[index].path)
        }
        let selectedPath = defaults.string(forKey: "selectedProjectPath")
        selectedProjectID = projects.first(where: { $0.path == selectedPath })?.id ?? projects.first?.id
        if let project = selectedProject { restoreRunSelection(for: project); Task { await refreshProject(project) } }
    }

    var selectedProject: Project? { projects.first(where: { $0.id == selectedProjectID }) }

    var selectedRunConfiguration: RunConfiguration? { selectedProject?.runConfigurations.first { $0.id == selectedRunConfigurationID } }

    func selectRunConfiguration(_ configuration: RunConfiguration) {
        guard let project = selectedProject else { return }
        selectedRunConfigurationID = configuration.id
        activeRunConfigurations[project.path] = configuration.id
        UserDefaults.standard.set(configuration.id.uuidString, forKey: "run.selected." + project.path)
        commandText = configuration.command
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index].command = configuration.command }
    }

    private func restoreRunSelection(for project: Project) {
        guard let current = projects.first(where: { $0.id == project.id }), selectedProjectID == current.id else { return }
        let saved = activeRunConfigurations[current.path] ?? UserDefaults.standard.string(forKey: "run.selected." + current.path).flatMap(UUID.init(uuidString:))
        let configuration = current.runConfigurations.first(where: { $0.id == saved }) ?? current.runConfigurations.first
        selectedRunConfigurationID = configuration?.id
        restoringQuickCommand = true
        commandText = quickCommandDrafts[current.id] ?? configuration?.command ?? current.command
        restoringQuickCommand = false
    }

    @discardableResult
    func replaceRunConfigurations(_ configurations: [RunConfiguration], selectedID: UUID?, projectID: UUID) -> Bool {
        guard selectedProjectID == projectID, let index = projects.firstIndex(where: { $0.id == projectID }) else { return false }
        let environments = Dictionary(configurations.map { ($0.id, EnvironmentParser.serialize($0.environment)) }, uniquingKeysWith: { first, _ in first })
        if let error = RunConfigurationValidation.error(configurations, environments: environments, projectPath: projects[index].path, language: language) { errorMessage = error; return false }
        do {
            let url = runConfigURL(for: projects[index].path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(configurations).write(to: url, options: .atomic)
        } catch { errorMessage = error.localizedDescription; return false }
        projects[index].runConfigurations = configurations
        projects[index].runConfigurationsLoaded = true
        selectedRunConfigurationID = selectedID
        if let selected = configurations.first(where: { $0.id == selectedID }) { selectRunConfiguration(selected) }
        else { activeRunConfigurations.removeValue(forKey: projects[index].path); UserDefaults.standard.removeObject(forKey: "run.selected." + projects[index].path) }
        return true
    }

    func runCommand(command configuredCommand: String? = nil, workingDirectory: String? = nil, environment: [String: String] = [:], projectID targetProjectID: UUID? = nil,
                    configurationID: UUID? = nil, name: String? = nil) {
        guard !isTerminating else { return }
        if let selectedProjectID = targetProjectID ?? selectedProjectID, let index = projects.firstIndex(where: { $0.id == selectedProjectID }) {
            let project = projects[index]
            let savedConfigurationID = self.selectedProjectID == project.id ? selectedRunConfigurationID :
                (activeRunConfigurations[project.path] ?? UserDefaults.standard.string(forKey: "run.selected." + project.path).flatMap(UUID.init(uuidString:)))
            let configuration = configuredCommand == nil ? project.runConfigurations.first(where: { $0.id == savedConfigurationID }) ?? project.runConfigurations.first : nil
            let quickCommand = self.selectedProjectID == project.id ? commandText : quickCommandDrafts[project.id] ?? project.command
            let command = configuredCommand ?? configuration?.command ?? quickCommand
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                showRunSettings = true; return
            }
            if let configuration, let existing = runningTasks[selectedProjectID]?.last(where: { $0.configurationID == configuration.id && ($0.isRunning || restartingTaskIDs.contains($0.id)) }) {
                selectedTaskIDs[selectedProjectID] = existing.id; runRequestID = UUID(); return
            }
            let cwd = RunConfigurationValidation.directory(workingDirectory ?? configuration?.workingDirectory ?? "", projectPath: project.path)
            let taskEnvironment = configuration?.environment.merging(environment) { _, override in override } ?? environment
            if let error = RunConfigurationValidation.launchError(command: command, directory: cwd, environment: taskEnvironment, language: language) {
                errorMessage = error
                return
            }
            if self.selectedProjectID == selectedProjectID { commandText = command }
            projects[index].command = command
            projects[index].isRunning = true
            let taskID = UUID()
            let initialOutput = "$ \(command)\n"
            var tasks = runningTasks[project.id, default: []]
            tasks.append(RunningTask(id: taskID, command: command, output: initialOutput, isRunning: true, exitCode: nil, configurationID: configuration?.id ?? configurationID, name: configuration?.name ?? name, workingDirectory: cwd, environment: taskEnvironment))
            while tasks.filter({ !$0.isRunning }).count > 20, let oldest = tasks.firstIndex(where: { !$0.isRunning }) { tasks.remove(at: oldest) }
            runningTasks[project.id] = tasks
            selectedTaskIDs[project.id] = taskID
            if self.selectedProjectID == project.id { commandOutput = initialOutput }
            projects[index].output = initialOutput
            runRequestID = UUID()
            Task { [weak self] in
                // Stop/close may happen before this scheduled task starts.
                guard self?.isTerminating == false,
                      self?.projects.contains(where: { $0.id == project.id }) == true,
                      self?.runningTasks[project.id]?.contains(where: { $0.id == taskID && $0.isRunning }) == true else { return }
                let stream = RunOutputStream { [weak self] snapshot in
                    guard let self, var tasks = self.runningTasks[project.id], let taskIndex = tasks.firstIndex(where: { $0.id == taskID && $0.isRunning }) else { return }
                    tasks[taskIndex].output = snapshot.text
                    tasks[taskIndex].logWasTruncated = snapshot.truncated
                    if self.selectedProjectID == project.id && self.selectedTaskIDs[project.id] == taskID { self.commandOutput = snapshot.text }
                    if let index = self.projects.firstIndex(where: { $0.id == project.id }) { self.projects[index].output = snapshot.text }
                    self.runningTasks[project.id] = tasks
                }
                self?.runOutputStreams[taskID] = stream
                let result = await CommandRunner.run(command: command, cwd: cwd, projectID: project.id, taskID: taskID, environment: taskEnvironment, interactiveShell: true) { chunk in
                    stream.append(chunk)
                }
                let snapshot = stream.finish(fallback: result.output)
                await MainActor.run {
                    guard let self else { return }
                    let wasStopped = self.runningTasks[project.id]?.first(where: { $0.id == taskID }).map { $0.isStopping || $0.wasStopped } == true
                    let prefix = wasStopped ? Copy.t("命令已停止\n", "Command stopped\n", language: self.language) : (result.status == 0 ? "" : Copy.t("命令失败（退出码 \(result.status)）\n", "Command failed (exit code \(result.status))\n", language: self.language))
                    self.runOutputStreams.removeValue(forKey: taskID)
                    let output = String((prefix + snapshot.text).suffix(12_000))
                    if self.selectedProjectID == project.id && self.selectedTaskIDs[project.id] == taskID { self.commandOutput = output }
                    if var tasks = self.runningTasks[project.id], let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) {
                        tasks[taskIndex].output = output
                        tasks[taskIndex].logWasTruncated = snapshot.truncated
                        tasks[taskIndex].isRunning = false
                        tasks[taskIndex].isStopping = false
                        tasks[taskIndex].endedAt = Date()
                        tasks[taskIndex].exitCode = wasStopped ? -15 : result.status
                        while tasks.filter({ !$0.isRunning }).count > 20, let oldest = tasks.firstIndex(where: { !$0.isRunning }) { tasks.remove(at: oldest) }
                        self.runningTasks[project.id] = tasks
                    }
                    if let index = self.projects.firstIndex(where: { $0.id == project.id }) {
                        self.projects[index].isRunning = self.runningTasks[project.id]?.contains(where: \.isRunning) == true
                        self.projects[index].output = output
                    }
                }
            }
        }
    }

    func stopCommand() {
        guard let id = selectedProjectID else { return }
        for task in runningTasks[id, default: []] where task.isRunning || restartingTaskIDs.contains(task.id) { stopTask(task.id, projectID: id) }
    }

    func stopTask(_ taskID: UUID, projectID targetProjectID: UUID? = nil) {
        restartingTaskIDs.remove(taskID)
        guard let projectID = targetProjectID ?? selectedProjectID,
              var tasks = runningTasks[projectID], let index = tasks.firstIndex(where: { $0.id == taskID }),
              tasks[index].isRunning, !tasks[index].isStopping else { return }
        tasks[index].isStopping = true
        if !CommandRunner.isRunning(taskID: taskID) {
            // A stop before the scheduled launch must cancel that launch.
            tasks[index].isRunning = false; tasks[index].isStopping = false
            tasks[index].exitCode = -15; tasks[index].endedAt = Date()
        }
        runningTasks[projectID] = tasks
        CommandRunner.stop(taskID: taskID)
        if let index = projects.firstIndex(where: { $0.id == projectID }) {
            projects[index].isRunning = tasks.contains(where: \.isRunning)
        }
    }

    func checkoutBranch(_ branch: String) {
        guard let project = selectedProject, !isGitBusy, canLeaveConflict() else { return }
        conflictDocument = nil
        runGitOperation(project) { await GitService.checkout(branch: branch, at: project.path) }
    }

    func checkoutRemoteBranch(_ remoteBranch: String) {
        guard let project = selectedProject, !isGitBusy, canLeaveConflict() else { return }
        conflictDocument = nil
        let remote = gitRemotes.sorted { $0.name.count > $1.name.count }.first { remoteBranch.hasPrefix($0.name + "/") }
        let localName = remote.map { String(remoteBranch.dropFirst($0.name.count + 1)) } ?? remoteBranch.split(separator: "/", maxSplits: 1).dropFirst().joined(separator: "/")
        runGitOperation(project) { await GitService.checkoutRemote(remoteBranch, localName: localName, at: project.path) }
    }

    func createBranch(_ name: String, checkout: Bool = true, from baseBranch: String? = nil, completion: (@MainActor (CommandResult) -> Void)? = nil) {
        guard let project = selectedProject, !isGitBusy else {
            completion?(CommandResult(output: "请选择项目并等待当前 Git 操作完成。 / Select a project and wait for Git to finish.", status: 1)); return
        }
        if checkout && !canLeaveConflict() {
            completion?(CommandResult(output: "已保留未保存的冲突结果。 / Unsaved conflict result was kept.", status: 1)); return
        }
        runGitOperation(project, presentError: completion == nil, completion: completion) {
            await GitService.createBranch(name, checkout: checkout, from: baseBranch, at: project.path)
        }
    }

    func deleteBranch(_ name: String, force: Bool = false) {
        guard let project = selectedProject else { return }
        let title = force ? (language == .chinese ? "强制删除分支？" : "Force delete branch?") : (language == .chinese ? "删除分支？" : "Delete branch?")
        let message = force ? "\(name)\n\n" + (language == .chinese ? "未合并的提交将无法通过此分支访问。" : "Unmerged commits will no longer be reachable from this branch.") : name
        guard confirmDestructive(title: title, message: message) else { return }
        runGitOperation(project) { await GitService.deleteBranch(name, force: force, at: project.path) }
    }

    func deleteRemoteBranch(_ snapshot: GitRemoteBranchSnapshot, credentials: GitCredentials, completion: @escaping @MainActor (CommandResult) -> Void) {
        guard let project = selectedProject, !isGitBusy else { completion(CommandResult(output: "Git 正忙，请稍后重试。 / Git is busy. Try again shortly.", status: 1)); return }
        runGitOperation(project, presentError: false, completion: completion) { await GitService.deleteRemoteBranch(snapshot, at: project.path, credentials: credentials) }
    }

    func submoduleAction(_ action: GitSubmoduleAction, module: GitSubmodule, recursive: Bool, credentials: GitCredentials, completion: @escaping @MainActor (CommandResult) -> Void) {
        guard let project = selectedProject, !isGitBusy else { completion(CommandResult(output: "Git 正忙，请稍后重试。 / Git is busy. Try again shortly.", status: 1)); return }
        runGitOperation(project, label: "submodule.\(action)", presentError: false, completion: completion) { await GitService.submoduleAction(action, module: module, recursive: recursive, credentials: credentials) }
    }

    func addSubmodule(_ request: GitSubmoduleAddRequest, credentials: GitCredentials, completion: @escaping @MainActor (CommandResult) -> Void) {
        guard let project = selectedProject, !isGitBusy else { completion(CommandResult(output: "Git 正忙，请稍后重试。 / Git is busy. Try again shortly.", status: 1)); return }
        runGitOperation(project, presentError: false, completion: completion) { await GitService.addSubmodule(request, at: project.path, credentials: credentials) }
    }

    func removeSubmodule(_ module: GitSubmodule, completion: @escaping @MainActor (CommandResult) -> Void) {
        guard let project = selectedProject, !isGitBusy else { completion(CommandResult(output: "Git 正忙，请稍后重试。 / Git is busy. Try again shortly.", status: 1)); return }
        let childPath = URL(fileURLWithPath: module.absolutePath).resolvingSymlinksInPath().path
        guard !projects.contains(where: {
            let path = URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path
            return path == childPath || path.hasPrefix(childPath + "/")
        }) else { completion(CommandResult(output: "请先关闭此子模块及其内部项目的标签，再移除。 / Close this submodule and its nested project tabs before removal.", status: 1)); return }
        runGitOperation(project, presentError: false, completion: completion) { await GitService.removeSubmodule(module) }
    }

    func moveWorktree(_ tree: GitWorktree, destination: String, completion: @escaping @MainActor (CommandResult) -> Void) {
        guard let project = selectedProject, !isGitBusy else { completion(CommandResult(output: "Git 正忙，请稍后重试。 / Git is busy. Try again shortly.", status: 1)); return }
        let root = URL(fileURLWithPath: tree.path).resolvingSymlinksInPath().standardizedFileURL.path
        guard !projects.contains(where: {
            let location = URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path
            return location == root || location.hasPrefix(root + "/")
        }) else { completion(CommandResult(output: "请先关闭该工作树及其内部项目的标签。 / Close this worktree and its nested project tabs first.", status: 1)); return }
        runGitOperation(project, presentError: false, completion: completion) { await GitService.moveWorktree(tree, destination: destination, at: project.path) }
    }

    func setWorktreeLocked(_ tree: GitWorktree, locked: Bool, reason: String, completion: @escaping @MainActor (CommandResult) -> Void) {
        guard let project = selectedProject, !isGitBusy else { completion(CommandResult(output: "Git 正忙，请稍后重试。 / Git is busy. Try again shortly.", status: 1)); return }
        runGitOperation(project, presentError: false, completion: completion) { await GitService.setWorktreeLocked(tree, locked: locked, reason: reason, at: project.path) }
    }

    func pruneWorktrees(_ expected: [GitWorktree], completion: @escaping @MainActor (CommandResult) -> Void) {
        guard let project = selectedProject, !isGitBusy else { completion(CommandResult(output: "Git 正忙，请稍后重试。 / Git is busy. Try again shortly.", status: 1)); return }
        runGitOperation(project, presentError: false, completion: completion) { await GitService.pruneWorktrees(expected: expected, at: project.path) }
    }

    func addWorktree(destination: String, mode: GitWorktreeMode, branch: String, target: String, completion: @escaping @MainActor (CommandResult) -> Void) {
        guard let project = selectedProject, !isGitBusy else { completion(CommandResult(output: "Git 正忙，请稍后重试。 / Git is busy. Try again shortly.", status: 1)); return }
        runGitOperation(project, presentError: false, completion: completion) { await GitService.addWorktree(destination: destination, mode: mode, branch: branch, target: target, at: project.path) }
    }

    func removeWorktree(_ tree: GitWorktree, completion: @escaping @MainActor (CommandResult) -> Void) {
        guard let project = selectedProject, !isGitBusy else { completion(CommandResult(output: "Git 正忙，请稍后重试。 / Git is busy. Try again shortly.", status: 1)); return }
        let root = URL(fileURLWithPath: tree.path).resolvingSymlinksInPath().standardizedFileURL.path
        guard !projects.contains(where: {
            let location = URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path
            return location == root || location.hasPrefix(root + "/")
        }) else {
            completion(CommandResult(output: "请先关闭该工作树的项目标签。 / Close this worktree's project tab first.", status: 1)); return
        }
        guard confirmDestructive(title: language == .chinese ? "移除工作树？" : "Remove worktree?", message: tree.path + "\n\n" + (language == .chinese ? "此目录将被删除，分支会保留。有未提交内容时 Git 会拒绝移除。" : "This directory will be deleted; its branch is kept. Git refuses if changes are present.")) else { return }
        runGitOperation(project, presentError: false, completion: completion) { await GitService.removeWorktree(tree, at: project.path) }
    }

    func mergeBranch(_ name: String) {
        guard let project = selectedProject, !isGitBusy, canLeaveConflict() else { return }
        conflictDocument = nil
        runGitOperation(project) { await GitService.merge(name, at: project.path) }
    }

    func rebaseBranch(_ name: String) {
        guard let project = selectedProject, !isGitBusy, canLeaveConflict() else { return }
        conflictDocument = nil
        runGitOperation(project) { await GitService.rebase(name, at: project.path) }
    }

    func renameBranch(_ old: String, to new: String, completion: (@MainActor (CommandResult) -> Void)? = nil) {
        guard let project = selectedProject, !isGitBusy else {
            completion?(CommandResult(output: "请选择项目并等待当前 Git 操作完成。 / Select a project and wait for Git to finish.", status: 1)); return
        }
        runGitOperation(project, presentError: completion == nil, completion: completion) {
            await GitService.renameBranch(old, to: new, at: project.path)
        }
    }

    func setUpstream(_ target: String?, snapshot: GitUpstreamSnapshot, completion: @escaping @MainActor (CommandResult) -> Void) {
        guard let project = selectedProject, !isGitBusy else {
            completion(CommandResult(output: "请等待当前 Git 操作完成。 / Wait for Git to finish.", status: 1)); return
        }
        runGitOperation(project, presentError: false, completion: completion) {
            await GitService.setUpstream(target, snapshot: snapshot, at: project.path)
        }
    }

    func gitAction(_ action: GitAction) {
        if action == .stageAll, gitChanges.contains(where: \.isConflicted) {
            errorMessage = language == .chinese ? "请先解决冲突文件，再暂存全部。" : "Resolve conflicts before staging all files."
            return
        }
        if action == .push { gitSyncKind = .push; return }
        if action == .pull { gitSyncKind = .pull; return }
        guard let project = selectedProject else { return }
        runGitOperation(project, label: "action.\(action)") { await GitService.perform(action, at: project.path) }
    }

    func syncGit(_ kind: GitSyncKind, remote: String, branch: String, setUpstream: Bool, strategy: GitPullStrategy, credentials: GitCredentials = GitCredentials(), forceSnapshot: GitForcePushSnapshot? = nil, completion: @escaping @MainActor (CommandResult) -> Void) {
        guard let project = selectedProject, !isGitBusy else { completion(CommandResult(output: "Git 正忙，请稍后重试。 / Git is busy. Try again shortly.", status: 1)); return }
        if let forceSnapshot, kind != .push || forceSnapshot.destination.remote != remote || forceSnapshot.destination.branch != branch {
            completion(CommandResult(output: "推送目标已改变，请重新打开推送窗口。 / Push target changed. Reopen the push dialog.", status: 1)); return
        }
        runGitOperation(project, label: "sync.\(kind)", presentError: false, completion: completion) {
            if kind == .push, let forceSnapshot { return await GitService.forcePush(forceSnapshot, setUpstream: setUpstream, at: project.path, credentials: credentials) }
            if kind == .push { return await GitService.push(remote: remote, branch: branch, setUpstream: setUpstream, at: project.path, credentials: credentials) }
            if kind == .fetch { return await GitService.fetch(remote: remote, at: project.path, credentials: credentials) }
            return await GitService.pull(remote: remote, branch: branch, strategy: strategy, at: project.path, credentials: credentials)
        }
    }

    private func runGitOperation(_ project: Project, label: String = #function, onSuccess: (@MainActor () -> Void)? = nil, presentError: Bool = true, completion: (@MainActor (CommandResult) -> Void)? = nil, operation: @escaping @MainActor () async -> CommandResult) {
        guard !gitBusyProjects.contains(project.id) else { return }
        gitBusyProjects.insert(project.id)
        let entryID = beginGitConsoleEntry(projectID: project.id, title: GitConsoleTitle.title(label, language: language))
        Task {
            defer { gitBusyProjects.remove(project.id) }
            let rawResult = await operation()
            let result = CommandResult(output: GitDiagnosticRedactor.redact(rawResult.output), status: rawResult.status, truncated: rawResult.truncated)
            finishGitConsoleEntry(entryID, projectID: project.id, result: result, presentError: presentError)
            guard selectedProjectID == project.id else { completion?(result); return }
            await refreshProject(project)
            if selectedProjectID == project.id {
                if result.status == 0 { onSuccess?() }
            }
            completion?(result)
        }
    }

    func ignoreUntrackedFile(_ file: String) {
        guard let project = selectedProject, !isGitBusy else { return }
        runGitOperation(project) { await GitService.ignoreUntrackedFile(file, at: project.path) }
    }

    func initializeGit() {
        guard let project = selectedProject else { return }
        runGitOperation(project) { await GitService.initialize(at: project.path) }
    }

    func applyDiffHunk(_ index: Int, file: String, expectedDiff: String, staged: Bool) {
        guard let project = selectedProject, historyCommit == nil, conflictDocument == nil, !isGitBusy,
              let change = gitChanges.first(where: { $0.path == file }), [" M", "M ", "MM"].contains(change.state) else { return }
        guard diffContent == expectedDiff, diffIsStaged == staged else { return }
        runGitOperation(project) { await GitService.applyIndexHunk(file: file, hunk: index, staged: staged, expectedDiff: expectedDiff, at: project.path) }
    }

    func discardDiffHunk(_ index: Int, file: String, expectedDiff: String) {
        guard let project = selectedProject, historyCommit == nil, conflictDocument == nil, !isGitBusy, !diffIsStaged,
              let change = gitChanges.first(where: { $0.path == file }), [" M", "MM"].contains(change.state), diffContent == expectedDiff else { return }
        let document = GitDiffDocument(expectedDiff)
        guard document.supportsPartialIndex, document.hunks.indices.contains(index) else { return }
        guard confirmDestructive(title: language == .chinese ? "回滚此修改块？" : "Revert this hunk?", message: file + "\n" + document.hunks[index].header + "\n\n" + (language == .chinese ? "此块的未暂存修改将被撤回。其他修改块和暂存内容会保留。此操作无法通过 Git 撤销。" : "This unstaged hunk will be discarded. Other hunks and staged content are kept. Git cannot undo this action.")) else { return }
        runGitOperation(project) { await GitService.discardWorktreeHunk(file: file, hunk: index, expectedDiff: expectedDiff, at: project.path) }
    }

    func runBatchGitOperation(_ project: Project, action: GitFileAction, changes: [GitChange]) {
        runGitOperation(project, label: "batch.\(action)") { await GitService.batchFileAction(action, changes: changes, at: project.path) }
    }

    func gitFileAction(_ action: GitFileAction, path: String, isUntracked: Bool = false) {
        guard let project = selectedProject else { return }
        if action == .stage, gitChanges.contains(where: { $0.path == path && $0.isConflicted }) {
            markConflictResolved(GitChange(path: path, state: "UU")); return
        }
        if action == .discard && !confirmDestructive(title: language == .chinese ? "丢弃文件修改？" : "Discard file changes?", message: language == .chinese ? "此操作无法撤销。" : "This action cannot be undone.") { return }
        let originalPath = gitChanges.first(where: { $0.path == path })?.originalPath
        runGitOperation(project, label: "file.\(action)") { await GitService.fileAction(action, path: path, at: project.path, isUntracked: isUntracked, originalPath: originalPath) }
    }

    func stashAction(_ action: GitStashAction, stash: GitStash, restoreIndex: Bool = false, completion: (@MainActor (CommandResult) -> Void)? = nil) {
        guard let project = selectedProject, !isGitBusy, canLeaveConflict() else { return }
        if action == .drop, !confirmDestructive(title: language == .chinese ? "丢弃 Stash？" : "Drop stash?", message: "\(stash.reference) · \(stash.message)") { return }
        runGitOperation(project, label: "stash.\(action)", presentError: completion == nil, completion: completion) { await GitService.stashAction(action, stash: stash, restoreIndex: restoreIndex, at: project.path) }
    }

    func saveStash(message: String, includeUntracked: Bool, keepIndex: Bool, completion: (@MainActor (CommandResult) -> Void)? = nil) {
        guard let project = selectedProject, !isGitBusy, canLeaveConflict() else { return }
        runGitOperation(project, presentError: completion == nil, completion: completion) { await GitService.saveStash(message: message, includeUntracked: includeUntracked, keepIndex: keepIndex, at: project.path) }
    }

    func remoteAction(_ action: GitRemoteAction, name: String, url: String = "", expected: GitRemote? = nil, completion: (@MainActor (CommandResult) -> Void)? = nil) {
        guard let project = selectedProject, !isGitBusy else { return }
        if action == .remove, !confirmDestructive(title: language == .chinese ? "移除远程仓库？" : "Remove remote?", message: name + (language == .chinese ? "\n远程服务器上的仓库和提交不会删除，本地跟踪引用将移除。" : "\nThe server repository is kept; local tracking references are removed.")) { return }
        runGitOperation(project, label: "remote.\(action)", presentError: completion == nil, completion: completion) { await GitService.remoteAction(action, name: name, url: url, expected: expected, at: project.path) }
    }

    func refreshDocker() {
        guard dockerTask == nil, dockerBusyContainer == nil else { return }
        isDockerLoading = true; dockerError = nil
        dockerTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = await dockerClient.list()
            applyDockerSnapshot(snapshot)
            isDockerLoading = false; dockerLoaded = true; dockerTask = nil
        }
    }

    private func applyDockerSnapshot(_ snapshot: DockerSnapshot) {
        dockerError = snapshot.error
        if snapshot.error == nil { dockerContainers = snapshot.containers }
    }

    func createManagedTag(name: String, target: String, message: String, completion: @escaping @MainActor (CommandResult) -> Void) {
        guard let project = selectedProject else { return }
        runGitOperation(project, presentError: false, completion: completion) { await GitService.createTag(name, target: target, message: message, at: project.path) }
    }

    func deleteManagedTag(_ tag: GitTagDetails, completion: @escaping @MainActor (CommandResult) -> Void) {
        guard let project = selectedProject, !isGitBusy else { return }
        guard confirmDestructive(title: language == .chinese ? "删除本地标签？" : "Delete local tag?", message: tag.name + (language == .chinese ? "\n远程标签不会删除。" : "\nThe remote tag is kept.")) else { return }
        runGitOperation(project, presentError: false, completion: completion) { await GitService.deleteTag(tag, at: project.path) }
    }

    func pushManagedTag(_ tag: GitTagDetails, remote: String, credentials: GitCredentials, completion: @escaping @MainActor (CommandResult) -> Void) {
        guard let project = selectedProject else { return }
        runGitOperation(project, presentError: false, completion: completion) { await GitService.pushTag(tag, remote: remote, at: project.path, credentials: credentials) }
    }

    func checkoutManagedTag(_ tag: GitTagDetails, completion: @escaping @MainActor (CommandResult) -> Void) {
        guard let project = selectedProject, !isGitBusy, canLeaveConflict() else { return }
        guard confirmDestructive(title: language == .chinese ? "切换到标签？" : "Check out tag?", message: tag.name + (language == .chinese ? "\n将进入分离 HEAD 状态。如需继续提交，请创建新分支。" : "\nHEAD will be detached. Create a branch before making new commits.")) else { return }
        runGitOperation(project, presentError: false, completion: completion) { await GitService.checkoutTag(tag, at: project.path) }
    }

    func dockerAction(_ action: DockerAction, container: DockerContainer) {
        guard dockerBusyContainer == nil, !isDockerLoading else { return }
        dockerBusyContainer = container.id
        dockerLastActions[container.id] = action
        dockerActionErrors.removeValue(forKey: container.id); dockerNotice = nil
        Task { [weak self] in
            guard let self else { return }
            let result = await dockerClient.perform(action, container.id)
            if result.status != 0 {
                dockerActionErrors[container.id] = Copy.t("操作失败（退出码 \(result.status)）", "Operation failed (exit code \(result.status))", language: language) + "\n" + String(result.output.suffix(4000))
            } else {
                dockerNotice = Copy.t("“\(container.name)”操作已完成。", "Operation completed for ‘\(container.name)’.", language: language)
            }
            let snapshot = await dockerClient.list()
            applyDockerSnapshot(snapshot)
            dockerLoaded = true; dockerBusyContainer = nil
        }
    }

    func startInteractiveRebase(_ steps: [GitRebaseStep], snapshot: GitRebaseSnapshot, completion: @escaping @MainActor (CommandResult) -> Void) {
        guard let project = selectedProject, !isGitBusy else {
            completion(CommandResult(output: "请选择项目并等待当前 Git 操作完成。 / Select a project and wait for Git to finish.", status: 1)); return
        }
        runGitOperation(project, presentError: false, completion: completion) {
            await GitService.interactiveRebase(steps, snapshot: snapshot, at: project.path)
        }
    }

    func amendLastCommit(message: String, snapshot: GitAmendSnapshot, includeStaged: Bool, completion: @escaping @MainActor (CommandResult) -> Void) {
        guard let project = selectedProject else { return }
        runGitOperation(project, presentError: false, completion: completion) {
            await GitService.amend(message: message, expectedHEAD: snapshot.hash, includeStaged: includeStaged, at: project.path)
        }
    }

    func commitChanges(pushAfter: Bool = false) {
        guard let project = selectedProject, !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard gitChanges.contains(where: { $0.isStaged }) else {
            errorMessage = language == .chinese ? "请先暂存至少一个文件，再提交。" : "Stage at least one file before committing."
            return
        }
        let message = commitMessage
        runGitOperation(project, onSuccess: { if pushAfter { self.gitSyncKind = .push } }) {
            let result = await CommandRunner.run(command: "git commit -m \(Shell.quote(message))", cwd: project.path)
            if result.status == 0 {
                if self.commitDrafts[project.path] == message { self.commitDrafts[project.path] = nil }
                if self.selectedProjectID == project.id, self.commitMessage == message { self.commitMessage = "" }
            }
            return result
        }
    }

    func selectProject(_ project: Project) {
        guard !showRunSettings, confirmSheetQuit == nil else { return }
        guard selectedProjectID != project.id, projects.contains(where: { $0.id == project.id }) else { return }
        guard canLeaveConflict() else { return }
        PreviewTrace.shared?.cancel()
        rememberProjectEditor()
        gitFileHistoryPath = nil
        conflictDocument = nil
        gitOperationState = nil
        previewWasClosed = false
        if let current = selectedProject { commitDrafts[current.path] = commitMessage }
        commitMessage = commitDrafts[project.path] ?? ""
        errorMessage = nil
        gitLastResult = gitConsoleEntries[project.id]?.last?.summary(language) ?? ""
        previewTask?.cancel()
        refreshID = UUID()
        selectedProjectID = project.id
        UserDefaults.standard.set(project.path, forKey: "selectedProjectPath")
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].runConfigurations = loadRunConfigurations(for: project.path)
            projects[index].runConfigurationsLoaded = runConfigFileExists(for: project.path)
        }
        selectedRunConfigurationID = nil
        restoreRunSelection(for: project)
        commandOutput = project.output
        selectedFile = ""
        fileContent = ""
        filePreviewDocument = nil
        diffContent = ""
        historyCommit = nil
        fileItems = []
        gitChanges = []
        gitStatusError = nil
        gitOperationState = nil
        gitBranch = ""
        gitTracking = nil
        isGitRepository = false
        gitBranches = []
        gitRemoteBranches = []
        gitCommits = []
        gitTags = []
        gitStashes = []
        gitRemotes = []
        restoreProjectEditor(project)
        Task { await refreshProject(project) }
    }

    func selectAdjacentProject(offset: Int) {
        guard !projects.isEmpty else { return }
        let currentIndex = selectedProjectID.flatMap { id in projects.firstIndex(where: { $0.id == id }) } ?? 0
        let nextIndex = (currentIndex + offset + projects.count) % projects.count
        selectProject(projects[nextIndex])
    }

    func addProject() {
        guard !showRunSettings, confirmSheetQuit == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = language == .chinese ? "添加项目" : "Add Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    func openProject(at url: URL) {
        guard !showRunSettings, confirmSheetQuit == nil else { return }
        let normalizedPath = url.standardizedFileURL.path
        if let existing = projects.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == normalizedPath }) {
            selectProject(existing)
            return
        }
        let name = url.lastPathComponent.isEmpty ? normalizedPath : url.lastPathComponent
        let project = Project(name: name, path: normalizedPath)
        projects.append(project)
        saveRecentProjects()
        selectProject(project)
    }

    func closeProject(_ id: UUID) {
        guard !showRunSettings, confirmSheetQuit == nil else { return }
        guard let removedIndex = projects.firstIndex(where: { $0.id == id }) else { return }
        let project = projects[removedIndex]
        guard !gitBusyProjects.contains(id) else {
            errorMessage = Copy.t("“\(project.name)”正在执行 Git 操作，请完成后再关闭项目。", "Git is working in ‘\(project.name)’. Wait for it to finish before closing the project.", language: language)
            return
        }
        if terminals.sessions[id]?.contains(where: \.hasRunningCommands) == true || CommandRunner.hasRunningProcesses(projectID: id) || runningTasks[id]?.contains(where: \.isRunning) == true {
            let alert = NSAlert()
            alert.messageText = Copy.t("停止运行并关闭项目？", "Stop commands and close the project?", language: language)
            alert.informativeText = Copy.t("“\(project.name)”仍有运行中的命令或终端会话。关闭项目将停止这些进程，其他项目不受影响。", "‘\(project.name)’ has running commands or terminal sessions. Closing it stops those processes and leaves other projects running.", language: language)
            let cancelButton = alert.addButton(withTitle: Copy.t("取消", "Cancel", language: language))
            cancelButton.keyEquivalent = "\u{1b}"
            alert.addButton(withTitle: Copy.t("停止并关闭", "Stop and Close", language: language))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        if selectedProjectID == id, !canLeaveConflict() { return }
        if selectedProjectID == id { conflictDocument = nil }
        let taskIDs = Set(runningTasks[id, default: []].map(\.id))
        restartingTaskIDs.subtract(taskIDs)
        selectedTaskIDs.removeValue(forKey: id)
        CommandRunner.stop(projectID: id)
        // A process can take a short time to acknowledge SIGTERM. Release
        // the UI delivery streams immediately so a closed project cannot
        // retain output or a delivery closure while another project is active.
        taskIDs.forEach { runOutputStreams.removeValue(forKey: $0) }
        terminals.closeProject(id)
        quickCommandDrafts.removeValue(forKey: id)
        projectEditorLocations.removeValue(forKey: id)
        runningTasks.removeValue(forKey: id)
        gitConsoleEntries.removeValue(forKey: id)
        selectedGitConsoleEntryIDs.removeValue(forKey: id)
        autoStartedProjects.remove(id)
        if let project = projects.first(where: { $0.id == id }) { commitDrafts.removeValue(forKey: project.path); activeRunConfigurations.removeValue(forKey: project.path) }
        projects.removeAll { $0.id == id }
        saveRecentProjects()
        if selectedProjectID == id {
            if !projects.isEmpty { selectProject(projects[min(removedIndex, projects.count - 1)]) }
            else {
                previewTask?.cancel(); refreshID = UUID(); isLoading = false
                selectedProjectID = nil; selectedRunConfigurationID = nil; commandText = ""
                UserDefaults.standard.removeObject(forKey: "selectedProjectPath")
                selectedFile = ""; fileContent = ""; filePreviewDocument = nil; diffContent = ""; historyCommit = nil; gitFileHistoryPath = nil
                fileItems = []; gitChanges = []; gitBranches = []; gitRemoteBranches = []; gitCommits = []; gitTags = []; gitStashes = []; gitRemotes = []
                gitOperationState = nil; gitStatusError = nil; gitBranch = ""; gitTracking = nil; isGitRepository = false
                gitLastResult = ""; commitMessage = ""; errorMessage = nil
                commandOutput = language == .chinese ? "请添加一个项目开始使用。" : "Add a project to get started."
            }
        }
    }

    func refreshEnvironment() {
        guard environmentTask == nil else { return }
        isEnvironmentLoading = true; environmentError = nil
        environmentTask = Task { [weak self] in
            let detected = await EnvironmentDetector.detect()
            guard let self else { return }
            if detected.error == nil { environments = detected.items }
            environmentError = detected.error; isEnvironmentLoading = false
            environmentLoaded = true; environmentTask = nil
        }
    }

    private func saveRecentProjects() { UserDefaults.standard.set(projects.map(\.path), forKey: "recentProjectPaths") }

    private func runConfigURL(for path: String) -> URL {
        URL(fileURLWithPath: path).appendingPathComponent(".git-workbench/run-config.json")
    }

    private func runConfigFileExists(for path: String) -> Bool { FileManager.default.fileExists(atPath: runConfigURL(for: path).path) }

    private func loadRunConfigurations(for path: String) -> [RunConfiguration] {
        let url = runConfigURL(for: path)
        let data = FilePreviewReader.readRange(path: url.path, offset: 0, count: 1024 * 1024 + 1)
        guard let configs = RunConfigurationValidation.decodeSaved(data) else { return [] }
        return configs
    }

    private func confirmDestructive(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: language == .chinese ? "继续" : "Continue")
        alert.addButton(withTitle: language == .chinese ? "取消" : "Cancel").keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }

    func gitAdvanced(_ operation: GitAdvancedOperation, value: String = "", mainline: Int? = nil, completion: (@MainActor (CommandResult) -> Void)? = nil) {
        guard let project = selectedProject, !isGitBusy else {
            completion?(CommandResult(output: "请选择项目并等待当前 Git 操作完成。 / Select a project and wait for Git to finish.", status: 1)); return
        }
        let cancelled = { completion?(CommandResult(output: "已取消操作。 / Operation cancelled.", status: 130)) }
        if [.mergeAbort, .rebaseAbort, .cherryPickAbort, .revertAbort].contains(operation) {
            guard confirmDestructive(title: language == .chinese ? "中止当前 Git 操作？" : "Abort the current Git operation?", message: language == .chinese ? "当前冲突处理结果将被放弃，Git 会恢复操作开始前的状态。" : "Conflict resolution work will be discarded and Git will restore the state before this operation.") else { cancelled(); return }
            conflictDocument = nil
        }
        if [.rebaseSkip, .cherryPickSkip, .revertSkip].contains(operation) {
            guard confirmDestructive(title: language == .chinese ? "跳过当前提交？" : "Skip the current commit?", message: language == .chinese ? "当前提交的改动及冲突处理结果将被放弃，Git 会继续处理后续提交。" : "Changes and conflict resolutions for the current commit will be discarded. Git will proceed with the remaining commits.") else { cancelled(); return }
            conflictDocument = nil
        }
        if operation == .resetHard && !confirmDestructive(title: language == .chinese ? "执行硬重置？" : "Perform hard reset?", message: language == .chinese ? "未提交的工作区修改将被丢弃。" : "Uncommitted workspace changes will be discarded.") { cancelled(); return }
        if operation == .tagDelete && !confirmDestructive(title: language == .chinese ? "删除标签？" : "Delete tag?", message: value) { cancelled(); return }
        runGitOperation(project, label: "advanced.\(operation)", presentError: completion == nil, completion: completion) {
            let result: CommandResult
            switch operation {
            case .revert: result = await GitService.revert(value, mainline: mainline, at: project.path)
            case .cherryPick: result = await GitService.cherryPick(value, mainline: mainline, at: project.path)
            case .resetSoft: result = await GitService.reset(value, mode: "--soft", at: project.path)
            case .resetMixed: result = await GitService.reset(value, mode: "--mixed", at: project.path)
            case .resetHard: result = await GitService.reset(value, mode: "--hard", at: project.path)
            case .tagCreate: result = await GitService.createTag(value, at: project.path)
            case .tagDelete:
                result = await GitService.deleteTag(value, at: project.path)
            case .rebaseContinue: result = await GitService.rebaseContinue(at: project.path)
            case .rebaseAbort: result = await GitService.rebaseAbort(at: project.path)
            case .mergeAbort: result = await GitService.mergeAbort(at: project.path)
            case .mergeContinue: result = await GitService.continueOperation(.merging, at: project.path)
            case .cherryPickContinue: result = await GitService.continueOperation(.cherryPicking, at: project.path)
            case .revertContinue: result = await GitService.continueOperation(.reverting, at: project.path)
            case .cherryPickAbort: result = await CommandRunner.run(command: "git cherry-pick --abort", cwd: project.path)
            case .revertAbort: result = await CommandRunner.run(command: "git revert --abort", cwd: project.path)
            case .rebaseSkip: result = await GitService.skipOperation(.rebasing, at: project.path)
            case .cherryPickSkip: result = await GitService.skipOperation(.cherryPicking, at: project.path)
            case .revertSkip: result = await GitService.skipOperation(.reverting, at: project.path)
            }
            return result
        }
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            background = .image(url)
            UserDefaults.standard.set(url.path, forKey: "backgroundImagePath")
            UserDefaults.standard.set("image", forKey: "backgroundStyle")
        }
    }

    func persistPreferences() {
        UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
        UserDefaults.standard.set(theme.rawValue, forKey: "appTheme")
        UserDefaults.standard.set(editorFontSize, forKey: "editorFontSize")
        switch background {
        case .plain: UserDefaults.standard.set("plain", forKey: "backgroundStyle")
        case .aurora: UserDefaults.standard.set("aurora", forKey: "backgroundStyle")
        case .image(let url): UserDefaults.standard.set("image", forKey: "backgroundStyle"); UserDefaults.standard.set(url.path, forKey: "backgroundImagePath")
        }
    }

    func closePreview() {
        guard canLeaveConflict() else { return }
        PreviewTrace.shared?.cancel()
        previewWasClosed = true
        conflictDocument = nil
        previewTask?.cancel()
        selectedFile = ""
        fileContent = ""
        filePreviewDocument = nil
        diffContent = ""
        historyCommit = nil
    }

    func openFile(_ item: FileItem) {
        guard !item.isDirectory else { return }
        openFilePath(item.path)
    }

    func openFilePath(_ path: String) {
        guard canLeaveConflict() else { return }
        let keepContent = selectedFile == path && diffContent.isEmpty && historyCommit == nil && conflictDocument == nil
        if !keepContent { PreviewTrace.shared?.begin(file: path) }
        previewWasClosed = false
        conflictDocument = nil
        historyCommit = nil
        selectedFile = path
        diffContent = ""
        previewTask?.cancel()
        if !keepContent { fileContent = ""; filePreviewDocument = nil }
        previewTask = Task {
            if let cached = await PreviewCache.shared.value(for: path) {
                guard !Task.isCancelled, selectedFile == path else { return }
                PreviewTrace.shared?.didRead(file: path)
                filePreviewDocument = cached
                if fileContent != cached.text { fileContent = cached.text }
                return
            }
            let preview = await Task.detached(priority: .userInitiated) {
                let revision = FileRevision.read(path)
                return (FilePreviewReader.read(path: path), revision)
            }.value
            guard !Task.isCancelled, selectedFile == path else { return }
            await PreviewCache.shared.insert(preview.0, for: path, revision: preview.1)
            guard !Task.isCancelled, selectedFile == path else { return }
            PreviewTrace.shared?.didRead(file: path)
            filePreviewDocument = preview.0
            if fileContent != preview.0.text { fileContent = preview.0.text }
        }
    }

    func openDiff(_ change: GitChange, staged: Bool = false) {
        guard let project = selectedProject else { return }
        if conflictDocument?.file == change.path, conflictDocument?.projectPath == project.path { return }
        guard canLeaveConflict() else { return }
        PreviewTrace.shared?.cancel()
        let path = URL(fileURLWithPath: project.path).appendingPathComponent(change.path).path
        let keepContent = selectedFile == path && historyCommit == nil && conflictDocument == nil && !diffContent.isEmpty && diffIsStaged == staged && !change.isConflicted
        previewWasClosed = false
        conflictDocument = change.isConflicted ? GitConflictDocument(file: change.path, projectPath: project.path) : nil
        previewTask?.cancel()
        historyCommit = nil
        diffIsStaged = staged
        selectedFile = path
        if !keepContent { diffContent = "正在读取差异… / Loading diff…" }
        if change.isConflicted { return }
        previewTask = Task {
            let diff = await GitService.diff(change.path, at: project.path, staged: staged, untracked: change.state == "??")
            guard !Task.isCancelled, selectedProjectID == project.id, selectedFile == path else { return }
            let updated = diff.isEmpty ? "没有差异 / No differences" : diff
            if diffContent != updated { diffContent = updated }
        }
    }

    func showBlame(_ path: String) {
        guard let project = selectedProject, isGitRepository, path.hasPrefix(project.path + "/"), canLeaveConflict() else { return }
        gitBlameTarget = GitBlameTarget(projectID: project.id, root: project.path, file: String(path.dropFirst(project.path.count + 1)))
    }

    func showFileHistory(_ path: String) {
        guard let project = selectedProject, isGitRepository, path.hasPrefix(project.path + "/"), canLeaveConflict() else { return }
        gitFileHistoryPath = String(path.dropFirst(project.path.count + 1))
        gitFileHistoryRequest = UUID()
    }

    func openCommitDiff(_ hash: String, file: String) {
        guard let project = selectedProject, canLeaveConflict() else { return }
        previewWasClosed = false
        conflictDocument = nil
        previewTask?.cancel()
        historyCommit = hash
        selectedFile = URL(fileURLWithPath: project.path).appendingPathComponent(file).path
        diffContent = language == .chinese ? "正在读取提交差异…" : "Loading commit diff…"
        previewTask = Task {
            let diff = await GitService.commitDiff(hash, file: file, at: project.path)
            guard !Task.isCancelled, selectedProjectID == project.id, historyCommit == hash else { return }
            diffContent = diff.isEmpty ? (language == .chinese ? "没有文本差异" : "No text differences") : diff
        }
    }

    func canLeaveConflict() -> Bool {
        guard let document = conflictDocument, document.isDirty else { return true }
        if isGitBusy { return false }
        let alert = NSAlert()
        alert.messageText = language == .chinese ? "放弃未保存的冲突结果？" : "Discard the unsaved conflict result?"
        alert.informativeText = document.file
        alert.addButton(withTitle: language == .chinese ? "继续编辑" : "Keep editing")
        alert.addButton(withTitle: language == .chinese ? "放弃结果" : "Discard result")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func reloadConflictDocument() {
        guard let document = conflictDocument, canLeaveConflict() else { return }
        conflictDocument = GitConflictDocument(file: document.file, projectPath: document.projectPath)
    }

    private func finishResolving(_ file: String) {
        guard conflictDocument?.file == file, let project = selectedProject else { return }
        conflictDocument = nil
        if let next = gitChanges.first(where: \.isConflicted) { openDiff(next) }
        else {
            let path = URL(fileURLWithPath: project.path).appendingPathComponent(file).path
            if FileManager.default.fileExists(atPath: path) { openFilePath(path) } else { closePreview() }
        }
    }

    func saveConflictDocument() {
        guard let project = selectedProject, let document = conflictDocument, let snapshot = document.snapshot else { return }
        let result: String? = document.deleteResult ? nil : document.result
        runGitOperation(project, onSuccess: { self.finishResolving(document.file) }) {
            await GitService.saveConflict(document.file, result: result, snapshot: snapshot, at: project.path)
        }
    }

    func resolveConflict(_ change: GitChange, using side: ConflictSide) {
        guard let project = selectedProject, canLeaveConflict() else { return }
        runGitOperation(project, onSuccess: { self.finishResolving(change.path) }) { await GitService.resolve(change.path, side: side, at: project.path) }
    }

    func markConflictResolved(_ change: GitChange) {
        guard let project = selectedProject, canLeaveConflict() else { return }
        runGitOperation(project, onSuccess: { self.finishResolving(change.path) }) { await GitService.markConflictResolved(change.path, at: project.path) }
    }

    func refreshProject(_ project: Project) async {
        guard selectedProjectID == project.id else { return }
        let requestID = UUID()
        refreshID = requestID
        isLoading = true
        let url = URL(fileURLWithPath: NSString(string: project.path).expandingTildeInPath)
        let tree = await Task.detached(priority: .userInitiated) { FileTreeLoader.load(url: url) }.value
        guard selectedProjectID == project.id, refreshID == requestID else { return }
        fileItems = tree
        fileTreeRevision = UUID()
        openInitialPreview(project, tree: tree)
        // These reads have no shared mutable Git state. Start them together so
        // switching a project does not wait for one probe to finish before the
        // next one begins; the selected-project/request guards below still
        // prevent stale results from replacing the active tab.
        async let statusRead = GitService.status(at: url.path)
        async let operationRead = GitService.operationState(at: url.path)
        let status = await statusRead
        let operation = await operationRead
        guard selectedProjectID == project.id, refreshID == requestID else { return }
        gitStatusError = status.error
        guard status.error == nil else {
            // Navigation must remain usable when Git cannot read the repository.
            restoreProjectDiff(project, changes: [])
            gitTracking = nil; isLoading = false; return
        }
        gitChanges = status.changes
        restoreProjectDiff(project, changes: status.changes)
        gitOperationState = operation
        if !diffContent.isEmpty && historyCommit == nil && conflictDocument == nil {
            let relative = String(selectedFile.dropFirst(url.path.count + 1))
            if let change = status.changes.first(where: { $0.path == relative }) {
                openDiff(change, staged: diffIsStaged ? change.isStaged : !change.isUnstaged)
            } else if FileManager.default.fileExists(atPath: selectedFile) { openFilePath(selectedFile) }
            else { closePreview() }
        }
        if diffContent.isEmpty, conflictDocument == nil, historyCommit == nil, !selectedFile.isEmpty {
            if FileManager.default.fileExists(atPath: selectedFile) { openFilePath(selectedFile) }
            else { closePreview() }
        }
        gitBranch = status.branch
        gitTracking = status.isRepository ? status.tracking : nil
        isGitRepository = status.isRepository
        // The remaining repository metadata is independent as well. Keep the
        // command runner bounded per operation, while allowing the selected
        // project to populate its tab in parallel.
        async let branchesRead = GitService.branches(at: url.path)
        async let remoteBranchesRead = GitService.remoteBranches(at: url.path)
        async let commitsRead = GitService.commits(at: url.path)
        async let tagsRead = GitService.tags(at: url.path)
        async let stashesRead = GitService.stashes(at: url.path)
        async let remotesRead = GitService.remotes(at: url.path)
        async let detectedRead = Task.detached(priority: .utility) { ProjectCommandDetector.detect(at: url) }.value
        let branches = await branchesRead
        let remoteBranches = await remoteBranchesRead
        let commits = await commitsRead
        let tags = await tagsRead
        let stashes = await stashesRead
        let remotes = await remotesRead
        let detected = await detectedRead
        guard selectedProjectID == project.id, refreshID == requestID else { return }
        gitBranches = branches
        gitRemoteBranches = remoteBranches
        gitCommits = commits
        gitTags = tags
        gitStashes = stashes
        gitRemotes = remotes
        if let index = projects.firstIndex(where: { $0.id == project.id }), !projects[index].runConfigurationsLoaded {
            projects[index].runConfigurations = detected
            projects[index].runConfigurationsLoaded = true
        }
        if selectedRunConfigurationID == nil { restoreRunSelection(for: project) }
        if let index = projects.firstIndex(where: { $0.id == project.id }), !autoStartedProjects.contains(project.id) {
            autoStartedProjects.insert(project.id)
            for config in projects[index].runConfigurations where config.autoStart {
                runCommand(command: config.command, workingDirectory: config.workingDirectory, environment: config.environment, configurationID: config.id, name: config.name)
            }
        }
        let projectRoot = url.standardizedFileURL.path
        let selectedFileBelongsToProject = selectedFile.hasPrefix(projectRoot + "/")
        if !previewWasClosed, historyCommit == nil, conflictDocument == nil, (!selectedFileBelongsToProject || !FileManager.default.fileExists(atPath: selectedFile)) {
            // The root listing is intentionally shallow for large projects. If it
            // contains only directories, find one preview target one directory at
            // a time instead of recursively materializing the whole tree.
            let firstPath: String?
            if let first = firstFile(in: tree) {
                firstPath = first.path
            } else {
                firstPath = await Task.detached(priority: .utility) {
                    FileTreeLoader.firstFileURL(url: url)?.path
                }.value
            }
            guard selectedProjectID == project.id, refreshID == requestID else { return }
            if let firstPath { openFilePath(firstPath) }
        }
        isLoading = false
        // Machine-wide probes have their own lifecycle. Never keep a repository
        // busy or discard probe results merely because a project tab changed.
        if !dockerLoaded { refreshDocker() }
        if !environmentLoaded { refreshEnvironment() }
    }

    private func firstFile(in items: [FileItem]) -> FileItem? { for item in items { if !item.isDirectory { return item }; if let child = firstFile(in: item.children) { return child } }; return nil }


}

struct Project: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let path: String
    var command = ""
    var output = "准备运行项目命令。"
    var isRunning = false
    var runConfigurations: [RunConfiguration] = []
    var runConfigurationsLoaded = false
}

struct RunConfiguration: Identifiable, Equatable, Codable { var id = UUID(); var name: String; var command: String; var workingDirectory: String; var environment: [String: String] = [:]; var autoStart = false }
struct RunningTask: Identifiable, Equatable {
    let id: UUID
    let command: String
    var output: String
    var isRunning: Bool
    var exitCode: Int32?
    var configurationID: UUID? = nil
    var name: String? = nil
    var workingDirectory = ""
    var environment: [String: String] = [:]
    var logWasCleared = false
    var logWasTruncated = false
    var isStopping = false
    var startedAt = Date()
    var endedAt: Date? = nil
    var displayName: String { name ?? command }
    var wasStopped: Bool { !isRunning && exitCode == -15 }
}

enum EnvironmentParser {
    /// JSON quoting keeps newlines, quotes and backslashes on one form row.
    /// Values remain literal environment strings; they are never evaluated.
    static func serialize(_ values: [String: String]) -> String {
        values.keys.sorted().map { key in
            // JSONEncoder currently cannot fail for String, but keep this path
            // recoverable so a future value type or encoder change cannot crash
            // the settings sheet while it is rendering user data.
            let data = (try? JSONEncoder().encode(values[key] ?? "")) ?? Data("\"\"".utf8)
            return key + "=" + String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n")
    }

    static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, let first = key.first, (first.isLetter || first == "_"), key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            if value.count >= 2, let first = value.first, let last = value.last, (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                if first == "\"", let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) { value = decoded }
                else { value = String(value.dropFirst().dropLast()) }
            }
            values[key] = value
        }
        return values
    }
}

struct GitChange: Identifiable {
    let path: String
    let originalPath: String?
    /// The two porcelain status columns: index state followed by worktree state.
    let state: String
    init(path: String, state: String, originalPath: String? = nil) {
        self.path = path
        self.state = state
        self.originalPath = originalPath
    }
    var id: String { path }
    var isConflicted: Bool { ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(state) }
    var isStaged: Bool { !isConflicted && (state.first.map { $0 != " " && $0 != "?" } ?? false) }
    var isUnstaged: Bool { isConflicted || (state.dropFirst().first.map { $0 != " " } ?? false) }
    var displayState: String { state.trimmingCharacters(in: .whitespaces) }
    var displayPath: String { originalPath.map { "\($0) → \(path)" } ?? path }
}
struct GitCommit: Identifiable, Sendable { let hash: String; let subject: String; let author: String; let date: String; var parents: [String] = []; var refs: [String] = []; var id: String { hash } }
struct GitStash: Identifiable { let reference: String; let message: String; let hash: String; var id: String { hash } }
struct GitRemote: Identifiable, Equatable, Sendable { let name: String; let fetchURL: String; let pushURL: String; var id: String { name } }
struct EnvironmentItem: Identifiable { let name: String; let path: String; let version: String?; let available: Bool; var id: String { name } }
struct DockerContainer: Identifiable { let id: String; let name: String; let image: String; let status: String; let ports: String; var isRunning: Bool { status.lowercased().hasPrefix("up") } }

struct CommandResult {
    let output: String
    let status: Int32
    let truncated: Bool
    var previewOutput: String { (truncated ? "… 差异过大，仅预览末尾部分。 / Large diff: showing the last portion.\n" : "") + output }
    init(output: String, status: Int32, truncated: Bool = false) { self.output = output; self.status = status; self.truncated = truncated }
}

final class OutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    private var didTruncate = false
    var truncated: Bool { lock.lock(); defer { lock.unlock() }; return didTruncate }
    init(limit: Int = 256 * 1024) { self.limit = max(1, limit) }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        if data.count > limit { data = data.suffix(limit); didTruncate = true }
        lock.unlock()
    }

    func text() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

// Serialize each pipe's read and append with its final drain. A termination
// callback may otherwise snapshot output while a readability callback has
// already read bytes but has not appended them yet.
final class CommandPipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let accumulator: OutputAccumulator
    private let onOutput: (@Sendable (String) -> Void)?
    private var decoder = CommandUTF8Decoder()
    private var secretFilter: CommandSecretFilter
    init(handle: FileHandle, accumulator: OutputAccumulator, onOutput: (@Sendable (String) -> Void)?, environment: [String: String] = [:]) {
        self.handle = handle; self.accumulator = accumulator; self.onOutput = onOutput
        secretFilter = CommandSecretFilter(environment: environment)
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) }
    }
    private var finished = false
    func readAvailable() {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        drain(maximumBytes: 256 * 1024)
    }
    func finish() {
        handle.readabilityHandler = nil
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        // A descendant may inherit the write end after the shell exits. Read
        // bytes already available without waiting indefinitely for that EOF.
        drain(maximumBytes: 1024 * 1024)
        let text = secretFilter.append(decoder.decode(Data(), final: true), final: true)
        if !text.isEmpty { onOutput?(text) }
        handle.closeFile()
    }
    private func drain(maximumBytes: Int) {
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        var consumed = 0
        while consumed < maximumBytes {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                consumed += count
                let data = Data(bytes.prefix(count))
                accumulator.append(data)
                let text = secretFilter.append(decoder.decode(data))
                if !text.isEmpty { onOutput?(text) }
            } else if count < 0 && errno == EINTR { continue }
            else {
                if count == 0 { handle.readabilityHandler = nil }
                break
            }
        }
    }
}

@MainActor
enum CommandRunner {
    private static var processes: [UUID: [Process]] = [:]
    private static var taskProcesses: [UUID: Process] = [:]
    private static var taskProcessGroups: [UUID: Int32] = [:]
    private static var requestedStops = Set<UUID>()
    static func run(command: String, cwd: String, projectID: UUID? = nil, taskID: UUID? = nil, environment: [String: String] = [:], outputLimit: Int = 256 * 1024, interactiveShell: Bool = false, timeoutSeconds: Double? = nil, onOutput: (@Sendable (String) -> Void)? = nil) async -> CommandResult {
        await withCheckedContinuation { continuation in
            let process = Process(); let pipe = Pipe(); let err = Pipe(); let output = OutputAccumulator(limit: outputLimit); let errorOutput = OutputAccumulator()
            let trackedID = taskID ?? UUID()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            let overrides = interactiveShell ? environment.keys.sorted().filter { $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }.map { "export \($0)=\(Shell.quote(environment[$0] ?? ""))" }.joined(separator: "\n") : ""
            process.arguments = [interactiveShell ? "-ilc" : "-lc", overrides.isEmpty ? command : overrides + "\n" + command]
            process.currentDirectoryURL = URL(fileURLWithPath: NSString(string: cwd).expandingTildeInPath)
            if !environment.isEmpty { process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new } }
            process.standardOutput = pipe; process.standardError = err
            let stdoutReader = CommandPipeReader(handle: pipe.fileHandleForReading, accumulator: output, onOutput: onOutput, environment: environment)
            let stderrReader = CommandPipeReader(handle: err.fileHandleForReading, accumulator: errorOutput, onOutput: onOutput, environment: environment)
            pipe.fileHandleForReading.readabilityHandler = { _ in stdoutReader.readAvailable() }
            err.fileHandleForReading.readabilityHandler = { _ in stderrReader.readAvailable() }
            process.terminationHandler = { process in
                stdoutReader.finish()
                stderrReader.finish()
                Task { @MainActor in
                    if projectID != nil || requestedStops.contains(trackedID), let group = taskProcessGroups[trackedID], kill(-group, 0) == 0 {
                        // Managed sessions own their process group. A shell that
                        // exits must not leave an invisible background service.
                        terminateGroup(group)
                        let notice = "\n主命令已退出，正在清理同组后台进程。 / Command exited; cleaning up background processes in its group.\n"
                        errorOutput.append(Data(notice.utf8)); onOutput?(notice)
                        try? await Task.sleep(nanoseconds: 1_100_000_000)
                    }
                    let text = CommandSecretFilter.redact(output.text() + errorOutput.text(), environment: environment)
                    taskProcessGroups.removeValue(forKey: trackedID)
                    requestedStops.remove(trackedID)
                    if let projectID { processes[projectID]?.removeAll { $0 === process } }
                    taskProcesses.removeValue(forKey: trackedID)
                    continuation.resume(returning: CommandResult(output: text, status: process.terminationStatus, truncated: output.truncated || errorOutput.truncated))
                }
            }
            do {
                try process.run()
            } catch {
                stdoutReader.finish(); stderrReader.finish()
                continuation.resume(returning: CommandResult(output: error.localizedDescription, status: -1))
                return
            }
            let pid = process.processIdentifier
            if getpgid(pid) == pid, pid != getpgrp() { taskProcessGroups[trackedID] = pid }
            if let timeoutSeconds, timeoutSeconds > 0 {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(min(timeoutSeconds, 3600) * 1_000_000_000))
                    if process.isRunning {
                        let notice = "\n命令超时 / Command timed out.\n"
                        errorOutput.append(Data(notice.utf8)); onOutput?(notice)
                        terminate(process)
                    }
                }
            }
            if let projectID { processes[projectID, default: []].append(process) }
            taskProcesses[trackedID] = process
        }
    }
    private static func terminate(_ process: Process) {
        for (id, tracked) in taskProcesses where tracked === process { requestedStops.insert(id) }
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        let group = getpgid(pid)
        // Foundation launches each Process in its own group on macOS. Never
        // signal a shared group if that invariant changes for a future runtime.
        if group == pid, group != getpgrp() {
            terminateGroup(group)
        } else { process.terminate() }
    }
    private static func terminateGroup(_ group: Int32) {
        guard group > 0, group != getpgrp() else { return }
        kill(-group, SIGTERM)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if kill(-group, 0) == 0 { kill(-group, SIGKILL) }
        }
    }
    static func stop(projectID: UUID) { processes[projectID]?.forEach(terminate); processes.removeValue(forKey: projectID) }
    static func stop(taskID: UUID) { if let process = taskProcesses[taskID] { terminate(process) }; taskProcesses.removeValue(forKey: taskID) }
    static func isRunning(taskID: UUID) -> Bool { taskProcesses[taskID]?.isRunning == true }
    static func hasRunningProcesses(projectID: UUID) -> Bool { processes[projectID]?.contains(where: { $0.isRunning }) == true }
    static var hasRunningCommands: Bool { !taskProcessGroups.isEmpty || processes.values.flatMap { $0 }.contains(where: \.isRunning) || taskProcesses.values.contains(where: \.isRunning) }
    static func stopAll() {
        var seen = Set<Int32>()
        for process in processes.values.flatMap({ $0 }) + Array(taskProcesses.values) {
            if seen.insert(process.processIdentifier).inserted { terminate(process) }
        }
        for group in Set(taskProcessGroups.values) { terminateGroup(group) }
        processes.removeAll(); taskProcesses.removeAll()
    }
}

struct GitStatus { let branch: String; let changes: [GitChange]; let isRepository: Bool; var error: String? = nil; var tracking = GitBranchTracking() }

enum GitAction { case fetch, pull, push, stageAll, unstageAll, stashSave, stashPop, stashApply, stashDrop, cleanPreview }
enum GitFileAction: Equatable { case stage, unstage, discard }
enum GitStashAction { case apply, drop }
enum GitRemoteAction { case add, remove, setURL }
enum DockerAction { case start, stop, restart }
enum GitAdvancedOperation: Equatable { case revert, cherryPick, resetSoft, resetMixed, resetHard, tagCreate, tagDelete, rebaseContinue, rebaseAbort, mergeAbort, mergeContinue, cherryPickContinue, cherryPickAbort, revertContinue, revertAbort, rebaseSkip, cherryPickSkip, revertSkip }

enum GitService {
    static func initialize(at path: String) async -> CommandResult { await CommandRunner.run(command: "git init", cwd: path) }
    static func status(at path: String) async -> GitStatus {
        let result = await CommandRunner.run(command: "LC_ALL=C git status --porcelain=v1 -z --branch --ahead-behind --untracked-files=all", cwd: path, outputLimit: 16 * 1024 * 1024)
        guard result.status == 0 else {
            let repository = await CommandRunner.run(command: "git rev-parse --is-inside-work-tree", cwd: path)
            return GitStatus(branch: "", changes: [], isRepository: repository.status == 0, error: repository.status == 0 ? result.output : nil)
        }
        guard !result.truncated else { return GitStatus(branch: "", changes: [], isRepository: true, error: "Git 更改列表超过 16 MB，未显示不完整状态。请排除构建产物后刷新。 / Git status exceeds 16 MB. Ignore generated files and refresh.") }
        let records = result.output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        guard let branchRecord = records.first else { return GitStatus(branch: "main", changes: [], isRepository: true) }
        let header = parseBranchHeader(branchRecord)
        var changes: [GitChange] = []
        var index = 1
        while index < records.count {
            let record = records[index]
            guard record.count >= 3 else { index += 1; continue }
            let state = String(record.prefix(2))
            var filePath = String(record.dropFirst(3))
            var originalPath: String?
            if state.contains("R") || state.contains("C"), index + 1 < records.count {
                let newPath = filePath
                index += 1
                originalPath = records[index]
                filePath = newPath
            }
            changes.append(GitChange(path: filePath, state: state, originalPath: originalPath))
            index += 1
        }
        return GitStatus(branch: header.branch, changes: changes, isRepository: true, tracking: header.tracking)
    }
    static func branches(at path: String) async -> [String] {
        let result = await CommandRunner.run(command: "git for-each-ref --format='%(refname:strip=2)' refs/heads/", cwd: path)
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\n").map(String.init)
    }
    static func remoteBranches(at path: String) async -> [String] {
        let result = await CommandRunner.run(command: "git for-each-ref --format='%(refname:strip=2)%00%(symref)' refs/remotes/", cwd: path)
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\n").compactMap { record in
            let fields = record.components(separatedBy: "\0")
            guard fields.count == 2, fields[1].isEmpty, !fields[0].hasSuffix("/HEAD") else { return nil }
            return fields[0]
        }
    }
    static func commits(at path: String, skip: Int = 0, limit: Int = 50, allBranches: Bool = false) async -> [GitCommit] {
        let result = await CommandRunner.run(command: "git --no-pager log \(allBranches ? "--all " : "")--topo-order -z --skip=\(max(0, skip)) -n \(max(1, min(limit, 100))) --date=iso-strict --format='%H%x00%s%x00%an%x00%ad%x00%P%x00%D' --", cwd: path)
        guard result.status == 0, !result.truncated else { return [] }
        let fields = result.output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        return stride(from: 0, to: max(0, fields.count - 5), by: 6).map { index in
            GitCommit(hash: fields[index], subject: fields[index + 1], author: fields[index + 2], date: fields[index + 3],
                      parents: fields[index + 4].split(separator: " ").map(String.init),
                      refs: fields[index + 5].components(separatedBy: ", ").filter { !$0.isEmpty })
        }
    }
    static func commitFiles(_ hash: String, at path: String) async -> [String] {
        let result = await CommandRunner.run(command: "git diff-tree --root --diff-merges=first-parent -r --no-commit-id --name-only -z \(Shell.quote(hash)) --", cwd: path)
        guard result.status == 0 else { return [] }
        return Array(Set(result.output.split(separator: "\0").map(String.init))).sorted()
    }
    static func commitDescription(_ hash: String, at path: String) async -> String {
        await CommandRunner.run(command: "git --no-pager show -s --format=fuller \(Shell.quote(hash)) --", cwd: path).output
    }
    static func commitDiff(_ hash: String, file: String, at path: String) async -> String {
        (await CommandRunner.run(command: "git --literal-pathspecs --no-pager show --format= --root --first-parent --no-color --no-ext-diff --no-textconv \(Shell.quote(hash)) -- \(Shell.quote(file))", cwd: path)).previewOutput
    }
    static func tags(at path: String) async -> [String] {
        let result = await CommandRunner.run(command: "git tag --list --sort=-version:refname", cwd: path)
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\n").map(String.init)
    }
    static func stashes(at path: String) async -> [GitStash] {
        let result = await CommandRunner.run(command: "git stash list -z --format='%H%x00%gd%x00%s'", cwd: path)
        guard result.status == 0, !result.truncated else { return [] }
        let fields = result.output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        return stride(from: 0, to: max(0, fields.count - 2), by: 3).map { GitStash(reference: fields[$0 + 1], message: fields[$0 + 2], hash: fields[$0]) }
    }
    static func remotes(at path: String) async -> [GitRemote] {
        let result = await CommandRunner.run(command: "git remote -v", cwd: path)
        var urls: [String: (String, String)] = [:]
        for line in result.output.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "\t") else { continue }
            let name = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            var item = urls[name] ?? ("", "")
            if value.hasSuffix(" (fetch)") { item.0 = String(value.dropLast(8)) }
            else if value.hasSuffix(" (push)") { item.1 = String(value.dropLast(7)) }
            urls[name] = item
        }
        return urls.keys.sorted().map { name in let pair = urls[name] ?? ("", ""); return GitRemote(name: name, fetchURL: pair.0, pushURL: pair.1) }
    }
    static func checkout(branch: String, at path: String) async -> CommandResult {
        if let error = await validateBranchName(branch, at: path) { return error }
        // `checkout` falls back to restoring paths if a branch disappeared.
        // `switch --no-guess` only switches the explicitly selected local branch.
        return await CommandRunner.run(command: "git switch --no-guess -- \(Shell.quote(branch))", cwd: path)
    }
    static func checkoutRemote(_ remoteBranch: String, localName: String, at path: String) async -> CommandResult {
        if let error = await validateBranchName(localName, at: path) { return error }
        let remoteReference = "refs/remotes/" + remoteBranch
        let localReference = "refs/heads/" + localName
        guard !remoteBranch.isEmpty, !remoteBranch.contains("\0"),
              await CommandRunner.run(command: "git check-ref-format \(Shell.quote(remoteReference)) && git show-ref --verify --quiet \(Shell.quote(remoteReference))", cwd: path).status == 0,
              await CommandRunner.run(command: "git symbolic-ref -q \(Shell.quote(remoteReference))", cwd: path).status != 0 else {
            return CommandResult(output: "远程分支无效或已不存在，请先 Fetch 并刷新。 / Remote branch is invalid or missing. Fetch and refresh first.", status: 1)
        }
        let exists = await CommandRunner.run(command: "git show-ref --verify --quiet \(Shell.quote(localReference))", cwd: path).status == 0
        if exists {
            let upstream = await CommandRunner.run(command: "git for-each-ref --format='%(upstream)' \(Shell.quote(localReference))", cwd: path)
            guard upstream.status == 0, !upstream.truncated, upstream.output.trimmingCharacters(in: .whitespacesAndNewlines) == remoteReference else {
                return CommandResult(output: "已有同名本地分支，未跟踪所选远程分支。请切换该本地分支，或新建一个不同名称的分支。 / A local branch with this name tracks a different upstream. Select it explicitly or create a branch with a different name.", status: 1)
            }
            return await CommandRunner.run(command: "git switch --no-guess -- \(Shell.quote(localName))", cwd: path)
        }
        return await CommandRunner.run(command: "git switch --track -c \(Shell.quote(localName)) -- \(Shell.quote(remoteReference))", cwd: path)
    }
    static func createBranch(_ name: String, checkout: Bool, from baseBranch: String? = nil, at path: String) async -> CommandResult {
        if let error = await validateBranchName(name, at: path) { return error }
        var base = ""
        if let baseBranch {
            guard let hash = await commitHash(baseBranch, at: path) else { return CommandResult(output: "起点不是有效提交。 / Starting point is not a valid commit.", status: 1) }
            base = " \(hash)"
        }
        if checkout {
            return await CommandRunner.run(command: "git switch -c \(Shell.quote(name))\(base.isEmpty ? "" : " --" + base)", cwd: path)
        }
        return await CommandRunner.run(command: "git branch -- \(Shell.quote(name))\(base)", cwd: path)
    }
    static func deleteBranch(_ name: String, force: Bool = false, at path: String) async -> CommandResult {
        if let error = await validateBranchName(name, at: path) { return error }
        let flag = force ? "-D" : "-d"
        return await CommandRunner.run(command: "git branch \(flag) -- \(Shell.quote(name))", cwd: path)
    }
    static func merge(_ name: String, at path: String) async -> CommandResult {
        guard await commitHash(name, at: path) != nil else { return CommandResult(output: "合并目标不是有效提交。 / Merge target is not a valid commit.", status: 1) }
        return await CommandRunner.run(command: "git -c core.editor=true merge -- \(Shell.quote(name))", cwd: path)
    }
    static func rebase(_ name: String, at path: String) async -> CommandResult {
        guard await commitHash(name, at: path) != nil else { return CommandResult(output: "变基目标不是有效提交。 / Rebase target is not a valid commit.", status: 1) }
        return await CommandRunner.run(command: "git rebase -- \(Shell.quote(name))", cwd: path)
    }
    static func validateBranchName(_ name: String, at path: String) async -> CommandResult? {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("\0"), name != "HEAD" else {
            return CommandResult(output: "分支名称无效：不能为空、以 - 开头、包含 NUL 或使用保留名称 HEAD。 / Invalid branch name: empty, option-like, NUL-containing or reserved HEAD name.", status: 1)
        }
        let result = await CommandRunner.run(command: "git check-ref-format \(Shell.quote("refs/heads/" + name))", cwd: path)
        return result.status == 0 ? nil : CommandResult(output: "分支名称无效。 / Invalid branch name.\n" + result.output, status: 1)
    }
    static func renameBranch(_ old: String, to new: String, at path: String) async -> CommandResult {
        if let error = await validateBranchName(new, at: path) { return error }
        if let error = await validateBranchName(old, at: path) { return error }
        return await CommandRunner.run(command: "git branch -m -- \(Shell.quote(old)) \(Shell.quote(new))", cwd: path)
    }
    static func reset(_ target: String, mode: String, at path: String) async -> CommandResult {
        guard ["--soft", "--mixed", "--hard"].contains(mode), let hash = await commitHash(target, at: path) else { return CommandResult(output: "无效的提交引用或重置方式。 / Invalid commit reference or reset mode.", status: 1) }
        return await CommandRunner.run(command: "git reset \(mode) \(hash)", cwd: path)
    }
    static func commitHash(_ reference: String, at path: String) async -> String? {
        guard !reference.isEmpty, !reference.hasPrefix("-"), !reference.contains("\0") else { return nil }
        let result = await CommandRunner.run(command: "git rev-parse --verify --end-of-options \(Shell.quote(reference + "^{commit}"))", cwd: path)
        let hash = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, [40, 64].contains(hash.count), hash.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hash
    }
    static func createTag(_ name: String, target: String = "HEAD", message: String = "", at path: String) async -> CommandResult {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("\0"), await CommandRunner.run(command: "git check-ref-format \(Shell.quote("refs/tags/" + name))", cwd: path).status == 0,
              let hash = await commitHash(target, at: path), !message.contains("\0") else { return CommandResult(output: "请填写有效的标签名称和目标提交。 / Enter a valid tag name and target commit.", status: 1) }
        let annotation = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "-a -m \(Shell.quote(message)) "
        return await CommandRunner.run(command: "git tag \(annotation)-- \(Shell.quote(name)) \(hash)", cwd: path)
    }
    static func deleteTag(_ name: String, at path: String) async -> CommandResult { await CommandRunner.run(command: "git tag -d \(Shell.quote(name))", cwd: path) }
    static func rebaseContinue(at path: String) async -> CommandResult { await CommandRunner.run(command: "GIT_EDITOR=true git rebase --continue", cwd: path) }
    static func rebaseAbort(at path: String) async -> CommandResult { await CommandRunner.run(command: "git rebase --abort", cwd: path) }
    static func mergeAbort(at path: String) async -> CommandResult { await CommandRunner.run(command: "git merge --abort", cwd: path) }
    static func diff(_ file: String, at path: String, staged: Bool = false, untracked: Bool = false) async -> String {
        let arguments = untracked ? "--no-index -- /dev/null \(Shell.quote(file))" : "\(staged ? "--cached " : "")-- \(Shell.quote(file))"
        return (await CommandRunner.run(command: "git -c core.safecrlf=false --literal-pathspecs --no-pager diff --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ --no-relative --unified=3 --word-diff=none \(arguments)", cwd: path)).previewOutput
    }
    static func resolve(_ file: String, side: ConflictSide, at path: String) async -> CommandResult {
        let unmerged = await CommandRunner.run(command: "git --literal-pathspecs ls-files -u -z -- \(Shell.quote(file))", cwd: path)
        guard unmerged.status == 0, !unmerged.output.isEmpty else { return CommandResult(output: "此文件已经没有未解决的冲突。 / This file no longer has an unresolved conflict.", status: 1) }
        let stage = side == .ours ? 2 : 3
        let exists = await CommandRunner.run(command: "git cat-file -e \(Shell.quote(":\(stage):\(file)"))", cwd: path).status == 0
        let command = exists ? "git --literal-pathspecs checkout --\(side.rawValue) -- \(Shell.quote(file)) && git --literal-pathspecs add -- \(Shell.quote(file))" : "git --literal-pathspecs rm -- \(Shell.quote(file))"
        return await CommandRunner.run(command: command, cwd: path)
    }
    static func fileAction(_ action: GitFileAction, path: String, at projectPath: String, isUntracked: Bool = false, originalPath: String? = nil) async -> CommandResult {
        let paths = ([path] + (originalPath.map { [$0] } ?? [])).map(Shell.quote).joined(separator: " ")
        switch action {
        case .stage:
            var stagePaths = [path]
            if let originalPath {
                let tracked = await CommandRunner.run(command: "git --literal-pathspecs ls-files --error-unmatch -- \(Shell.quote(originalPath))", cwd: projectPath)
                if tracked.status == 0 { stagePaths.append(originalPath) }
            }
            return await CommandRunner.run(command: "git --literal-pathspecs add -A -- \(stagePaths.map(Shell.quote).joined(separator: " "))", cwd: projectPath)
        case .unstage:
            let hasHead = await CommandRunner.run(command: "git rev-parse --verify HEAD", cwd: projectPath).status == 0
            let command = hasHead ? "git --literal-pathspecs restore --staged -- \(paths)" : "git --literal-pathspecs rm -f --cached -- \(paths)"
            return await CommandRunner.run(command: command, cwd: projectPath)
        case .discard:
            let command = isUntracked ? "git --literal-pathspecs clean -f -- \(Shell.quote(path))" : "git --literal-pathspecs restore --worktree -- \(Shell.quote(path))"
            return await CommandRunner.run(command: command, cwd: projectPath)
        }
    }
    static func stashAction(_ action: GitStashAction, stash: GitStash, restoreIndex: Bool = false, at path: String) async -> CommandResult {
        let current = await stashes(at: path)
        guard current.contains(where: { $0.hash == stash.hash && $0.reference == stash.reference }) else {
            return CommandResult(output: "Stash 列表已改变，请刷新后重试。 / The stash list changed. Refresh and try again.", status: 1)
        }
        switch action {
        case .apply: return await CommandRunner.run(command: "git stash apply \(restoreIndex ? "--index " : "")\(Shell.quote(stash.hash))", cwd: path)
        case .drop: return await CommandRunner.run(command: "git stash drop \(Shell.quote(stash.reference))", cwd: path)
        }
    }
    static func saveStash(message: String, includeUntracked: Bool, keepIndex: Bool, at path: String) async -> CommandResult {
        let flags = (includeUntracked ? "-u " : "") + (keepIndex ? "--keep-index " : "")
        let title = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return await CommandRunner.run(command: "git stash push \(flags)\(title.isEmpty ? "" : "-m " + Shell.quote(title))", cwd: path)
    }
    static func stashDiff(_ stash: GitStash, at path: String) async -> String {
        let result = await CommandRunner.run(command: "git --no-pager stash show -p --include-untracked --no-color --no-ext-diff --no-textconv \(Shell.quote(stash.hash))", cwd: path, outputLimit: 1024 * 1024)
        return result.output + (result.truncated ? "\n… 差异过大，以上仅显示部分内容。 / Large diff: partial preview." : "")
    }
    static func remoteAction(_ action: GitRemoteAction, name: String, url: String, expected: GitRemote? = nil, at path: String) async -> CommandResult {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains(where: { $0.isWhitespace || $0 == "\0" }),
              await CommandRunner.run(command: "git check-ref-format \(Shell.quote("refs/remotes/" + name + "/branch"))", cwd: path).status == 0 else {
            return CommandResult(output: "远程名称无效。 / Invalid remote name.", status: 1)
        }
        if action != .remove, let error = GitRepositoryAddress.validationError(url) { return CommandResult(output: error, status: 1) }
        if let expected {
            let current = await remotes(at: path)
            guard expected.name == name, current.first(where: { $0.name == name }) == expected else {
                return CommandResult(output: "远程配置已改变，请刷新后重新编辑。 / Remote configuration changed. Refresh before editing.", status: 1)
            }
        }
        switch action {
        case .add: return await CommandRunner.run(command: "git remote add -- \(Shell.quote(name)) \(Shell.quote(url))", cwd: path)
        case .remove: return await CommandRunner.run(command: "git remote remove -- \(Shell.quote(name))", cwd: path)
        case .setURL: return await CommandRunner.run(command: "git remote set-url -- \(Shell.quote(name)) \(Shell.quote(url))", cwd: path)
        }
    }
    static func perform(_ action: GitAction, at path: String) async -> CommandResult {
        if action == .unstageAll {
            let conflicts = await CommandRunner.run(command: "git ls-files -u -z", cwd: path)
            if conflicts.status != 0 { return conflicts }
            if !conflicts.output.isEmpty { return CommandResult(output: "请先处理冲突，再取消全部暂存。 / Resolve conflicts before unstaging all files.", status: 1) }
        }
        let command: String
        switch action {
        case .fetch: command = "git fetch --all --prune"
        case .pull: command = "GIT_EDITOR=true git -c core.editor=true pull --no-edit"
        case .push: command = "git push"
        case .stageAll: command = "git add -A"
        case .unstageAll:
            let hasHead = await CommandRunner.run(command: "git rev-parse --verify HEAD", cwd: path).status == 0
            command = hasHead ? "git restore --staged -- ." : "git rm -r -f --cached --ignore-unmatch -- ."
        case .stashSave: command = "git stash push -u"
        case .stashPop: command = "git stash pop"
        case .stashApply: command = "git stash apply"
        case .stashDrop: command = "git stash drop"
        case .cleanPreview: command = "git clean -nd"
        }
        return await CommandRunner.run(command: command, cwd: path)
    }
}

enum ConflictSide: String { case ours, theirs }

enum ProjectCommandDetector {
    private static func manifest(at url: URL) -> [String: Any]? {
        let bytes = FilePreviewReader.readRange(path: url.path, offset: 0, count: 1024 * 1024 + 1)
        guard bytes.count <= 1024 * 1024 else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }

    static func detect(at url: URL) -> [RunConfiguration] {
        var result: [RunConfiguration] = []
        let fm = FileManager.default
        func add(_ name: String, _ command: String) {
            guard !result.contains(where: { $0.name == name }) else { return }
            result.append(RunConfiguration(name: name, command: command, workingDirectory: url.path))
        }
        if let json = manifest(at: url.appendingPathComponent("package.json")), let scripts = json["scripts"] as? [String: Any] {
            let manager: String
            if let packageManager = json["packageManager"] as? String, !packageManager.hasPrefix("@"), let name = packageManager.split(separator: "@").first, ["npm", "pnpm", "yarn", "bun"].contains(String(name)) { manager = String(name) }
            else if fm.fileExists(atPath: url.appendingPathComponent("pnpm-lock.yaml").path) { manager = "pnpm" }
            else if fm.fileExists(atPath: url.appendingPathComponent("yarn.lock").path) { manager = "yarn" }
            else { manager = "npm" }
            for name in scripts.keys.sorted() {
                let command = "\(manager) run \(Shell.quote(name))"
                add("\(manager) \(name)", command)
            }
        }
        if fm.fileExists(atPath: url.appendingPathComponent("Makefile").path) { add("Make", "make") }
        if fm.fileExists(atPath: url.appendingPathComponent("Cargo.toml").path) { add("Cargo run", "cargo run") }
        if fm.fileExists(atPath: url.appendingPathComponent("go.mod").path) { add("Go run", "go run .") }
        if fm.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { add("Swift run", "swift run") }
        if fm.fileExists(atPath: url.appendingPathComponent("pyproject.toml").path) { add("Python package", "python3 -m pip install -e .") }
        if let json = manifest(at: url.appendingPathComponent("composer.json")), let scripts = json["scripts"] as? [String: Any] {
            for name in scripts.keys.sorted() { add("Composer \(name)", "composer run-script \(Shell.quote(name))") }
        }
        if ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"].contains(where: { fm.fileExists(atPath: url.appendingPathComponent($0).path) }) {
            add("Docker Compose up", "docker compose up")
            add("Docker Compose down", "docker compose down")
        }
        if fm.fileExists(atPath: url.appendingPathComponent("manage.py").path) { add("Django server", "python3 manage.py runserver") }
        if fm.fileExists(atPath: url.appendingPathComponent("requirements.txt").path) { add("Python dependencies", "python3 -m pip install -r requirements.txt") }
        if fm.fileExists(atPath: url.appendingPathComponent("pom.xml").path) {
            add("Maven test", "mvn test")
            add("Maven package", "mvn package")
        }
        if fm.fileExists(atPath: url.appendingPathComponent("gradlew").path) {
            add("Gradle test", "./gradlew test")
            add("Gradle run", "./gradlew run")
        } else if fm.fileExists(atPath: url.appendingPathComponent("build.gradle").path) || fm.fileExists(atPath: url.appendingPathComponent("build.gradle.kts").path) {
            add("Gradle test", "gradle test")
            add("Gradle run", "gradle run")
        }
        if fm.fileExists(atPath: url.appendingPathComponent("Gemfile").path) { add("Bundler install", "bundle install") }
        if fm.fileExists(atPath: url.appendingPathComponent("artisan").path) { add("Laravel server", "php artisan serve") }
        if fm.fileExists(atPath: url.appendingPathComponent("mix.exs").path) {
            add("Mix test", "mix test")
            add("Phoenix server", "mix phx.server")
        }
        return result
    }
}

enum EnvironmentDetector {
    static let tools = ["git", "node", "npm", "pnpm", "yarn", "bun", "python3", "pip3", "go", "rustc", "cargo", "swift", "java", "php", "ruby", "bundle", "composer", "mvn", "gradle", "mix", "dotnet", "docker"]
    static func detect() async -> EnvironmentSnapshot {
        // Source the interactive login environment once, rather than launching
        // a fresh shell and loading version managers for every executable.
        let script = """
        for gw_probe_tool in \(tools.map(Shell.quote).joined(separator: " ")); do
            printf '\\036%s\\037' "$gw_probe_tool"
            command -v "$gw_probe_tool" 2>/dev/null
            printf '\\037'
            if [ "$gw_probe_tool" = go ]; then "$gw_probe_tool" version 2>/dev/null | /usr/bin/head -1; else "$gw_probe_tool" --version 2>/dev/null | /usr/bin/head -1; fi
            printf '\\036'
        done
        """
        let result = await CommandRunner.run(command: script, cwd: FileManager.default.homeDirectoryForCurrentUser.path, interactiveShell: true, timeoutSeconds: 25)
        guard result.status == 0, !result.truncated else { return EnvironmentSnapshot(items: [], error: "开发环境检测未完成 / Environment detection failed.\n" + String(result.output.suffix(2000))) }
        return EnvironmentSnapshot(items: parse(result.output), error: nil)
    }
    static func parse(_ output: String) -> [EnvironmentItem] {
        var found: [String: EnvironmentItem] = [:]
        for record in output.components(separatedBy: "\u{001e}") {
            let fields = record.components(separatedBy: "\u{001f}")
            guard fields.count == 3, tools.contains(fields[0]) else { continue }
            let path = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let version = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
            found[fields[0]] = EnvironmentItem(name: fields[0], path: path, version: version.isEmpty ? nil : version, available: !path.isEmpty)
        }
        return tools.map { found[$0] ?? EnvironmentItem(name: $0, path: "", version: nil, available: false) }
    }
}



enum Shell { static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" } }

enum FileTreeLoader {
    private static let maxDepth = 24
    static let maxEntriesPerDirectory = 5_000

    /// Loads one directory level. Descendants are intentionally loaded only when a row is expanded.
    static func load(url: URL, depth: Int = 0, recursive: Bool = false) -> [FileItem] {
        guard depth <= maxDepth, let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsSubdirectoryDescendants]) else { return [] }
        var entries: [(url: URL, directory: Bool)] = []
        for case let item as URL in enumerator {
            if Task.isCancelled { break }
            guard ![".DS_Store", "node_modules", ".git", ".build", ".swiftpm", "Pods", "target"].contains(item.lastPathComponent) else { continue }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            entries.append((item, values?.isDirectory == true && values?.isSymbolicLink != true))
            if entries.count >= maxEntriesPerDirectory { break }
        }
        return entries.sorted { first, second in
            if first.directory != second.directory { return first.directory }
            return first.url.lastPathComponent.localizedStandardCompare(second.url.lastPathComponent) == .orderedAscending
        }.map { entry in
            FileItem(name: entry.url.lastPathComponent, icon: entry.directory ? "folder.fill" : icon(for: entry.url.pathExtension),
                     children: entry.directory && recursive ? load(url: entry.url, depth: depth + 1, recursive: true) : [], path: entry.url.path, isDirectory: entry.directory)
        }
    }

    /// Finds a reasonable initial preview target without retaining a recursive
    /// tree. Each level is loaded, inspected, and released before descending.
    /// This keeps startup memory proportional to the current path in very large
    /// repositories.
    static func firstFileURL(url: URL, depth: Int = 0) -> URL? {
        guard depth <= maxDepth, !Task.isCancelled else { return nil }
        for item in load(url: url, depth: depth) {
            if Task.isCancelled { return nil }
            if !item.isDirectory { return URL(fileURLWithPath: item.path) }
            if let result = firstFileURL(url: URL(fileURLWithPath: item.path), depth: depth + 1) {
                return result
            }
        }
        return nil
    }

    static func search(url: URL, query: String, limit: Int = 200) -> [FileItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return [] }
        let excluded = [".git", "node_modules", ".build", ".swiftpm", "Pods", "target"]
        let rootPath = url.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { return [] }
        var results: [FileItem] = []
        for case let fileURL as URL in enumerator {
            if Task.isCancelled { break }
            let name = fileURL.lastPathComponent
            if excluded.contains(name) {
                if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                continue
            }
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory != true, values?.isSymbolicLink != true else { continue }
            let filePath = fileURL.standardizedFileURL.path
            let relativePath = filePath.hasPrefix(rootPath + "/") ? String(filePath.dropFirst(rootPath.count + 1)) : fileURL.lastPathComponent
            if name.lowercased().contains(normalizedQuery) || relativePath.lowercased().contains(normalizedQuery) {
                results.append(FileItem(name: relativePath, icon: icon(for: fileURL.pathExtension), children: [], path: fileURL.path, isDirectory: false))
                if results.count >= limit { break }
            }
        }
        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func icon(for ext: String) -> String { switch ext.lowercased() { case "swift": "swift"; case "js", "ts", "vue", "jsx", "tsx": "curlybraces"; case "md": "doc.richtext"; case "json", "yaml", "yml": "doc.text"; default: "doc" } }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case chinese = "中文", english = "English"
    var id: String { rawValue }
}

enum Copy {
    static func t(_ zh: String, _ en: String, language: AppLanguage) -> String { language == .chinese ? zh : en }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }
    var colorScheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
    @MainActor var isDark: Bool {
        if self == .dark { return true }
        if self == .light { return false }
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

enum BackgroundStyle: Equatable {
    case aurora, plain, image(URL)
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview = "Overview", changes = "Changes", history = "History", commands = "Commands"
    var id: String { rawValue }
    var icon: String {
        switch self { case .overview: "square.grid.2x2"; case .changes: "arrow.triangle.branch"; case .history: "clock.arrow.circlepath"; case .commands: "terminal" }
    }
}

enum TopPanel: String, CaseIterable, Identifiable {
    case files, git
    var id: String { rawValue }
}

enum BottomTool: String, CaseIterable, Identifiable {
    case processes, services, console, gitTree
    var id: String { rawValue }
    var icon: String {
        switch self { case .processes: "play.circle"; case .services: "shippingbox"; case .console: "terminal"; case .gitTree: "point.3.connected.trianglepath.dotted" }
    }
}

struct BottomToolFocusRequest: Equatable {
    let id = UUID()
    let tool: BottomTool
}

enum GitPromptKind: String, Identifiable {
    case revert, cherryPick, resetSoft, resetMixed, resetHard, tagCreate, tagDelete
    var id: String { rawValue }
    var operation: GitAdvancedOperation {
        switch self { case .revert: .revert; case .cherryPick: .cherryPick; case .resetSoft: .resetSoft; case .resetMixed: .resetMixed; case .resetHard: .resetHard; case .tagCreate: .tagCreate; case .tagDelete: .tagDelete }
    }
}

struct FileItem: Identifiable {
    var id: String { path.isEmpty ? name : path }
    let name: String
    let icon: String
    let children: [FileItem]
    let path: String
    let isDirectory: Bool
    init(name: String, icon: String, children: [FileItem], path: String = "", isDirectory: Bool? = nil) {
        self.name = name; self.icon = icon; self.children = children; self.path = path; self.isDirectory = isDirectory ?? !children.isEmpty
    }
}

enum SplitAxis { case vertical, horizontal }

struct SplitDivider: NSViewRepresentable {
    let axis: SplitAxis
    @Binding var dimension: CGFloat
    let range: ClosedRange<CGFloat>
    var inverted = false
    var reset: (() -> Void)? = nil
    var commit: (() -> Void)? = nil

    func makeNSView(context: Context) -> SplitDividerView { SplitDividerView() }
    func updateNSView(_ view: SplitDividerView, context: Context) {
        view.axis = axis; view.dimension = dimension; view.range = range; view.inverted = inverted
        view.change = { dimension = $0 }; view.reset = reset; view.commit = commit
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityLabel(axis == .vertical ? "调整左右分栏 / Resize columns" : "调整上下分栏 / Resize rows")
        view.setAccessibilityValue(Int(dimension))
        view.toolTip = "拖动调整，双击恢复默认 / Drag to resize; double-click to reset"
        view.window?.invalidateCursorRects(for: view)
        view.needsDisplay = true
    }
}

final class SplitDividerView: NSView {
    var axis: SplitAxis = .vertical
    var dimension: CGFloat = 0
    var range: ClosedRange<CGFloat> = 0...0
    var inverted = false
    var change: ((CGFloat) -> Void)?
    var reset: (() -> Void)?
    var commit: (() -> Void)?
    private var start: (point: NSPoint, dimension: CGFloat)?
    private var hovering = false
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 24 : 4
        let direction: CGFloat
        switch (axis, event.keyCode) {
        case (.vertical, 123), (.horizontal, 125): direction = -1
        case (.vertical, 124), (.horizontal, 126): direction = 1
        default: super.keyDown(with: event); return
        }
        adjust(step * direction * (inverted ? -1 : 1))
    }

    override var intrinsicContentSize: NSSize {
        axis == .vertical ? NSSize(width: SplitSizing.divider, height: NSView.noIntrinsicMetric) : NSSize(width: NSView.noIntrinsicMetric, height: SplitSizing.divider)
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .vertical ? .resizeLeftRight : .resizeUpDown)
    }
    override func draw(_ dirtyRect: NSRect) {
        (hovering || window?.firstResponder === self ? NSColor.controlAccentColor.withAlphaComponent(0.10) : NSColor.clear).setFill()
        bounds.fill()
        guard hovering || window?.firstResponder === self else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.42).setFill()
        let handle = axis == .vertical
            ? NSRect(x: bounds.midX - 1, y: max(8, bounds.midY - 14), width: 2, height: 28)
            : NSRect(x: max(8, bounds.midX - 14), y: bounds.midY - 1, width: 28, height: 2)
        NSBezierPath(roundedRect: handle, xRadius: 1, yRadius: 1).fill()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { start = nil; reset?(); return }
        start = (event.locationInWindow, dimension)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        // AppKit window coordinates point up. A positive vertical delta grows
        // a bottom pane; a horizontal delta grows a left pane.
        let delta = (axis == .vertical ? event.locationInWindow.x - start.point.x : event.locationInWindow.y - start.point.y) * (inverted ? -1 : 1)
        let value = SplitSizing.fitted(start.dimension + delta, to: range)
        dimension = value; change?(value)
    }
    override func mouseUp(with event: NSEvent) { if start != nil { start = nil; commit?() } }
    override func accessibilityPerformIncrement() -> Bool { adjust(24); return true }
    override func accessibilityPerformDecrement() -> Bool { adjust(-24); return true }
    private func adjust(_ delta: CGFloat) {
        let value = SplitSizing.fitted(dimension + delta, to: range)
        dimension = value; change?(value); commit?()
    }
}

struct FileTree: View {
    let items: [FileItem]
    @ObservedObject var model: WorkbenchModel
    let search: String
    @Binding var expandedItems: Set<String>
    @State private var searchResults: [FileItem] = []
    @State private var completedQuery = ""
    @State private var completedProjectID: UUID?
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var visibleItems: [FileItem] { query.isEmpty ? items : (completedQuery == query && completedProjectID == model.selectedProjectID ? searchResults : []) }

    var body: some View {
        VStack(spacing: 0) {
        NativeFileTree(items: visibleItems,
                       model: model, search: search, expandedItems: $expandedItems)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .overlay {
                if visibleItems.isEmpty {
                    VStack(spacing: 10) {
                        if (!query.isEmpty && (completedQuery != query || completedProjectID != model.selectedProjectID)) || (query.isEmpty && model.isLoading) {
                            ProgressView().controlSize(.small)
                            Text(Copy.t("正在读取…", "Loading…", language: model.language))
                        } else {
                            Image(systemName: query.isEmpty ? "folder" : "magnifyingglass")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(.tertiary)
                            Text(Copy.t(query.isEmpty ? "目录为空" : "没有匹配的文件", query.isEmpty ? "This folder is empty" : "No matching files", language: model.language))
                                .fontWeight(.medium)
                            if query.isEmpty {
                                Text(Copy.t("可在终端创建文件，或从左上角打开其他项目", "Create a file in Terminal, or open another project from the top left", language: model.language))
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.tertiary)
                                    .font(.system(size: 10))
                                    .frame(maxWidth: 190)
                            }
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .allowsHitTesting(false)
                }
            }
        if !query.isEmpty && searchResults.count >= 200 {
            Text(Copy.t("最多显示 200 个结果，请缩小筛选范围", "Up to 200 results; refine your filter", language: model.language))
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(8)
        }
        }
            .task(id: (model.selectedProjectID?.uuidString ?? "") + search + model.fileTreeRevision.uuidString) {
                let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty, let project = model.selectedProject else { searchResults = []; completedQuery = ""; return }
                completedQuery = ""
                searchResults = []
                // Avoid starting a disk walk for every intermediate keystroke.
                // Cancellation keeps the latest query responsive while the
                // short delay prevents rapid typing from churning enumerators.
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, model.selectedProjectID == project.id else { return }
                let worker = Task.detached(priority: .utility) { FileTreeLoader.search(url: URL(fileURLWithPath: project.path), query: query) }
                let results = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, model.selectedProjectID == project.id else { return }
                searchResults = results
                completedQuery = query
                completedProjectID = project.id
            }
    }
}


struct EmptyWorkspaceView: View {
    @ObservedObject var model: WorkbenchModel
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                        .frame(width: 64, height: 64)
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Color.accentColor)
                }
                Text(Copy.t("打开一个项目开始", "Open a project to get started", language: model.language))
                    .font(.system(size: 17, weight: .semibold))
                Text(Copy.t("项目文件、Git 和运行命令会显示在这里", "Files, Git, and run commands will appear here", language: model.language))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button(Copy.t("打开项目", "Open Project", language: model.language)) { model.addProject() }
                        .buttonStyle(.borderedProminent)
                    Button(Copy.t("克隆仓库", "Clone Repository", language: model.language)) { model.showCloneSheet = true }
                        .buttonStyle(.bordered)
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkbenchChrome.editor)
    }
}

struct SyntaxLine: View {
    let text: String
    let language: String
    var search: String = ""
    var body: some View { Text(AttributedString(SyntaxHighlighter.attributed(text, language: language, search: search))).font(.system(size: 13, design: .monospaced)) }
}

struct DiffPreview: View {
    let content: String
    var body: some View {
        GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(PreviewLinePolicy.lines(in: content).enumerated()), id: \.offset) { _, line in
                        let added = line.hasPrefix("+") && !line.hasPrefix("+++")
                        let removed = line.hasPrefix("-") && !line.hasPrefix("---")
                        Text(line.isEmpty ? " " : line).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(added ? Color.green : removed ? Color.red : line.hasPrefix("@@") ? Color.blue : Color.primary)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(.horizontal, 12).padding(.vertical, 2)
                            .frame(minWidth: geometry.size.width, alignment: .leading)
                            .background(added ? Color.green.opacity(0.07) : removed ? Color.red.opacity(0.07) : Color.clear)
                    }
                }.padding(.vertical, 8).textSelection(.enabled)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
            }
        }.background(Color(nsColor: .textBackgroundColor))
    }
}

struct RunPanel: View {
    @ObservedObject var model: WorkbenchModel
    var body: some View { VStack(alignment: .leading, spacing: 9) { HStack { Label(Copy.t("运行命令", "RUN COMMAND", language: model.language), systemImage: "terminal").font(.system(size: 10, weight: .bold, design: .default)).tracking(1); Spacer(); Text(Copy.t("环境已就绪", "Environment ready", language: model.language)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.green) }; HStack { TextField(Copy.t("输入命令", "command", language: model.language), text: $model.commandText).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).padding(9).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7)); Button { model.runCommand() } label: { Image(systemName: "play.fill") }.buttonStyle(.borderedProminent).controlSize(.small); Button { model.stopCommand() } label: { Image(systemName: "stop.fill") }.buttonStyle(.bordered).controlSize(.small) }; Text(model.commandOutput).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3) }.padding(16).frame(height: 150, alignment: .topLeading).background(.thinMaterial) }
}

struct BranchSheet: View {
    @ObservedObject var model: WorkbenchModel
    var body: some View { GitBranchEditor(model: model, mode: .create) }
}

struct RenameBranchSheet: View {
    @ObservedObject var model: WorkbenchModel
    var body: some View { GitBranchEditor(model: model, mode: .rename(model.gitBranch)) }
}

struct WorkbenchCommands: Commands {
    @ObservedObject var model: WorkbenchModel
    var body: some Commands {
        CommandGroup(replacing: .appTermination) {
            Button(Copy.t("退出 CodeFlight", "Quit CodeFlight", language: model.language)) { model.requestApplicationQuit() }
                .keyboardShortcut("q", modifiers: .command)
        }
        CommandGroup(replacing: .appSettings) {
            Button(Copy.t("设置…", "Settings…", language: model.language)) { model.showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button(Copy.t("打开项目…", "Open Project…", language: model.language)) { model.addProject() }.keyboardShortcut("o", modifiers: .command)
            Button(Copy.t("克隆仓库…", "Clone Repository…", language: model.language)) { model.showCloneSheet = true }
            Button(Copy.t("关闭当前文件", "Close File", language: model.language)) { model.closePreview() }.keyboardShortcut("w", modifiers: .command).disabled(model.selectedFile.isEmpty)
            Button(Copy.t("关闭当前项目", "Close Project", language: model.language)) { if let id = model.selectedProjectID { model.closeProject(id) } }.keyboardShortcut("w", modifiers: [.command, .shift]).disabled(model.selectedProjectID == nil)
        }
        CommandMenu(Copy.t("工作台", "Workbench", language: model.language)) {
            Button(Copy.t("命令面板", "Command Palette", language: model.language)) { model.showCommandPalette = true }.keyboardShortcut("k", modifiers: [.command])
            Button(Copy.t("项目导航", "Project Navigator", language: model.language)) { model.fileNavigatorFocusRequest = UUID() }
                .keyboardShortcut("1", modifiers: .command)
            Button(Copy.t("Git 更改", "Git Changes", language: model.language)) { model.gitNavigatorFocusRequest = UUID() }
                .keyboardShortcut("0", modifiers: .command)
            Button(Copy.t("快速打开文件", "Go to File", language: model.language)) { model.fileSearchFocusRequest = UUID() }
                .keyboardShortcut("p", modifiers: .command)
            Button(Copy.t("聚焦终端", "Focus Terminal", language: model.language)) { model.focusTerminal() }
                .keyboardShortcut("2", modifiers: .command).disabled(model.selectedProjectID == nil)
            Button(Copy.t("新建终端会话", "New Terminal Session", language: model.language)) { model.focusTerminal(newSession: true) }
                .keyboardShortcut("t", modifiers: [.command, .option]).disabled(model.selectedProjectID == nil)
            Button(Copy.t("运行进程", "Processes", language: model.language)) { model.focusBottomTool(.processes) }
                .keyboardShortcut("4", modifiers: .command).disabled(model.selectedProjectID == nil)
            Button(Copy.t("服务与 Docker", "Services & Docker", language: model.language)) { model.focusBottomTool(.services) }
                .keyboardShortcut("8", modifiers: .command).disabled(model.selectedProjectID == nil)
            Button(Copy.t("Git 树", "Git Tree", language: model.language)) { model.focusBottomTool(.gitTree) }
                .keyboardShortcut("9", modifiers: .command).disabled(model.selectedProjectID == nil)
            Button(Copy.t("显示／隐藏底部工具窗口", "Show/Hide Tool Window", language: model.language)) { model.toggleBottomTool() }
                .keyboardShortcut("j", modifiers: .command).disabled(model.selectedProjectID == nil)
            Divider()
            if !model.projects.isEmpty {
                Divider()
                ForEach(Array(model.projects.prefix(9).enumerated()), id: \.element.id) { index, project in
                    Button(Copy.t("切换到项目 \(index + 1)：\(project.name)", "Switch to Project \(index + 1): \(project.name)", language: model.language)) { model.selectProject(project) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                }
                Button(Copy.t("下一个项目", "Next Project", language: model.language)) { model.selectAdjacentProject(offset: 1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button(Copy.t("上一个项目", "Previous Project", language: model.language)) { model.selectAdjacentProject(offset: -1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            }
            Divider()
            Button(Copy.t("运行／重新运行", "Run / Rerun", language: model.language)) { model.runSelectedConfiguration() }.keyboardShortcut("r", modifiers: [.command]).disabled(model.selectedProjectID == nil)
            Button(Copy.t("停止当前项目进程", "Stop project processes", language: model.language)) { model.stopCommand() }.keyboardShortcut(".", modifiers: [.command]).disabled(model.selectedProject?.isRunning != true)
            Divider()
            Menu(Copy.t("主题", "Theme", language: model.language)) {
                Button {
                    model.theme = .system
                    model.persistPreferences()
                } label: {
                    themeMenuLabel(Copy.t("跟随系统", "System", language: model.language), selected: model.theme == .system)
                }
                Button {
                    model.theme = .light
                    model.persistPreferences()
                } label: {
                    themeMenuLabel(Copy.t("浅色", "Light", language: model.language), selected: model.theme == .light)
                }
                Button {
                    model.theme = .dark
                    model.persistPreferences()
                } label: {
                    themeMenuLabel(Copy.t("深色", "Dark", language: model.language), selected: model.theme == .dark)
                }
                Divider()
                Button(Copy.t("切换浅色／深色", "Toggle Light / Dark", language: model.language)) {
                    model.theme = model.theme == .dark ? .light : .dark
                    model.persistPreferences()
                }.keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
        CommandMenu(Copy.t("编辑器", "Editor", language: model.language)) {
            Button(Copy.t("放大字号", "Increase Font Size", language: model.language)) { model.adjustEditorFontSize(by: 1) }
                .keyboardShortcut("+", modifiers: .command).disabled(model.selectedFile.isEmpty)
            Button(Copy.t("缩小字号", "Decrease Font Size", language: model.language)) { model.adjustEditorFontSize(by: -1) }
                .keyboardShortcut("-", modifiers: .command).disabled(model.selectedFile.isEmpty)
            Button(Copy.t("恢复默认字号", "Reset Font Size", language: model.language)) { model.resetEditorFontSize() }
                .keyboardShortcut("0", modifiers: [.command, .option]).disabled(model.selectedFile.isEmpty)
            Text(Copy.t("当前字号：\(Int(model.editorFontSize)) pt", "Current size: \(Int(model.editorFontSize)) pt", language: model.language))
        }
    }

    private func themeMenuLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 24)
            if selected { Image(systemName: "checkmark") }
        }
    }
}

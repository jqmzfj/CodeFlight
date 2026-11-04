import SwiftUI
import AppKit

extension WorkbenchModel {
    /// Invalidate both deferred launches and reruns before the app drains its
    /// process groups. Otherwise a queued rerun can start during Quit.
    func prepareForTermination() {
        isTerminating = true
        restartingTaskIDs.removeAll()
        for project in projects {
            for task in runningTasks[project.id, default: []] where task.isRunning {
                stopTask(task.id, projectID: project.id)
            }
        }
    }

    var selectedRunTask: RunningTask? {
        guard let id = selectedProjectID, let config = selectedRunConfiguration else { return nil }
        return runningTasks[id]?.last { $0.configurationID == config.id && ($0.isRunning || restartingTaskIDs.contains($0.id)) }
    }

    func runSelectedConfiguration() {
        guard selectedProject != nil else { return }
        guard selectedRunConfiguration != nil else { showRunSettings = true; return }
        if let task = selectedRunTask { rerunTask(task.id) }
        else { runCommand() }
    }

    func rerunTask(_ taskID: UUID) {
        guard !isTerminating, let projectID = selectedProjectID,
              let task = runningTasks[projectID]?.first(where: { $0.id == taskID }),
              !task.isStopping, !restartingTaskIDs.contains(taskID) else { return }
        if task.isRunning { stopTask(taskID, projectID: projectID) }
        restartingTaskIDs.insert(taskID)
        Task { [weak self] in
            // Give the owned process group time to terminate before reusing ports.
            if task.isRunning { try? await Task.sleep(nanoseconds: 1_200_000_000) }
            for _ in 0..<80 {
                guard let self else { return }
                if self.runningTasks[projectID]?.first(where: { $0.id == taskID })?.isRunning != true { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let self else { return }
            defer { self.restartingTaskIDs.remove(taskID) }
            guard self.restartingTaskIDs.contains(taskID), self.projects.contains(where: { $0.id == projectID }),
                  let old = self.runningTasks[projectID]?.first(where: { $0.id == taskID }) else { return }
            guard !old.isRunning else {
                self.errorMessage = Copy.t("进程尚未退出，请稍后重试。", "The process has not exited. Try again shortly.", language: self.language); return
            }
            self.runCommand(command: task.command, workingDirectory: task.workingDirectory,
                            environment: task.environment, projectID: projectID,
                            configurationID: task.configurationID, name: task.name)
        }
    }

    func selectTask(_ taskID: UUID) {
        guard let id = selectedProjectID, let task = runningTasks[id]?.first(where: { $0.id == taskID }) else { return }
        selectedTaskIDs[id] = taskID
        commandOutput = task.output
    }

    func clearTaskOutput(_ taskID: UUID) {
        guard let id = selectedProjectID, let index = runningTasks[id]?.firstIndex(where: { $0.id == taskID }) else { return }
        runOutputStreams[taskID]?.clear()
        runningTasks[id]?[index].output = ""
        runningTasks[id]?[index].logWasTruncated = false
        runningTasks[id]?[index].logWasCleared = true
        if selectedTaskIDs[id] == taskID { commandOutput = "" }
    }

    func removeFinishedTask(_ taskID: UUID) {
        guard let id = selectedProjectID,
              runningTasks[id]?.contains(where: { $0.id == taskID && !$0.isRunning }) == true,
              !restartingTaskIDs.contains(taskID) else { return }
        runningTasks[id]?.removeAll { $0.id == taskID }
        if selectedTaskIDs[id] == taskID {
            selectedTaskIDs[id] = runningTasks[id]?.last?.id
        }
    }
}

struct RunToolbar: View {
    @ObservedObject var model: WorkbenchModel
    private var active: [(Project, RunningTask)] {
        model.projects.flatMap { project in
            model.runningTasks[project.id, default: []].filter { $0.isRunning || model.restartingTaskIDs.contains($0.id) }.map { (project, $0) }
        }
    }
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    var body: some View {
        let task = model.selectedRunTask
        Button { model.runSelectedConfiguration() } label: {
            Label(task == nil ? text("运行", "Run") : text("重新运行", "Rerun"), systemImage: task == nil ? "play.fill" : "arrow.clockwise")
        }.buttonStyle(.borderless).labelStyle(.iconOnly).controlSize(.regular)
            .disabled(model.selectedProjectID == nil || task?.isStopping == true || task.map { model.restartingTaskIDs.contains($0.id) } == true)
            .help(text("运行当前配置 ⌘R", "Run current configuration ⌘R"))
        if active.count > 1 {
            Menu {
                ForEach(active, id: \.1.id) { project, task in
                    Button(text("停止 ", "Stop ") + project.name + " · " + task.displayName) { model.stopTask(task.id, projectID: project.id) }
                        .disabled(task.isStopping && !model.restartingTaskIDs.contains(task.id))
                }
                Divider()
                Button(text("停止全部进程", "Stop all processes")) {
                    for (project, task) in active { model.stopTask(task.id, projectID: project.id) }
                }
            } label: {
                Label("\(active.count)", systemImage: "stop.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.trailing, 6)
            }
            .menuStyle(.borderlessButton).fixedSize().help(text("选择要停止的进程", "Choose a process to stop"))
        } else {
            Button {
                if let (project, task) = active.first { model.stopTask(task.id, projectID: project.id) }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(active.isEmpty ? Color.secondary : .red)
                    .padding(.trailing, 6)
            }
            .buttonStyle(.borderless).controlSize(.regular).disabled(active.isEmpty || (active.first.map { $0.1.isStopping && !model.restartingTaskIDs.contains($0.1.id) } ?? false))
            .help(active.first.map { text("停止 ", "Stop ") + $0.0.name + " · " + $0.1.displayName } ?? text("没有运行中的进程", "No running processes"))
        }
    }
}

struct ProcessTool: View {
    @ObservedObject var model: WorkbenchModel
    var onHide: (() -> Void)? = nil
    @State private var search = ""
    @State private var followsOutput = true
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var tasks: [RunningTask] { model.selectedProjectID.flatMap { model.runningTasks[$0] } ?? [] }
    private var selected: RunningTask? {
        let id = model.selectedProjectID.flatMap { model.selectedTaskIDs[$0] }
        return tasks.first { $0.id == id } ?? tasks.last
    }
    var body: some View {
        WorkbenchSplit("process.sessions", initial: 240, minimum: 170, otherMinimum: 280) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(text("运行进程", "Processes")).font(.system(size: 11, weight: .semibold))
                    if !tasks.isEmpty {
                        Text("\(tasks.count)").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.showRunSettings = true } label: { Image(systemName: "gearshape") }
                        .help(text("编辑运行配置", "Edit run configurations"))
                    Menu {
                        ForEach(model.selectedProject?.runConfigurations ?? []) { config in
                            Button(config.name) { model.selectRunConfiguration(config); model.runCommand() }
                        }
                        Divider()
                        Button(text("新建运行配置…", "New configuration…")) { model.showRunSettings = true }
                    } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize()
                        .help(text("选择或新建配置运行", "Select or create configuration to run"))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: WorkbenchChrome.rowHeight)
                .background(WorkbenchChrome.raised)

                Rectangle().fill(WorkbenchChrome.quietSeparator).frame(height: 1)

                if tasks.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "terminal")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                        Text(text("暂无运行中的会话", "No active sessions"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(text("可通过上方“+”或快捷命令启动", "Start via ‘+’ above or command below"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 12)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(tasks.reversed()) { task in
                                Button { model.selectTask(task.id); search = "" } label: {
                                    HStack(spacing: 8) {
                                        Circle().fill(task.isRunning ? (task.isStopping ? .orange : .green) : (task.exitCode == 0 ? .blue : task.wasStopped ? .secondary : .orange)).frame(width: 6, height: 6)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(task.displayName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                            Text(task.statusText(model.language)).font(.system(size: 10)).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                        if model.restartingTaskIDs.contains(task.id) { ProgressView().controlSize(.mini) }
                                    }.padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                                        .background(selected?.id == task.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                }.buttonStyle(.plain).help(task.command)
                                    .contextMenu {
                                        Button(text("重新运行", "Rerun")) { model.rerunTask(task.id) }.disabled(task.isStopping || model.restartingTaskIDs.contains(task.id))
                                        if task.isRunning { Button(text("停止", "Stop")) { model.stopTask(task.id) }.disabled(task.isStopping && !model.restartingTaskIDs.contains(task.id)) }
                                        else { Button(text("关闭会话", "Close session")) { model.removeFinishedTask(task.id) }.disabled(model.restartingTaskIDs.contains(task.id)) }
                                    }
                            }
                        }.padding(4)
                    }
                }

                Rectangle().fill(WorkbenchChrome.quietSeparator).frame(height: 1)

                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.tertiary)
                    TextField(text("输入快捷命令，回车运行", "Command; Return to run"), text: $model.commandText)
                        .textFieldStyle(.plain).font(.system(size: 10.5, design: .monospaced))
                        .onSubmit { model.runCommand(command: model.commandText) }
                    if !model.commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button { model.runCommand(command: model.commandText) } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8.5))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.selectedProjectID == nil)
                        .help(text("运行快捷命令", "Run command"))
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(WorkbenchChrome.raised)
            }
        } second: {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    if let task = selected {
                        Button { model.rerunTask(task.id) } label: { Image(systemName: "arrow.clockwise") }
                            .disabled(task.isStopping || model.restartingTaskIDs.contains(task.id)).help(text("重新运行此会话", "Rerun session"))
                        Button { model.stopTask(task.id) } label: { Image(systemName: "stop.fill").foregroundStyle(task.isRunning ? Color.red : .secondary) }
                            .disabled((!task.isRunning && !model.restartingTaskIDs.contains(task.id)) || (task.isStopping && !model.restartingTaskIDs.contains(task.id))).help(text("停止此会话", "Stop session"))
                        Text(task.displayName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(task.statusText(model.language) + " · " + "\(Int((task.endedAt ?? context.date).timeIntervalSince(task.startedAt)))s")
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(task.output, forType: .string) } label: { Image(systemName: "doc.on.doc") }.help(text("复制日志", "Copy log"))
                        Button { model.clearTaskOutput(task.id) } label: { Image(systemName: "trash") }.help(text("清空日志", "Clear log"))
                        Button { model.removeFinishedTask(task.id) } label: { Image(systemName: "xmark") }.disabled(task.isRunning || model.restartingTaskIDs.contains(task.id)).help(text("关闭已结束会话", "Close finished session"))
                    } else {
                        Text(text("日志控制台", "Console")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    if let onHide {
                        Divider().frame(height: 12)
                        Button(action: onHide) {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(text("隐藏工具窗口", "Hide tool window"))
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: WorkbenchChrome.rowHeight)
                .background(WorkbenchChrome.raised)

                Rectangle().fill(WorkbenchChrome.quietSeparator).frame(height: 1)

                if let task = selected {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField(text("筛选日志", "Filter log"), text: $search).textFieldStyle(.plain)
                            if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                            Toggle(text("跟随输出", "Follow output"), isOn: $followsOutput).toggleStyle(.checkbox)
                        }.font(.system(size: 10)).padding(.horizontal, 10).padding(.vertical, 5)
                        if task.logWasTruncated {
                            Text(text("仅保留最近 12,000 个字符，更早日志已丢弃以控制内存。", "Showing the latest 12,000 characters; older output was discarded to limit memory."))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 4)
                        }
                        RunLogView(output: search.isEmpty ? task.output : task.output.components(separatedBy: .newlines).filter { $0.localizedCaseInsensitiveContains(search) }.joined(separator: "\n"),
                                   followsOutput: followsOutput, sessionID: task.id)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "play.rectangle").font(.system(size: 24)).foregroundStyle(.tertiary)
                        Text(text("运行配置或快捷命令后，在这里查看独立日志", "Run a configuration or command to view its log here")).font(.caption).foregroundStyle(.secondary)
                        Button(text("编辑运行配置…", "Edit configurations…")) { model.showRunSettings = true }.disabled(model.selectedProjectID == nil)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.onChange(of: model.selectedProjectID) { _ in search = "" }
    }
}

extension RunningTask {
    func statusText(_ language: AppLanguage) -> String {
        if isStopping { return Copy.t("正在停止…", "Stopping…", language: language) }
        if isRunning { return Copy.t("运行中", "Running", language: language) }
        if wasStopped { return Copy.t("已停止", "Stopped", language: language) }
        return exitCode == 0 ? Copy.t("已完成", "Completed", language: language) : Copy.t("失败，退出码 ", "Failed, exit code ", language: language) + (exitCode.map(String.init) ?? "—")
    }
}

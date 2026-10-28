import SwiftUI
import AppKit

struct RunCommandSettings: View {
    @ObservedObject var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @State private var configurations: [RunConfiguration] = []
    @State private var selection: UUID?
    @FocusState private var focusedName: UUID?
    @State private var environments: [UUID: String] = [:]
    @State private var projectID: UUID?
    @State private var projectPath = ""
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var selectedIndex: Int? { configurations.firstIndex { $0.id == selection } }
    @State private var originalConfigurations: [RunConfiguration] = []
    @State private var originalEnvironments: [UUID: String] = [:]
    @State private var originalData: Data?
    @State private var localError: String?
    @State private var loadError: String?
    @State private var detected: [RunConfiguration] = []
    @State private var isDetecting = false
    @State private var detectionRequest = UUID()
    @State private var showDiscardConfirmation = false
    private var dirty: Bool { configurations != originalConfigurations || environments != originalEnvironments }
    private var validationError: String? {
        loadError ?? RunConfigurationValidation.error(configurations, environments: environments, projectPath: projectPath, language: model.language)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(text("运行配置", "Run configurations"), systemImage: "play.rectangle").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(text("关闭", "Close")) { requestClose() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            WorkbenchSplit("runSettings", initial: 190, minimum: 170, otherMinimum: 380) {
                VStack(spacing: 0) {
                    List(configurations, selection: $selection) { config in
                        Label(config.name, systemImage: "terminal").font(.system(size: 12)).lineLimit(1).tag(config.id)
                    }.listStyle(.sidebar).accessibilityLabel(text("运行配置列表", "Run configurations list"))
                    Divider()
                    Menu {
                        ForEach(detected) { config in
                            Button(config.name) { importConfiguration(config) }
                                .disabled(configurations.contains { $0.command == config.command && resolvedDirectory($0.workingDirectory) == resolvedDirectory(config.workingDirectory) })
                        }
                        if detected.isEmpty { Text(text("未检测到可运行命令", "No commands detected")) }
                        Divider()
                        Button(text("重新检测", "Detect again")) { Task { await detectCommands() } }
                    } label: { Label(isDetecting ? text("检测中…", "Detecting…") : text("从项目导入", "Import from project"), systemImage: "square.and.arrow.down") }
                        .disabled(isDetecting).padding(10)
                    HStack(spacing: 14) {
                        Button { addConfiguration() } label: { Image(systemName: "plus") }.help(text("新增配置", "Add configuration")).accessibilityLabel(text("新增配置", "Add configuration"))
                        Button { removeConfiguration() } label: { Image(systemName: "minus") }.disabled(selection == nil).help(text("删除配置", "Remove configuration")).accessibilityLabel(text("删除配置", "Remove configuration"))
                        Button { duplicateConfiguration() } label: { Image(systemName: "doc.on.doc") }.disabled(selection == nil).help(text("复制配置", "Duplicate configuration")).accessibilityLabel(text("复制配置", "Duplicate configuration"))
                        Spacer()
                    }.buttonStyle(.borderless).padding(10)
                }.frame(maxWidth: .infinity)
                } second: {
                if let index = selectedIndex {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            formField(text("名称", "Name")) {
                                TextField("", text: $configurations[index].name).textFieldStyle(.roundedBorder)
                                    .accessibilityLabel(text("配置名称", "Configuration name")).focused($focusedName, equals: configurations[index].id)
                            }
                            formField(text("命令", "Command")) {
                                ResizableFormArea("runSettings.command", initial: 62) {
                                    TextEditor(text: $configurations[index].command).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
                                        .accessibilityLabel(text("运行命令", "Run command"))
                                }.padding(6).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                            }
                            formField(text("工作目录", "Working directory")) {
                                HStack {
                                    TextField(text("留空使用项目根目录", "Blank uses project root"), text: $configurations[index].workingDirectory).textFieldStyle(.roundedBorder)
                                        .accessibilityLabel(text("工作目录", "Working directory"))
                                    Button(text("选择…", "Choose…")) { chooseDirectory(index) }
                                        .accessibilityLabel(text("选择工作目录", "Choose working directory"))
                                }
                            }
                            formField(text("环境变量（每行 KEY=VALUE）", "Environment variables (KEY=VALUE per line)")) {
                                ResizableFormArea("runSettings.environment", initial: 75) {
                                    TextEditor(text: Binding(get: { environments[configurations[index].id] ?? "" }, set: { environments[configurations[index].id] = $0 })).font(.system(size: 11, design: .monospaced)).scrollContentBackground(.hidden)
                                        .accessibilityLabel(text("环境变量", "Environment variables"))
                                }.padding(6).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle(text("打开项目后自动运行", "Run when project opens"), isOn: $configurations[index].autoStart).font(.system(size: 12))
                                Text(text("继承本机登录环境，以上环境变量优先。", "Inherits your login environment; these variables take priority.")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(18)
                    }.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 10) {
                        Text(text("添加或选择一项运行配置", "Add or select a configuration")).font(.system(size: 12)).foregroundStyle(.secondary)
                        Button(text("新增配置", "Add configuration")) { addConfiguration() }
                    }.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack(spacing: 10) {
                if let error = localError ?? validationError { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2).help(error) }
                Spacer()
                Button(text("取消", "Cancel")) { requestClose() }
                Button(text("保存", "Save")) { save() }.buttonStyle(.borderedProminent).disabled(validationError != nil).keyboardShortcut(.defaultAction)
            }.padding(14)
        }.frame(minWidth: 620, idealWidth: 740, maxWidth: .infinity, minHeight: 460, idealHeight: 570, maxHeight: .infinity)
        .resizableSheet(minimumWidth: 620, minimumHeight: 460, language: model.language)
        .onAppear {
            guard let project = model.selectedProject else { return }
            projectID = project.id; projectPath = project.path
            originalData = configurationData
            if FileManager.default.fileExists(atPath: configurationURL.path) {
                if let data = originalData, let saved = RunConfigurationValidation.decodeSaved(data) {
                    configurations = saved
                } else {
                    configurations = []
                    loadError = text("已保存的配置无法读取。请先检查 .git-workbench/run-config.json，当前不会覆盖该文件。", "Saved configurations cannot be read. Check .git-workbench/run-config.json before saving.")
                }
            } else { configurations = project.runConfigurations }
            environments = Dictionary(configurations.map { ($0.id, EnvironmentParser.serialize($0.environment)) }, uniquingKeysWith: { first, _ in first })
            originalConfigurations = configurations; originalEnvironments = environments
            selection = configurations.first(where: { $0.id == model.selectedRunConfigurationID })?.id ?? configurations.first?.id
            model.confirmSheetQuit = { confirmQuit() }
        }
        .onDisappear { model.confirmSheetQuit = nil }
        .interactiveDismissDisabled(dirty)
        .confirmationDialog(text("保存运行配置的修改？", "Save configuration changes?"), isPresented: $showDiscardConfirmation, titleVisibility: .visible) {
            Button(text("保存并关闭", "Save and Close")) { save() }.disabled(validationError != nil)
            Button(text("不保存", "Discard changes"), role: .destructive) { dismiss() }
            Button(text("继续编辑", "Keep editing"), role: .cancel) {}
        }
        .onChange(of: model.selectedProjectID) { newProjectID in
            guard newProjectID != projectID else { return }
            guard dirty else { dismiss(); return }
            // Keep the draft attached to the project it was opened for. A
            // project switch must never silently discard edited commands or
            // environment variables.
            if let projectID, let originalProject = model.projects.first(where: { $0.id == projectID }) {
                model.selectProject(originalProject)
            }
            localError = text("当前配置有未保存修改，请先保存或取消编辑。", "This configuration has unsaved changes. Save or cancel editing before switching projects.")
        }
        .task(id: projectPath) { await detectCommands() }
    }

    private func formField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content()
        }
    }
    private func uniqueName(_ base: String) -> String {
        var suffix = 1; var candidate = base
        while configurations.contains(where: { $0.name == candidate }) { suffix += 1; candidate = "\(base) \(suffix)" }
        return candidate
    }
    private func addConfiguration() {
        let configuration = RunConfiguration(name: uniqueName(text("新配置", "New configuration")), command: "", workingDirectory: projectPath)
        configurations.append(configuration); selection = configuration.id
        focusedName = configuration.id
    }
    private func removeConfiguration() {
        guard let index = selectedIndex else { return }
        let removed = configurations.remove(at: index); environments.removeValue(forKey: removed.id)
        selection = configurations.isEmpty ? nil : configurations[min(index, configurations.count - 1)].id
    }
    private func duplicateConfiguration() {
        guard let index = selectedIndex else { return }
        var copy = configurations[index]; copy.id = UUID(); copy.name = uniqueName(copy.name + text(" 副本", " copy"))
        environments[copy.id] = environments[configurations[index].id]
        configurations.insert(copy, at: index + 1); selection = copy.id
        focusedName = copy.id
    }
    private func resolvedDirectory(_ directory: String) -> String {
        RunConfigurationValidation.directory(directory, projectPath: projectPath)
    }

    private var configurationData: Data? {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else { return nil }
        return FilePreviewReader.readRange(path: configurationURL.path, offset: 0, count: 1024 * 1024 + 1)
    }
    private var configurationURL: URL { URL(fileURLWithPath: projectPath).appendingPathComponent(".git-workbench/run-config.json") }
    private func requestClose() { if dirty { showDiscardConfirmation = true } else { dismiss() } }
    private func confirmQuit() -> Bool {
        guard dirty else { dismiss(); return true }
        let alert = NSAlert()
        alert.messageText = text("保存运行配置后退出？", "Save run configurations before quitting?")
        alert.informativeText = text("运行配置中有未保存的修改。", "There are unsaved changes in run configurations.")
        alert.addButton(withTitle: text("保存并退出", "Save and Quit")).isEnabled = validationError == nil
        alert.addButton(withTitle: text("不保存", "Discard changes"))
        alert.addButton(withTitle: text("取消", "Cancel")).keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: dismiss(); return true
        default: return false
        }
    }
    private func detectCommands() async {
        guard !projectPath.isEmpty else { return }
        let request = UUID()
        detectionRequest = request
        isDetecting = true
        let url = URL(fileURLWithPath: projectPath)
        let commands = await Task.detached(priority: .utility) { ProjectCommandDetector.detect(at: url) }.value
        guard detectionRequest == request else { return }
        if !Task.isCancelled { detected = commands }
        isDetecting = false
    }
    private func importConfiguration(_ configuration: RunConfiguration) {
        var value = configuration
        value.id = UUID(); value.name = uniqueName(value.name)
        configurations.append(value); environments[value.id] = ""; selection = value.id
        focusedName = value.id
    }

    private func chooseDirectory(_ index: Int) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: resolvedDirectory(configurations[index].workingDirectory))
        if panel.runModal() == .OK, let url = panel.url { configurations[index].workingDirectory = url.path }
    }
    @discardableResult private func save() -> Bool {
        guard validationError == nil, let projectID else { return false }
        guard configurationData == originalData else {
            localError = text("配置文件已被其他程序修改。草稿已保留，请关闭后重新打开再编辑。", "The configuration file changed externally. Your draft is kept; reopen configurations before saving.")
            return false
        }
        localError = nil
        let values = configurations.map { config in
            var value = config; value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            value.environment = EnvironmentParser.parse(environments[value.id] ?? "")
            value.workingDirectory = resolvedDirectory(value.workingDirectory)
            return value
        }
        if model.replaceRunConfigurations(values, selectedID: selection, projectID: projectID) { dismiss(); return true }
        localError = model.errorMessage ?? text("无法保存配置。", "Could not save configurations.")
        return false
    }
}


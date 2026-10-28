import SwiftUI

struct EnvironmentSnapshot { let items: [EnvironmentItem]; let error: String? }
struct DockerSnapshot {
    var containers: [DockerContainer] = []
    var error: String? = nil
}

@MainActor
struct DockerClient {
    var list: () async -> DockerSnapshot
    var perform: (DockerAction, String) async -> CommandResult
    static var live: DockerClient { DockerClient(list: { await DockerService.list() }, perform: { await DockerService.perform($0, container: $1) }) }
}

enum DockerService {
    static func list() async -> DockerSnapshot {
        let result = await CommandRunner.run(command: "docker ps -a --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}'", cwd: FileManager.default.homeDirectoryForCurrentUser.path, interactiveShell: true, timeoutSeconds: 8)
        return parse(result)
    }
    static func parse(_ result: CommandResult) -> DockerSnapshot {
        guard result.status == 0, !result.truncated else {
            return DockerSnapshot(error: "Docker 读取失败 / Docker could not be read (\(result.status)).\n" + String(result.output.suffix(4000)))
        }
        var containers: [DockerContainer] = []; var ids = Set<String>()
        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 5, parts[0].range(of: "^[a-fA-F0-9]{12,64}$", options: .regularExpression) != nil, ids.insert(parts[0]).inserted else {
                return DockerSnapshot(error: "Docker 返回内容无法解析，请重试。 / Docker returned an unexpected response. Retry.")
            }
            containers.append(DockerContainer(id: parts[0], name: parts[1], image: parts[2], status: parts[3], ports: parts[4]))
        }
        return DockerSnapshot(containers: containers)
    }
    static func perform(_ action: DockerAction, container: String) async -> CommandResult {
        guard container.range(of: "^[a-fA-F0-9]{12,64}$", options: .regularExpression) != nil else { return CommandResult(output: "无效容器标识 / Invalid container ID", status: 1) }
        let verb: String
        switch action { case .start: verb = "start"; case .stop: verb = "stop"; case .restart: verb = "restart" }
        return await CommandRunner.run(command: "docker \(verb) \(Shell.quote(container))", cwd: FileManager.default.homeDirectoryForCurrentUser.path, interactiveShell: true, timeoutSeconds: 30)
    }
}

struct ServicesTool: View {
    @ObservedObject var model: WorkbenchModel
    @State private var showsEnvironment = false
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $showsEnvironment) { Text("Docker").tag(false); Text(text("开发环境", "Environment")).tag(true) }.pickerStyle(.segmented).frame(width: 220)
                if showsEnvironment ? model.isEnvironmentLoading : model.isDockerLoading { ProgressView().controlSize(.small) }
                Spacer()
                if !showsEnvironment, let notice = model.dockerNotice { Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Button { if showsEnvironment { model.refreshEnvironment() } else { model.refreshDocker() } } label: { Label(text("刷新", "Refresh"), systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless).font(.system(size: 11)).disabled(showsEnvironment ? model.isEnvironmentLoading : model.isDockerLoading || model.dockerBusyContainer != nil)
            }.padding(.horizontal, 12).padding(.vertical, 7)
                .background(WorkbenchChrome.raised)
            Rectangle().fill(WorkbenchChrome.quietSeparator).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if showsEnvironment {
                        if let error = model.environmentError { errorView(error) { model.refreshEnvironment() } }
                        if model.environments.isEmpty && model.isEnvironmentLoading { Text(text("正在检测本机登录环境…", "Detecting your login environment…")).font(.caption).foregroundStyle(.secondary) }
                        ForEach(model.environments) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: item.available ? "checkmark.circle" : "minus.circle").foregroundStyle(item.available ? Color.green : .secondary)
                                Text(item.name).font(.system(size: 11, weight: .semibold)).frame(width: 70, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.available ? item.version ?? text("已检测到", "Detected") : text("未安装或不在 PATH 中", "Not installed or not in PATH")).font(.system(size: 11)).foregroundStyle(.secondary)
                                    if item.available { Text(item.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
                                }
                                Spacer(minLength: 0)
                            }.padding(7)
                        }
                    } else {
                        if let error = model.dockerError { errorView(error) { model.refreshDocker() } }
                        if model.isDockerLoading && model.dockerContainers.isEmpty { Text(text("正在读取 Docker 容器…", "Loading Docker containers…")).font(.caption).foregroundStyle(.secondary) }
                        else if model.dockerContainers.isEmpty && model.dockerError == nil {
                            Label(text("Docker 已连接，暂无容器", "Connected to Docker; no containers"), systemImage: "shippingbox").font(.caption).foregroundStyle(.secondary).padding(8)
                        }
                        ForEach(model.dockerContainers) { container in containerRow(container) }
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.background(WorkbenchChrome.panel).onAppear {
            if model.environments.isEmpty { model.refreshEnvironment() }
            if model.dockerContainers.isEmpty { model.refreshDocker() }
        }
    }
    private func errorView(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(message).font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button(text("重试", "Retry"), action: retry).disabled(showsEnvironment ? model.isEnvironmentLoading : model.isDockerLoading || model.dockerBusyContainer != nil)
        }.padding(8).background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
    }
    private func containerRow(_ container: DockerContainer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(container.isRunning ? .green : .secondary).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 3) {
                    Text(container.name).font(.system(size: 11, weight: .semibold))
                    Text(container.image + " · " + container.status + (container.ports.isEmpty ? "" : " · " + container.ports)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if model.dockerBusyContainer == container.id { ProgressView().controlSize(.small) }
                if container.isRunning {
                    Button(text("停止", "Stop")) { model.dockerAction(.stop, container: container) }
                    Button(text("重启", "Restart")) { model.dockerAction(.restart, container: container) }
                } else { Button(text("启动", "Start")) { model.dockerAction(.start, container: container) } }
            }.buttonStyle(.borderless).disabled(model.dockerBusyContainer != nil || model.isDockerLoading)
            if let error = model.dockerActionErrors[container.id] {
                errorView(error) {
                    if let action = model.dockerLastActions[container.id] { model.dockerAction(action, container: container) }
                }
            }
        }.padding(8).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
    }
}

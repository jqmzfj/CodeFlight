import SwiftUI
import AppKit

struct GitCloneRequest {
    let remote: String
    let parent: String
    let directory: String
    var destination: String { URL(fileURLWithPath: parent).appendingPathComponent(directory).path }

    var validationError: String? {
        let source = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = GitRepositoryAddress.validationError(source) { return error }
        guard !directory.isEmpty, directory != ".", directory != "..", !directory.contains("/"), !directory.contains(":"), !directory.contains(where: { $0.isNewline || $0 == "\0" }), directory.lowercased() != ".git" else { return "请输入单个文件夹名称。 / Enter a single folder name." }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory), isDirectory.boolValue else { return "请选择存在的父目录。 / Select an existing parent directory." }
        guard !FileManager.default.fileExists(atPath: destination), (try? FileManager.default.attributesOfItem(atPath: destination)) == nil else { return "目标文件夹已存在，请选择其他名称。 / The target folder already exists. Choose another name." }
        return nil
    }

    static func suggestedDirectory(_ remote: String) -> String {
        let path = remote.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let component = path.split(separator: "/").last.map(String.init) ?? ""
        let name = component.split(separator: ":").last.map(String.init) ?? component
        return name.hasSuffix(".git") ? String(name.dropLast(4)) : name
    }
}

extension GitService {
    static func clone(_ request: GitCloneRequest, taskID: UUID, credentials: GitCredentials = GitCredentials(), onOutput: (@Sendable (String) -> Void)? = nil) async -> CommandResult {
        if let error = request.validationError { return CommandResult(output: error, status: 1) }
        return await CommandRunner.run(command: "\(credentials.git) clone --progress -- \(Shell.quote(request.remote.trimmingCharacters(in: .whitespacesAndNewlines))) \(Shell.quote(request.destination))", cwd: request.parent, taskID: taskID,
                                       environment: credentials.environment, onOutput: onOutput)
    }
}

@MainActor
final class GitCloneProgress: ObservableObject {
    @Published var running = false
    @Published var output = ""
    @Published var failure: String?
    private var taskID: UUID?
    private var cancelled = false

    func start(_ request: GitCloneRequest, credentials: GitCredentials, onSuccess: @escaping @MainActor (String) -> Void) {
        guard !running else { return }
        if let error = request.validationError { failure = error; return }
        running = true; output = ""; failure = nil; cancelled = false
        let id = UUID(); taskID = id
        Task {
            let result = await GitService.clone(request, taskID: id, credentials: credentials) { [weak self] chunk in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.output = String((self.output + chunk).suffix(16_000))
                }
            }
            running = false; taskID = nil
            output = String(result.output.suffix(16_000))
            if cancelled { return }
            if result.status == 0 { onSuccess(request.destination) }
            else { failure = result.output.isEmpty ? "克隆未完成。 / Clone did not complete." : result.output }
        }
    }

    func stop() {
        cancelled = true
        if let taskID { CommandRunner.stop(taskID: taskID) }
    }
}

struct GitCloneSheet: View {
    @ObservedObject var model: WorkbenchModel
    @StateObject private var progress = GitCloneProgress()
    @Environment(\.dismiss) private var dismiss
    @State private var remote = ""
    @State private var parent = ""
    @State private var directory = ""
    @State private var credentials = GitCredentials()
    @FocusState private var addressFocused: Bool
    private var request: GitCloneRequest { GitCloneRequest(remote: remote, parent: parent, directory: directory) }
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(text("克隆仓库", "Clone repository"), systemImage: "square.and.arrow.down").font(.title3.bold())
                Spacer()
                Button { progress.stop(); dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(text("关闭", "Close")).keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(text("仓库地址", "Repository URL")).font(.system(size: 11, weight: .medium))
                TextField("https://… / git@…", text: $remote).textFieldStyle(.roundedBorder).focused($addressFocused)
                Text(text("使用本机 Git 的 SSH 密钥和凭据配置。", "Uses SSH keys and credentials configured for local Git.")).font(.caption).foregroundStyle(.secondary)
            }.disabled(progress.running)
            VStack(alignment: .leading, spacing: 7) {
                Text(text("保存到", "Parent folder")).font(.system(size: 11, weight: .medium))
                HStack {
                    Text(parent.isEmpty ? text("请选择目录", "Choose a folder") : parent).font(.caption).lineLimit(1).truncationMode(.middle).help(parent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(text("选择…", "Choose…")) { chooseParent() }.accessibilityLabel(text("选择保存目录", "Choose parent folder"))
                }
            }.disabled(progress.running)
            VStack(alignment: .leading, spacing: 7) {
                Text(text("文件夹名称", "Folder name")).font(.system(size: 11, weight: .medium))
                TextField("", text: $directory).textFieldStyle(.roundedBorder).accessibilityLabel(text("文件夹名称", "Folder name"))
            }.disabled(progress.running)
            GitCredentialsFields(language: model.language, credentials: $credentials).disabled(progress.running)
            if progress.running || !progress.output.isEmpty {
                ScrollView {
                    Text(progress.output).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(8)
                }.frame(height: 130).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            }
            if let failure = progress.failure {
                Text(failure).font(.caption).foregroundStyle(.orange).lineLimit(5).textSelection(.enabled)
            }
            HStack {
                if progress.running { ProgressView().controlSize(.small); Text(text("正在克隆…", "Cloning…")).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(progress.running ? text("停止并关闭", "Stop and close") : text("取消", "Cancel")) { progress.stop(); dismiss() }
                Button(text("克隆并打开", "Clone and open")) {
                    progress.start(request, credentials: credentials) { path in model.openProject(at: URL(fileURLWithPath: path)); dismiss() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(progress.running || request.validationError != nil)
            }
            if !progress.running, !remote.isEmpty, !parent.isEmpty, let error = request.validationError { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(22)
        .frame(minWidth: 540, idealWidth: 620, maxWidth: .infinity,
               minHeight: 470, idealHeight: 620, maxHeight: .infinity,
               alignment: .topLeading)
        .resizableSheet(minimumWidth: 540, minimumHeight: 470, language: model.language)
        .onAppear { parent = model.selectedProject.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path } ?? ""; addressFocused = true }
        .onChange(of: remote) { old in directory = GitCloneRequest.suggestedDirectory(old) }
        .onDisappear { progress.stop(); credentials = GitCredentials() }
    }

    private func chooseParent() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = text("选择目录", "Choose folder")
        if !parent.isEmpty { panel.directoryURL = URL(fileURLWithPath: parent) }
        if panel.runModal() == .OK, let url = panel.url { parent = url.path }
    }
}

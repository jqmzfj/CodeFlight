import Foundation

struct GitSubmoduleAddRequest {
    let source: String
    let destination: String
    var validationError: String? {
        guard !source.isEmpty, !source.hasPrefix("-"), !source.contains(where: { $0.isNewline || $0 == "\0" }), !source.contains("::") else {
            return "请输入有效的 Git 仓库地址。 / Enter a valid Git repository URL."
        }
        if let url = URLComponents(string: source), url.host != nil {
            guard ["http", "https", "ssh", "git", "file"].contains(url.scheme?.lowercased() ?? ""), url.password == nil,
                  url.query == nil, url.fragment == nil, !(["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.user != nil) else {
                return "仓库地址不能包含密码、HTTP 用户凭据或查询令牌，请使用临时身份验证。 / Remove credentials and query tokens from the URL; use temporary authentication."
            }
        }
        let parts = destination.split(separator: "/", omittingEmptySubsequences: false)
        guard !destination.isEmpty, !destination.hasPrefix("-"), !destination.contains(":"), !destination.contains("\\"),
              !destination.contains(where: { $0.isNewline || $0 == "\0" }),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" && $0.lowercased() != ".gitmodules" }) else {
            return "请输入仓库内的相对目录，例如 modules/library；不能包含 .. 或 .git。 / Enter a relative path inside the repository, without .. or .git."
        }
        return nil
    }
}

extension GitService {
    private static func submoduleConfigurationProblem(at root: String) async -> String? {
        guard await operationState(at: root) == nil else { return "请先完成或中止当前 Git 操作。 / Finish or abort the current Git operation first." }
        let configURL = URL(fileURLWithPath: root).appendingPathComponent(".gitmodules")
        if let info = try? configURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]),
           info.isSymbolicLink == true || info.isRegularFile != true || (info.fileSize ?? Int.max) > 1024 * 1024 {
            return ".gitmodules 必须是不超过 1 MB 的普通文件。 / .gitmodules must be a regular file up to 1 MB."
        }
        if FileManager.default.fileExists(atPath: configURL.path) {
            let tracked = await CommandRunner.run(command: "git --literal-pathspecs ls-files --error-unmatch -- .gitmodules", cwd: root)
            guard tracked.status == 0 else { return "请先提交或移走现有未跟踪的 .gitmodules 文件。 / Commit or move the existing untracked .gitmodules file first." }
        }
        let status = await CommandRunner.run(command: "git --literal-pathspecs status --porcelain=v1 -z --untracked-files=all -- .gitmodules", cwd: root)
        guard status.status == 0, !status.truncated, status.output.isEmpty else {
            return "请先提交或保存 .gitmodules 的修改，再添加或移除子模块。 / Commit or stash changes to .gitmodules first."
        }
        let modules = await submodules(at: root)
        return modules.1
    }

    static func addSubmodule(_ request: GitSubmoduleAddRequest, at path: String, credentials: GitCredentials = GitCredentials()) async -> CommandResult {
        if let error = request.validationError { return CommandResult(output: error, status: 1) }
        let location = await CommandRunner.run(command: "git rev-parse --show-toplevel", cwd: path)
        guard location.status == 0 else { return location }
        let root = location.output.hasSuffix("\n") ? String(location.output.dropLast()) : location.output
        if let error = await submoduleConfigurationProblem(at: root) { return CommandResult(output: error, status: 1) }
        let modules = await submodules(at: root)
        guard modules.0.count < 500 else { return CommandResult(output: "子模块数量已达 500 项。 / The repository already has 500 submodules.", status: 1) }
        guard !modules.0.contains(where: { request.destination == $0.path || request.destination.hasPrefix($0.path + "/") || $0.path.hasPrefix(request.destination + "/") }) else {
            return CommandResult(output: "此路径与现有子模块重叠，请选择其他目录。 / Choose a path that does not overlap an existing submodule.", status: 1)
        }
        let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        var destination = rootURL
        for part in request.destination.split(separator: "/") {
            destination.appendPathComponent(String(part))
            if let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                return CommandResult(output: "目标路径不能经过符号链接。 / The destination cannot traverse a symbolic link.", status: 1)
            }
        }
        guard (try? FileManager.default.attributesOfItem(atPath: destination.path)) == nil else {
            return CommandResult(output: "目标目录已存在，请选择新目录；不会覆盖现有文件。 / The destination exists. Choose a new directory.", status: 1)
        }
        let tracked = await CommandRunner.run(command: "git --literal-pathspecs ls-files --stage -z -- \(Shell.quote(request.destination))", cwd: root)
        guard tracked.status == 0, tracked.output.isEmpty, !tracked.truncated else {
            return CommandResult(output: "目标路径已有索引记录，请先处理现有文件。 / The destination has tracked index entries.", status: 1)
        }
        var source = request.source
        var local = false
        if source.hasPrefix("/") || source.hasPrefix("./") || source.hasPrefix("../") {
            source = URL(fileURLWithPath: source, relativeTo: rootURL).standardizedFileURL.path
            local = true
        } else if let url = URL(string: source), url.isFileURL {
            guard url.host == nil || url.host == "" || url.host == "localhost" else { return CommandResult(output: "本地仓库地址的主机无效。 / Invalid host for a local repository.", status: 1) }
            source = url.path; local = true
        } else if !source.contains(":") {
            return CommandResult(output: "本地仓库请填写绝对路径或以 ./、../ 开头。 / Use an absolute path or ./ or ../ for a local repository.", status: 1)
        }
        // Local transport is enabled only for an explicitly entered local source,
        // only for this command. No system or repository policy is changed.
        let localFlag = local ? "-c protocol.file.allow=always " : ""
        return await CommandRunner.run(command: "\(credentials.git) \(localFlag)submodule add -- \(Shell.quote(source)) \(Shell.quote(request.destination))", cwd: root, environment: credentials.environment)
    }

    static func removeSubmodule(_ module: GitSubmodule) async -> CommandResult {
        let latest = await submodules(at: module.root)
        guard latest.1 == nil, let current = latest.0.first(where: { $0.path == module.path }), current.expectedHash == module.expectedHash, current.url == module.url else {
            return CommandResult(output: "子模块配置或固定提交已改变，请刷新后重试。 / Submodule configuration or pin changed. Refresh and retry.", status: 1)
        }
        if let error = await submoduleConfigurationProblem(at: current.root) { return CommandResult(output: error, status: 1) }
        let staged = await CommandRunner.run(command: "git --literal-pathspecs diff --cached --quiet -- \(Shell.quote(current.path))", cwd: current.root)
        guard staged.status == 0 else { return CommandResult(output: "请先提交或取消暂存此子模块的固定提交修改。 / Commit or unstage the changed submodule pin first.", status: 1) }
        var queue = [current]
        var visited = Set<String>()
        while !queue.isEmpty {
            let item = queue.removeLast()
            guard visited.insert(item.absolutePath).inserted, visited.count <= 500 else {
                return CommandResult(output: "嵌套子模块超过检查范围，请使用 Git 命令处理。 / Nested submodules exceed the inspection limit.", status: 1)
            }
            let state = await submoduleState(item)
            guard state.error == nil else { return CommandResult(output: state.error ?? "无法检查子模块。 / Cannot inspect submodule.", status: 1) }
            if !state.initialized {
                let location = URL(fileURLWithPath: item.absolutePath)
                if FileManager.default.fileExists(atPath: location.path) {
                    guard let children = FileManager.default.enumerator(at: location, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]), children.nextObject() == nil else {
                        return CommandResult(output: "未初始化的子模块目录中仍有文件，未移除：\(item.path) / Uninitialized submodule contains files.", status: 1)
                    }
                }
                continue
            }
            guard state.hash == item.expectedHash else {
                return CommandResult(output: "子模块检出与固定提交不同，请先保存提交并更新父仓库：\(item.path) / Checkout differs from the pinned commit.", status: 1)
            }
            let files = await CommandRunner.run(command: "git status --porcelain=v1 -z --untracked-files=all --ignored=matching --ignore-submodules=none", cwd: item.absolutePath, outputLimit: 1024 * 1024)
            guard files.status == 0, !files.truncated, files.output.isEmpty else {
                return CommandResult(output: "子模块中有修改、未跟踪或忽略的文件，请先保存或清理：\(item.path) / Save or clean modified, untracked and ignored files first.", status: 1)
            }
            let nested = await submodules(at: item.absolutePath)
            guard nested.1 == nil else { return CommandResult(output: nested.1 ?? "无法检查嵌套子模块。 / Cannot inspect nested submodules.", status: 1) }
            queue.append(contentsOf: nested.0)
        }
        // Prepare the exact config edit before changing the checkout. Some Git
        // versions fail to remove a subsection whose name includes brackets.
        let config = await CommandRunner.run(command: "git config --null --file .gitmodules --get-regexp '^submodule\\..*\\.path$'", cwd: current.root, outputLimit: 1024 * 1024)
        guard config.status == 0, !config.truncated,
              let record = config.output.split(separator: "\0").first(where: { $0.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) == current.path }),
              let newline = record.firstIndex(of: "\n") else {
            return CommandResult(output: "无法定位子模块配置，请刷新。 / Cannot locate submodule configuration. Refresh.", status: 1)
        }
        let section = String(record[..<newline].dropLast(5))
        let configURL = URL(fileURLWithPath: current.root).appendingPathComponent(".gitmodules")
        do {
            let original = try Data(contentsOf: configURL)
            let permissions = try FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions]
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("git-workbench-submodule-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let prepared = directory.appendingPathComponent("gitmodules")
            try original.write(to: prepared)
            // --remove-section has the same bracket-name bug as submodule rm
            // on affected Git versions. Unset the exact keys instead; the config
            // writer then removes the empty subsection while preserving others.
            let entries = await CommandRunner.run(command: "git config --null --file \(Shell.quote(prepared.path)) --list", cwd: current.root, outputLimit: 1024 * 1024)
            guard entries.status == 0, !entries.truncated else { return CommandResult(output: "无法读取子模块配置。 / Cannot read submodule configuration.", status: 1) }
            let keys = Set(entries.output.split(separator: "\0").compactMap { entry -> String? in
                guard let separator = entry.firstIndex(of: "\n") else { return nil }
                let key = String(entry[..<separator])
                guard let dot = key.lastIndex(of: "."), String(key[..<dot]) == section else { return nil }
                return key
            })
            guard !keys.isEmpty else { return CommandResult(output: "子模块配置已改变，请刷新。 / Submodule configuration changed. Refresh.", status: 1) }
            for key in keys.sorted() {
                let edit = await CommandRunner.run(command: "git config --file \(Shell.quote(prepared.path)) --unset-all \(Shell.quote(key))", cwd: current.root)
                guard edit.status == 0 else { return edit }
            }
            let expected = try Data(contentsOf: prepared)
            guard try Data(contentsOf: configURL) == original else { return CommandResult(output: ".gitmodules 已改变，请刷新。 / .gitmodules changed. Refresh.", status: 1) }
            // Git rechecks dirtiness and retains object history in .git/modules.
            let removed = await CommandRunner.run(command: "git --literal-pathspecs rm -- \(Shell.quote(current.path))", cwd: current.root)
            guard removed.status == 0 else { return removed }
            let after = try Data(contentsOf: configURL)
            guard after == original || after == expected else {
                return CommandResult(output: "目录已移除，但 .gitmodules 被其他操作修改，未覆盖或暂存该文件。请检查后提交。 / Checkout removed, but .gitmodules changed externally. Inspect before committing.", status: 1)
            }
            if after == original {
                try expected.write(to: configURL, options: .atomic)
                if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: configURL.path) }
            }
            let staged = await CommandRunner.run(command: "git --literal-pathspecs add -- .gitmodules", cwd: current.root)
            guard staged.status == 0 else { return staged }
            return CommandResult(output: "已移除子模块，请提交父仓库中的更改。 / Submodule removed. Commit the parent changes.\n" + removed.output, status: 0)
        } catch { return CommandResult(output: error.localizedDescription, status: 1) }
    }
}

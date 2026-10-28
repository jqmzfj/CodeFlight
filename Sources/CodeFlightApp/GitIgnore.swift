import Foundation

extension GitService {
    static func ignoreUntrackedFile(_ file: String, at path: String) async -> CommandResult {
        let parts = file.split(separator: "/", omittingEmptySubsequences: false)
        guard !file.isEmpty, !file.hasPrefix("/"), !file.contains(where: { $0.isNewline || $0 == "\0" }),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }),
              parts.last != ".gitignore" else {
            return CommandResult(output: "无法为此路径生成单文件忽略规则。 / Cannot create a literal ignore rule for this path.", status: 1)
        }
        let location = await CommandRunner.run(command: "git rev-parse --show-toplevel", cwd: path)
        guard location.status == 0, !location.truncated else { return location }
        let root = URL(fileURLWithPath: location.output.hasSuffix("\n") ? String(location.output.dropLast()) : location.output).resolvingSymlinksInPath()
        let available = await CommandRunner.run(command: "git --literal-pathspecs ls-files --others --exclude-standard -z -- \(Shell.quote(file))", cwd: root.path)
        guard available.status == 0, !available.truncated, available.output == file + "\0" else {
            return CommandResult(output: "文件已暂存、已跟踪、已忽略或不存在，请刷新。 / File is staged, tracked, ignored or missing. Refresh the list.", status: 1)
        }
        // Use the nearest existing .gitignore so a deeper negation cannot
        // override a new root rule. Otherwise keep new rules at repository root.
        var folder = root.appendingPathComponent(file).deletingLastPathComponent()
        var config = root.appendingPathComponent(".gitignore")
        while folder.path != root.path {
            let candidate = folder.appendingPathComponent(".gitignore")
            if (try? FileManager.default.attributesOfItem(atPath: candidate.path)) != nil { config = candidate; break }
            folder.deleteLastPathComponent()
        }
        guard config.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            return CommandResult(output: "忽略文件不能指向仓库外。 / Ignore file must remain inside the repository.", status: 1)
        }
        let configPath = String(config.path.dropFirst(root.path.count + 1))
        let conflicts = await CommandRunner.run(command: "git --literal-pathspecs ls-files -u -z -- \(Shell.quote(configPath))", cwd: root.path)
        guard conflicts.status == 0, conflicts.output.isEmpty else {
            return CommandResult(output: "请先解决忽略文件的冲突。 / Resolve conflicts in the ignore file first.", status: 1)
        }
        do {
            let attributes: [FileAttributeKey: Any]?
            do { attributes = try FileManager.default.attributesOfItem(atPath: config.path) }
            catch {
                let error = error as NSError
                guard error.domain == NSCocoaErrorDomain, [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) else { throw error }
                attributes = nil
            }
            if let attributes {
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1024 * 1024 else {
                    return CommandResult(output: ".gitignore 必须是不超过 1 MB 的普通文件。 / .gitignore must be a regular file up to 1 MB.", status: 1)
                }
            }
            let original = attributes == nil ? Data() : FilePreviewReader.readRange(path: config.path, offset: 0, count: 1024 * 1024 + 1)
            guard original.count <= 1024 * 1024, original.count == ((attributes?[.size] as? NSNumber)?.intValue ?? 0),
                  let text = String(data: original, encoding: .utf8), !text.contains("\0") else {
                return CommandResult(output: "无法可靠读取 UTF-8 忽略文件，请手动编辑。 / Cannot read the UTF-8 ignore file reliably. Edit it manually.", status: 1)
            }
            let relative = String(root.appendingPathComponent(file).path.dropFirst(config.deletingLastPathComponent().path.count + 1))
            let escaped = relative.reduce(into: "") { result, character in
                if "\\*?[]!# ".contains(character) { result.append("\\") }
                result.append(character)
            }
            let newline = text.contains("\r\n") ? "\r\n" : "\n"
            let addition = (text.isEmpty || text.hasSuffix("\n") ? "" : newline) + "/" + escaped + newline
            var updated = original; updated.append(contentsOf: addition.utf8)
            try updated.write(to: config, options: .atomic)
            if let permissions = attributes?[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: config.path) }
            return CommandResult(output: "已添加忽略规则：\(configPath) → /\(escaped)。文件保留，规则尚未暂存。 / Ignore rule added; the file is kept and the rule is not staged.", status: 0)
        } catch {
            return CommandResult(output: error.localizedDescription, status: 1)
        }
    }
}

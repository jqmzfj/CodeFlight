import Foundation

enum RunConfigurationValidation {
    static func decodeSaved(_ data: Data) -> [RunConfiguration]? {
        guard data.count <= 1024 * 1024,
              let values = try? JSONDecoder().decode([RunConfiguration].self, from: data),
              Set(values.map(\.id)).count == values.count else { return nil }
        return values
    }

    static func directory(_ value: String, projectPath: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return projectPath }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : URL(fileURLWithPath: projectPath).appendingPathComponent(expanded).standardizedFileURL.path
    }

    /// Validate the actual launch snapshot too: files and paths can change after saving.
    static func launchError(command: String, directory: String, environment: [String: String], language: AppLanguage) -> String? {
        func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: language) }
        if command.contains("\0") || directory.contains("\0") {
            return text("命令或目录包含无效字符，请检查运行配置。", "The command or directory contains an invalid character. Check the run configuration.")
        }
        if environment.contains(where: { key, value in
            key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) == nil || value.contains("\0")
        }) {
            return text("环境变量名称或内容无效，请检查运行配置。", "An environment variable name or value is invalid. Check the run configuration.")
        }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) || !isDirectory.boolValue {
            return text("工作目录不存在：", "Working directory does not exist: ") + directory
        }
        return nil
    }

    static func environmentErrorLine(_ text: String) -> Int? {
        var keys = Set<String>()
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard let separator = line.firstIndex(of: "=") else { return index + 1 }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                  keys.insert(key).inserted, !value.contains("\0") else { return index + 1 }
            if let first = value.first, first == "\"" || first == "'" {
                if value.count < 2 || value.last != first { return index + 1 }
            }
            if EnvironmentParser.parse(key + "=" + value)[key]?.contains("\0") == true { return index + 1 }
        }
        return nil
    }

    static func error(_ configurations: [RunConfiguration], environments: [UUID: String], projectPath: String, language: AppLanguage) -> String? {
        func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: language) }
        var names = Set<String>(); var ids = Set<UUID>()
        for config in configurations {
            let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ids.insert(config.id).inserted else { return text("配置标识重复，请重新打开配置。", "Duplicate configuration IDs. Reopen configurations.") }
            if name.isEmpty || config.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text("请填写配置名称和命令。", "Enter a name and command for each configuration.") }
            if !names.insert(name).inserted { return text("配置名称不能重复。", "Configuration names must be unique.") }
            if config.command.contains("\0") || config.workingDirectory.contains("\0") { return text("命令或目录包含无效字符。", "The command or directory contains an invalid character.") }
            if let line = environmentErrorLine(environments[config.id] ?? "") {
                return text("“\(name)”的环境变量第 \(line) 行无效：请使用 KEY=VALUE，名称不能重复，且引号必须成对。", "Environment line \(line) in ‘\(name)’ is invalid: use unique KEY=VALUE entries with matching quotes.")
            }
            let path = directory(config.workingDirectory, projectPath: projectPath)
            var directory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: path, isDirectory: &directory) || !directory.boolValue { return text("工作目录不存在：", "Working directory does not exist: ") + path }
        }
        return nil
    }
}

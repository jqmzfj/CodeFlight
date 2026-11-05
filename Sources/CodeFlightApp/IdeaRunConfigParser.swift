import Foundation

struct IdeaRawRunConfig: Equatable {
    var name: String
    var type: String
    var module: String = ""
    var mainClass: String = ""
    var vmParameters: String = ""
    var programParameters: String = ""
    var activeProfiles: String = ""
    var workingDir: String = ""
    var scriptPath: String = ""
    var testMethod: String = ""
}

enum IdeaRunConfigParser {
    /// Parses run configurations from IntelliJ IDEA's `.idea/workspace.xml`
    /// and `.idea/runConfigurations/*.xml` files.
    static func detect(at projectURL: URL) -> [RunConfiguration] {
        let fm = FileManager.default
        let ideaURL = projectURL.appendingPathComponent(".idea")
        guard fm.fileExists(atPath: ideaURL.path) else { return [] }

        var rawConfigs: [IdeaRawRunConfig] = []

        // 1. Read .idea/workspace.xml
        let workspaceURL = ideaURL.appendingPathComponent("workspace.xml")
        if fm.fileExists(atPath: workspaceURL.path),
           let content = readFileText(at: workspaceURL, maxBytes: 1024 * 1024) {
            rawConfigs.append(contentsOf: parseRunManager(from: content))
        }

        // 2. Read .idea/runConfigurations/*.xml
        let runConfigsDir = ideaURL.appendingPathComponent("runConfigurations")
        if let files = try? fm.contentsOfDirectory(atPath: runConfigsDir.path) {
            for file in files.sorted() where file.hasSuffix(".xml") {
                let fileURL = runConfigsDir.appendingPathComponent(file)
                if let content = readFileText(at: fileURL, maxBytes: 256 * 1024) {
                    rawConfigs.append(contentsOf: parseConfigurations(from: content))
                }
            }
        }

        guard !rawConfigs.isEmpty else { return [] }

        return mapToRunConfigurations(rawConfigs, projectURL: projectURL)
    }

    private static func readFileText(at url: URL, maxBytes: Int) -> String? {
        let bytes = FilePreviewReader.readRange(path: url.path, offset: 0, count: maxBytes)
        guard !bytes.isEmpty else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Extracts <configuration> blocks inside <component name="RunManager"...>
    static func parseRunManager(from xml: String) -> [IdeaRawRunConfig] {
        guard let runManagerRange = findRunManagerBlock(in: xml) else { return [] }
        let runManagerChunk = String(xml[runManagerRange])
        return parseConfigurations(from: runManagerChunk)
    }

    private static func findRunManagerBlock(in xml: String) -> Range<String.Index>? {
        guard let start = xml.range(of: "<component name=\"RunManager\"") ?? xml.range(of: "<component name='RunManager'") else {
            return nil
        }
        guard let end = xml.range(of: "</component>", range: start.lowerBound..<xml.endIndex) else {
            return nil
        }
        return start.lowerBound..<end.upperBound
    }

    /// Parses all <configuration ...> ... </configuration> or self-closing <configuration ... /> blocks.
    static func parseConfigurations(from xml: String) -> [IdeaRawRunConfig] {
        var results: [IdeaRawRunConfig] = []
        var searchStart = xml.startIndex

        while searchStart < xml.endIndex {
            guard let configStart = xml.range(of: "<configuration ", range: searchStart..<xml.endIndex) else {
                break
            }

            // Find closing tag or self closing />
            let chunkRemaining = xml[configStart.lowerBound...]
            var configBlock = ""
            var nextSearch = configStart.upperBound

            if let closeTag = chunkRemaining.range(of: "</configuration>") {
                let blockRange = configStart.lowerBound..<closeTag.upperBound
                configBlock = String(xml[blockRange])
                nextSearch = closeTag.upperBound
            } else if let selfClose = chunkRemaining.range(of: "/>") {
                let blockRange = configStart.lowerBound..<selfClose.upperBound
                configBlock = String(xml[blockRange])
                nextSearch = selfClose.upperBound
            } else {
                break
            }

            searchStart = nextSearch

            if let parsed = parseSingleConfiguration(block: configBlock) {
                // Ignore default templates (<configuration default="true" ...>)
                if !configBlock.contains("default=\"true\"") && !configBlock.contains("default='true'") {
                    results.append(parsed)
                }
            }
        }

        return results
    }

    private static func parseSingleConfiguration(block: String) -> IdeaRawRunConfig? {
        guard let name = extractAttribute("name", from: block),
              let type = extractAttribute("type", from: block) else {
            return nil
        }

        var config = IdeaRawRunConfig(name: name, type: type)

        // Module
        if let moduleName = extractTagAttribute(tag: "module", attribute: "name", in: block) {
            config.module = moduleName
        }

        // Options
        let options = extractOptions(from: block)
        if let main = options["SPRING_BOOT_MAIN_CLASS"] ?? options["MAIN_CLASS_NAME"] {
            config.mainClass = main
        }
        if let vm = options["VM_PARAMETERS"] {
            config.vmParameters = vm
        }
        if let params = options["PROGRAM_PARAMETERS"] ?? options["PARAMETERS"] {
            config.programParameters = params
        }
        if let profiles = options["ACTIVE_PROFILES"] {
            config.activeProfiles = profiles
        }
        if let dir = options["WORKING_DIRECTORY"] ?? extractTagAttribute(tag: "working_directory", attribute: "value", in: block) {
            config.workingDir = dir
        }
        if let script = options["SCRIPT_NAME"] ?? extractTagAttribute(tag: "filePath", attribute: "value", in: block) ?? options["run-script"] {
            config.scriptPath = script
        }
        if let method = options["METHOD_NAME"] {
            config.testMethod = method
        }

        return config
    }

    private static func extractAttribute(_ attr: String, from xml: String) -> String? {
        let patterns = ["\(attr)=\"([^\"]+)\"", "\(attr)='([^']+)'"]
        for p in patterns {
            if let range = xml.range(of: p, options: .regularExpression) {
                let match = String(xml[range])
                if let quoteStart = match.firstIndex(of: "\"") ?? match.firstIndex(of: "'") {
                    let rest = match[match.index(after: quoteStart)...]
                    if let quoteEnd = rest.firstIndex(of: "\"") ?? rest.firstIndex(of: "'") {
                        return String(rest[..<quoteEnd])
                    }
                }
            }
        }
        return nil
    }

    private static func extractTagAttribute(tag: String, attribute: String, in xml: String) -> String? {
        let pattern = "<\(tag)[^>]*\\b\(attribute)=[\"']([^\"']*)[\"'][^>]*>"
        guard let range = xml.range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(xml[range])
        return extractAttribute(attribute, from: match)
    }

    private static func extractOptions(from xml: String) -> [String: String] {
        var options: [String: String] = [:]
        var searchStart = xml.startIndex
        while searchStart < xml.endIndex {
            guard let optionStart = xml.range(of: "<option ", range: searchStart..<xml.endIndex) else { break }
            guard let optionEnd = xml.range(of: ">", range: optionStart.upperBound..<xml.endIndex) else { break }
            let tag = String(xml[optionStart.lowerBound...optionEnd.lowerBound])
            searchStart = optionEnd.upperBound

            if let name = extractAttribute("name", from: tag),
               let value = extractAttribute("value", from: tag) {
                options[name] = value
            }
        }
        return options
    }

    private static func mapToRunConfigurations(_ rawConfigs: [IdeaRawRunConfig], projectURL: URL) -> [RunConfiguration] {
        let fm = FileManager.default
        let hasMvnw = fm.fileExists(atPath: projectURL.appendingPathComponent("mvnw").path)
        let mvnCmd = hasMvnw ? "./mvnw" : "mvn"
        let hasGradlew = fm.fileExists(atPath: projectURL.appendingPathComponent("gradlew").path)
        let gradleCmd = hasGradlew ? "./gradlew" : "gradle"
        let hasPom = fm.fileExists(atPath: projectURL.appendingPathComponent("pom.xml").path)
        let hasGradle = fm.fileExists(atPath: projectURL.appendingPathComponent("build.gradle").path) ||
                         fm.fileExists(atPath: projectURL.appendingPathComponent("build.gradle.kts").path) || hasGradlew

        var results: [RunConfiguration] = []

        func add(_ name: String, _ command: String, workingDir: String = projectURL.path) {
            guard !results.contains(where: { $0.name == name }) else { return }
            results.append(RunConfiguration(name: name, command: command, workingDirectory: workingDir))
        }

        // Prioritize actual runnable applications (Spring Boot, Application, Go, Python, Node) before tests (JUnit)
        let sortedConfigs = rawConfigs.sorted { c1, c2 in
            let isTest1 = c1.type == "JUnit"
            let isTest2 = c2.type == "JUnit"
            if isTest1 != isTest2 { return !isTest1 }
            return false
        }

        for raw in sortedConfigs {
            switch raw.type {
            case "SpringBootApplicationConfigurationType":
                var flags: [String] = []
                if !raw.activeProfiles.isEmpty {
                    flags.append("-Dspring-boot.run.profiles=\(raw.activeProfiles)")
                }
                if !raw.vmParameters.isEmpty {
                    flags.append("-Dspring-boot.run.jvmArguments=\"\(raw.vmParameters)\"")
                }
                if !raw.programParameters.isEmpty {
                    flags.append("-Dspring-boot.run.arguments=\"\(raw.programParameters)\"")
                }
                if !raw.mainClass.isEmpty {
                    flags.append("-Dspring-boot.run.main-class=\(raw.mainClass)")
                }
                let flagsStr = flags.isEmpty ? "" : " " + flags.joined(separator: " ")

                if hasPom {
                    if !raw.module.isEmpty && raw.module != projectURL.lastPathComponent {
                        // Multi-module Spring Boot project: build dependencies then run
                        add("IDEA: \(raw.name)", "\(mvnCmd) install -DskipTests -am -pl \(raw.module) && \(mvnCmd) -pl \(raw.module) spring-boot:run\(flagsStr)")
                        add("IDEA: \(raw.name) (fast run)", "\(mvnCmd) -pl \(raw.module) spring-boot:run\(flagsStr)")
                    } else {
                        add("IDEA: \(raw.name)", "\(mvnCmd) spring-boot:run\(flagsStr)")
                    }
                } else if hasGradle {
                    if !raw.module.isEmpty && raw.module != projectURL.lastPathComponent {
                        add("IDEA: \(raw.name)", "\(gradleCmd) :\(raw.module):bootRun")
                    } else {
                        add("IDEA: \(raw.name)", "\(gradleCmd) bootRun")
                    }
                }

            case "Application":
                if !raw.mainClass.isEmpty {
                    if hasPom {
                        let modFlag = (!raw.module.isEmpty && raw.module != projectURL.lastPathComponent) ? "-pl \(raw.module) " : ""
                        let vmFlag = raw.vmParameters.isEmpty ? "" : " -Dexec.args=\"\(raw.vmParameters)\""
                        add("IDEA: \(raw.name)", "\(mvnCmd) \(modFlag)compile exec:java -Dexec.mainClass=\"\(raw.mainClass)\"\(vmFlag)")
                    } else if hasGradle {
                        let modPrefix = (!raw.module.isEmpty && raw.module != projectURL.lastPathComponent) ? ":\(raw.module)" : ""
                        add("IDEA: \(raw.name)", "\(gradleCmd) \(modPrefix):run")
                    }
                }

            case "JUnit":
                if !raw.mainClass.isEmpty {
                    let target = raw.testMethod.isEmpty ? raw.mainClass : "\(raw.mainClass)#\(raw.testMethod)"
                    if hasPom {
                        let modFlag = (!raw.module.isEmpty && raw.module != projectURL.lastPathComponent) ? "-pl \(raw.module) " : ""
                        add("IDEA Test: \(raw.name)", "\(mvnCmd) \(modFlag)test -Dtest=\"\(target)\"")
                    } else if hasGradle {
                        let modPrefix = (!raw.module.isEmpty && raw.module != projectURL.lastPathComponent) ? ":\(raw.module)" : ""
                        add("IDEA Test: \(raw.name)", "\(gradleCmd) \(modPrefix):test --tests \"\(target)\"")
                    }
                }

            case "GoApplicationRunConfiguration":
                let script = cleanPath(raw.scriptPath, projectURL: projectURL)
                if !script.isEmpty {
                    add("IDEA: \(raw.name)", "go run \(script)")
                } else {
                    add("IDEA: \(raw.name)", "go run .")
                }

            case "PythonConfigurationType":
                let script = cleanPath(raw.scriptPath, projectURL: projectURL)
                let target = script.isEmpty ? "main.py" : script
                let args = raw.programParameters.isEmpty ? "" : " \(raw.programParameters)"
                add("IDEA: \(raw.name)", "python3 \(target)\(args)")

            case "NodeJSConfigurationType":
                let script = cleanPath(raw.scriptPath, projectURL: projectURL)
                let target = script.isEmpty ? "index.js" : script
                let args = raw.programParameters.isEmpty ? "" : " \(raw.programParameters)"
                add("IDEA: \(raw.name)", "node \(target)\(args)")

            case "js.build_tools.npm":
                if !raw.scriptPath.isEmpty {
                    add("IDEA: \(raw.name)", "npm run \(raw.scriptPath)")
                }

            default:
                break
            }
        }

        return results
    }

    private static func cleanPath(_ path: String, projectURL: URL) -> String {
        var clean = path.replacingOccurrences(of: "$PROJECT_DIR$/", with: "")
                        .replacingOccurrences(of: "$PROJECT_DIR$", with: "")
        if clean.hasPrefix(projectURL.path + "/") {
            clean = String(clean.dropFirst(projectURL.path.count + 1))
        }
        return clean
    }
}

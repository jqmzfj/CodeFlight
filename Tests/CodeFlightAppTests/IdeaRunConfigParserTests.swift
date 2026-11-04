import XCTest
import Foundation
@testable import CodeFlightApp

final class IdeaRunConfigParserTests: XCTestCase {
    func testParseRunManagerSpringBootAndJUnit() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <project version="4">
          <component name="RunManager" selected="SpringBootApplicationConfigurationType.GzldSystemApplication">
            <configuration name="SysUserControllerTest.testMethod" type="JUnit" factoryName="JUnit" temporary="true">
              <module name="gzld-system" />
              <option name="MAIN_CLASS_NAME" value="com.gzld.modules.system.controller.SysUserControllerTest" />
              <option name="METHOD_NAME" value="testMethod" />
            </configuration>
            <configuration name="GzldSystemApplication" type="SpringBootApplicationConfigurationType" factoryName="Spring Boot">
              <module name="gzld-admin" />
              <option name="SPRING_BOOT_MAIN_CLASS" value="com.gzld.GzldSystemApplication" />
              <option name="ACTIVE_PROFILES" value="dev" />
              <option name="VM_PARAMETERS" value="-Xmx512m" />
            </configuration>
          </component>
        </project>
        """

        let configs = IdeaRunConfigParser.parseRunManager(from: xml)
        XCTAssertEqual(configs.count, 2)

        let junit = try XCTUnwrap(configs.first { $0.type == "JUnit" })
        XCTAssertEqual(junit.name, "SysUserControllerTest.testMethod")
        XCTAssertEqual(junit.module, "gzld-system")
        XCTAssertEqual(junit.mainClass, "com.gzld.modules.system.controller.SysUserControllerTest")
        XCTAssertEqual(junit.testMethod, "testMethod")

        let boot = try XCTUnwrap(configs.first { $0.type == "SpringBootApplicationConfigurationType" })
        XCTAssertEqual(boot.name, "GzldSystemApplication")
        XCTAssertEqual(boot.module, "gzld-admin")
        XCTAssertEqual(boot.mainClass, "com.gzld.GzldSystemApplication")
        XCTAssertEqual(boot.activeProfiles, "dev")
        XCTAssertEqual(boot.vmParameters, "-Xmx512m")
    }

    func testDetectMapsSpringBootMultiModuleMavenCorrectly() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("idea-test-" + UUID().uuidString)
        let ideaDir = tempDir.appendingPathComponent(".idea")
        try FileManager.default.createDirectory(at: ideaDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Root pom.xml
        try "<project><modelVersion>4.0.0</modelVersion><groupId>com.test</groupId><artifactId>root</artifactId><version>1.0</version></project>"
            .write(to: tempDir.appendingPathComponent("pom.xml"), atomically: true, encoding: .utf8)

        // .idea/workspace.xml
        let workspaceXml = """
        <project version="4">
          <component name="RunManager">
            <configuration name="BackendApp" type="SpringBootApplicationConfigurationType" factoryName="Spring Boot">
              <module name="server-module" />
              <option name="SPRING_BOOT_MAIN_CLASS" value="com.test.ServerApplication" />
              <option name="ACTIVE_PROFILES" value="prod" />
            </configuration>
          </component>
        </project>
        """
        try workspaceXml.write(to: ideaDir.appendingPathComponent("workspace.xml"), atomically: true, encoding: .utf8)

        let detected = IdeaRunConfigParser.detect(at: tempDir)
        XCTAssertEqual(detected.count, 2)
        XCTAssertEqual(detected[0].name, "IDEA: BackendApp")
        XCTAssertTrue(detected[0].command.contains("mvn install -DskipTests -am -pl server-module"))
        XCTAssertTrue(detected[0].command.contains("mvn -pl server-module spring-boot:run"))
        XCTAssertTrue(detected[0].command.contains("-Dspring-boot.run.profiles=prod"))
        XCTAssertTrue(detected[0].command.contains("-Dspring-boot.run.main-class=com.test.ServerApplication"))

        XCTAssertEqual(detected[1].name, "IDEA: BackendApp (fast run)")
        XCTAssertTrue(detected[1].command.hasPrefix("mvn -pl server-module spring-boot:run"))
    }

    func testParseRunConfigurationsDirectoryGoAndPython() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("idea-polyglot-" + UUID().uuidString)
        let ideaDir = tempDir.appendingPathComponent(".idea")
        let runConfigsDir = ideaDir.appendingPathComponent("runConfigurations")
        try FileManager.default.createDirectory(at: runConfigsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let goXml = """
        <component name="ProjectRunConfigurationManager">
          <configuration name="Go API" type="GoApplicationRunConfiguration" factoryName="Go Application">
            <filePath value="$PROJECT_DIR$/cmd/server/main.go" />
          </configuration>
        </component>
        """
        try goXml.write(to: runConfigsDir.appendingPathComponent("Go_API.xml"), atomically: true, encoding: .utf8)

        let pyXml = """
        <component name="ProjectRunConfigurationManager">
          <configuration name="Python Worker" type="PythonConfigurationType" factoryName="Python">
            <option name="SCRIPT_NAME" value="$PROJECT_DIR$/worker.py" />
            <option name="PARAMETERS" value="--concurrency 4" />
          </configuration>
        </component>
        """
        try pyXml.write(to: runConfigsDir.appendingPathComponent("Python_Worker.xml"), atomically: true, encoding: .utf8)

        let detected = IdeaRunConfigParser.detect(at: tempDir)
        XCTAssertEqual(detected.count, 2)

        let goConfig = try XCTUnwrap(detected.first { $0.name == "IDEA: Go API" })
        XCTAssertEqual(goConfig.command, "go run cmd/server/main.go")

        let pyConfig = try XCTUnwrap(detected.first { $0.name == "IDEA: Python Worker" })
        XCTAssertEqual(pyConfig.command, "python3 worker.py --concurrency 4")
    }

    func testDetectOnMoePortalIfPresent() {
        let moeURL = URL(fileURLWithPath: "/Users/wangzihao/WZHCode/work/moe-portal/moe-portal")
        guard FileManager.default.fileExists(atPath: moeURL.appendingPathComponent(".idea/workspace.xml").path) else { return }

        let detected = IdeaRunConfigParser.detect(at: moeURL)
        XCTAssertTrue(detected.contains { $0.name.contains("GzldSystemApplication") })
    }
}

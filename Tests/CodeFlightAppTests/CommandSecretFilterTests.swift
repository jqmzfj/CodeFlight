import XCTest
@testable import CodeFlightApp

final class CommandSecretFilterTests: XCTestCase {
    private let environment = ["CODEFLIGHT_AUTH_USER": "fixture-user", "CODEFLIGHT_AUTH_SECRET": "fixture-secret/中文"]

    func testEveryChunkBoundaryRedactsLiteralEncodedAndBasicWithoutChangingOrdinaryOutput() {
        let secret = environment["CODEFLIGHT_AUTH_SECRET"]!
        let encoded = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
        let basic = Data(("fixture-user:" + secret).utf8).base64EncodedString()
        let text = "before \(secret) middle \(encoded) Basic \(basic) after"
        for offset in 0...text.count {
            let index = text.index(text.startIndex, offsetBy: offset)
            var filter = CommandSecretFilter(environment: environment)
            let output = filter.append(String(text[..<index])) + filter.append(String(text[index...])) + filter.append("", final: true)
            XCTAssertEqual(output, "before [REDACTED] middle [REDACTED] Basic [REDACTED] after", "offset \(offset)")
        }
        var filter = CommandSecretFilter(environment: environment)
        var scalarOutput = ""
        for scalar in text.unicodeScalars { scalarOutput += filter.append(String(scalar)) }
        scalarOutput += filter.append("", final: true)
        XCTAssertFalse(scalarOutput.contains(secret))
        XCTAssertEqual(CommandSecretFilter.redact("normal file names 中文", environment: environment), "normal file names 中文")
        XCTAssertEqual(CommandSecretFilter.redact(text, environment: [:]), text)
    }

    @MainActor func testRealPipeStreamingAndFinalResultDoNotExposeTemporaryCredentials() async {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = OutputAccumulator()
        let env = ["CODEFLIGHT_AUTH_USER": "fixture-user", "CODEFLIGHT_AUTH_SECRET": "fixture-secret"]
        let result = await CommandRunner.run(command: "printf fixture-; sleep 0.1; printf secret; printf '%s' \"$CODEFLIGHT_AUTH_SECRET\" >&2", cwd: root.path, environment: env) { output.append(Data($0.utf8)) }
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.output.contains("fixture-secret"))
        XCTAssertFalse(output.text().contains("fixture-secret"))
        XCTAssertEqual(result.output, "[REDACTED][REDACTED]")
        XCTAssertEqual(output.text(), "[REDACTED][REDACTED]")
    }

    @MainActor func testConsoleRedactsLegacyURLCredentialsBeforeErrorAndCopyableHistory() {
        let model = WorkbenchModel(restoringSession: false)
        let project = Project(name: "fixture", path: "/tmp")
        model.projects = [project]; model.selectedProjectID = project.id
        let id = model.beginGitConsoleEntry(projectID: project.id, title: "Fetch")
        let text = "fatal: https://legacy-user:legacy-password@example.com/repo.git?access_token=legacy-token#private\nssh://git@example.com/repo.git\nSee https://example.com/help"
        model.finishGitConsoleEntry(id, projectID: project.id, result: CommandResult(output: text, status: 128), presentError: true)
        for value in [model.errorMessage ?? "", model.selectedGitConsoleEntry?.output ?? ""] {
            for secret in ["legacy-user", "legacy-password", "legacy-token", "#private"] { XCTAssertFalse(value.contains(secret)) }
            XCTAssertTrue(value.contains("https://example.com/help"))
        }
    }
}

import SwiftUI
import Foundation

struct GitCredentials: Sendable {
    var username = ""
    var secret = ""
    var enabled: Bool { !secret.isEmpty }
    // Clearing credential.helper for this invocation prevents Git from saving
    // these temporary credentials through the user's configured helper.
    var git: String { enabled ? "git -c credential.helper=" : "git" }
    static var helperPath: String {
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("GitAskpass.sh"), FileManager.default.isExecutableFile(atPath: resource.path) { return resource.path }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("AppResources/GitAskpass.sh").path
    }
    var environment: [String: String] {
        var values = ["GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"]
        if enabled {
            values["GIT_ASKPASS"] = Self.helperPath
            values["CODEFLIGHT_AUTH_USER"] = username
            values["CODEFLIGHT_AUTH_SECRET"] = secret
        }
        return values
    }
}

struct GitCredentialsFields: View {
    let language: AppLanguage
    @Binding var credentials: GitCredentials
    @State private var expanded = false
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: language) }
    var body: some View {
        DisclosureGroup(text("HTTP 身份验证（可选）", "HTTP authentication (optional)"), isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(text("用户名", "Username"), text: $credentials.username).textFieldStyle(.roundedBorder)
                SecureField(text("密码或访问令牌", "Password or access token"), text: $credentials.secret).textFieldStyle(.roundedBorder)
                Text(text("仅本次使用，不保存。留空则使用本机 Git 凭据或 SSH 配置。", "Used for this operation only. Leave blank to use local Git credentials or SSH.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.top, 8)
        }.font(.system(size: 11))
    }
}

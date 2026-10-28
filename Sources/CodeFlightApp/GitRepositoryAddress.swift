import Foundation

/// Addresses saved to Git config must not contain temporary HTTP credentials.
enum GitRepositoryAddress {
    static func validationError(_ source: String) -> String? {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !source.hasPrefix("-"), !source.contains(where: { $0.isNewline || $0 == "\0" }), !source.contains("::") else {
            return "请输入有效的 Git 仓库地址。 / Enter a valid Git repository address."
        }
        if source.contains("://") {
            guard let url = URLComponents(string: source), url.host != nil else {
                return "仓库地址格式无效。 / Invalid repository address format."
            }
            guard ["http", "https", "ssh", "git", "file"].contains(url.scheme?.lowercased() ?? ""), url.password == nil,
                  url.query == nil, url.fragment == nil,
                  !(["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.user != nil) else {
                return "地址不能包含密码、HTTP 用户凭据或查询令牌，请使用临时身份验证。 / Remove credentials and query tokens from the address; use temporary authentication."
            }
        }
        return nil
    }
}

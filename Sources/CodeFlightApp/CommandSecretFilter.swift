import Foundation

/// Filters temporary Git authentication before output reaches a view. The
/// uncommitted suffix prevents a credential split across pipe reads leaking.
struct CommandSecretFilter {
    private let secrets: [String]
    private var pending = ""

    init(environment: [String: String]) {
        guard let secret = environment["CODEFLIGHT_AUTH_SECRET"], !secret.isEmpty else { secrets = []; return }
        let basic = Data(((environment["CODEFLIGHT_AUTH_USER"] ?? "") + ":" + secret).utf8).base64EncodedString()
        var values = Set([secret, basic])
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        if let encoded = secret.addingPercentEncoding(withAllowedCharacters: safe) { values.insert(encoded) }
        secrets = values.sorted { $0.count > $1.count }
    }

    mutating func append(_ text: String, final: Bool = false) -> String {
        guard !secrets.isEmpty else { return text }
        let input = pending + text
        pending = ""
        var result = ""
        var index = input.startIndex
        while index < input.endIndex {
            let rest = input[index...]
            if let match = secrets.first(where: { rest.hasPrefix($0) }) {
                result += "[REDACTED]"
                index = input.index(index, offsetBy: match.count)
            } else if !final, secrets.contains(where: { $0.hasPrefix(rest) }) {
                pending = String(rest)
                break
            } else {
                result.append(input[index]); index = input.index(after: index)
            }
        }
        return result
    }

    static func redact(_ text: String, environment: [String: String]) -> String {
        var filter = Self(environment: environment)
        return filter.append(text, final: true)
    }
}

enum GitDiagnosticRedactor {
    /// Git may echo a legacy remote URL containing embedded credentials. This
    /// applies only to human-facing diagnostics, never to Git protocol data.
    static func redact(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)\b(?:https?|ssh|git)://[^\s<>\"']+"#) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            var value = String(result[range])
            if let authorityEnd = value.range(of: "://")?.upperBound {
                let hostEnd = value[authorityEnd...].firstIndex(where: { "/?#".contains($0) }) ?? value.endIndex
                if let at = value[authorityEnd..<hostEnd].lastIndex(of: "@") {
                    value.replaceSubrange(authorityEnd...at, with: "[REDACTED]@")
                }
            }
            if let query = value.firstIndex(where: { $0 == "?" || $0 == "#" }) {
                value.replaceSubrange(query..., with: "?[REDACTED]")
            }
            result.replaceSubrange(range, with: value)
        }
        return result
    }
}

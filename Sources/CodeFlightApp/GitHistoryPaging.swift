import Foundation
import CryptoKit

struct GitHistoryPage: Sendable {
    var commits: [GitCommit] = []
    var revision: String?
    var hasMore = false
    var error: String?
    var requiresRefresh = false
}

extension GitService {
    private static func historyRevision(at path: String) async -> (token: String?, hasHead: Bool, error: String?) {
        let refs = await CommandRunner.run(command: "git show-ref --head --dereference", cwd: path, outputLimit: 2 * 1024 * 1024)
        guard (refs.status == 0 || (refs.status == 1 && refs.output.isEmpty)), !refs.truncated else {
            return (nil, false, refs.truncated ? "分支引用超过读取限制。 / Repository refs exceed the read limit." : refs.output)
        }
        let branch = await CommandRunner.run(command: "git symbolic-ref -q HEAD", cwd: path)
        guard branch.status == 0 || branch.status == 1 else { return (nil, false, branch.output) }
        let token = SHA256.hash(data: Data((refs.output + "\0" + branch.output).utf8)).map { String(format: "%02x", $0) }.joined()
        let hasHead = refs.output.split(whereSeparator: \.isNewline).contains { $0.split(separator: " ").last == "HEAD" }
        return (token, hasHead, nil)
    }

    /// Author and date filters run in Git so paging, "load older" and the
    /// revision check all apply to the filtered history instead of a single
    /// loaded page.
    private static func historyFilterArguments(author: String?, since: String?, until: String?) -> String? {
        var arguments = ""
        if let author, !author.isEmpty {
            guard author.count <= 200, !author.contains("\0"), !author.contains("\n") else { return nil }
            // --author is a regular expression; a literal name must not become one.
            arguments += "--author=\(Shell.quote(NSRegularExpression.escapedPattern(for: author))) --regexp-ignore-case "
        }
        for value in [since, until].compactMap({ $0 }) {
            guard !value.contains("\0"), !value.contains("\n"),
                  value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { return nil }
        }
        // A bare "yyyy-MM-dd" is parsed as UTC midnight by Git, which shifts the
        // boundary for every other time zone. An explicit local midnight keeps
        // the filter aligned with the dates shown in the log.
        if let since { arguments += "--since=\(Shell.quote(since + "T00:00:00")) " }
        if let until { arguments += "--until=\(Shell.quote(until + "T00:00:00")) " }
        return arguments
    }

    /// Author names for the log filter menu. Bounded so a large repository
    /// cannot turn a menu into an unbounded read.
    static func authors(at path: String, limit: Int = 500) async -> [String] {
        let result = await CommandRunner.run(command: "git --no-pager log -n \(max(1, min(limit, 2_000))) --no-merges --format=%an --", cwd: path,
                                             outputLimit: 256 * 1024, timeoutSeconds: 15)
        guard result.status == 0, !result.truncated else { return [] }
        var seen = Set<String>()
        var values: [String] = []
        for line in result.output.split(whereSeparator: \.isNewline) {
            let name = String(line).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, seen.insert(name).inserted { values.append(name) }
        }
        return values.sorted { $0.localizedStandardCompare($1) != .orderedDescending }
    }

    static func historyPage(at path: String, skip: Int = 0, allBranches: Bool = false, expectedRevision: String? = nil, reference: String? = nil,
                            author: String? = nil, since: String? = nil, until: String? = nil) async -> GitHistoryPage {
        if let reference {
            guard ["refs/heads/", "refs/remotes/", "refs/tags/"].contains(where: { reference.hasPrefix($0) }),
                  !reference.contains("\0"), !reference.contains("\n") else {
                return GitHistoryPage(error: "历史分支引用无效。 / Invalid history reference.")
            }
            let valid = await CommandRunner.run(command: "git check-ref-format \(Shell.quote(reference))", cwd: path)
            guard valid.status == 0 else { return GitHistoryPage(error: "历史分支引用无效。 / Invalid history reference.") }
        }
        guard let filterArguments = historyFilterArguments(author: author, since: since, until: until) else {
            return GitHistoryPage(error: "历史筛选条件无效。 / Invalid history filter.")
        }
        let before = await historyRevision(at: path)
        guard let refsRevision = before.token else { return GitHistoryPage(error: before.error ?? "无法读取仓库。 / Cannot read repository.") }
        let revision = refsRevision + "|" + (reference ?? (allBranches ? "--all" : "HEAD")) + "|" + filterArguments
        func changed() -> GitHistoryPage {
            GitHistoryPage(error: "提交历史或分支引用已变化，请刷新后继续。 / History or branch refs changed. Refresh before continuing.", requiresRefresh: true)
        }
        if let expectedRevision, expectedRevision != revision { return changed() }
        if reference == nil && !allBranches && !before.hasHead { return GitHistoryPage(revision: revision) }
        let result = await CommandRunner.run(command: "git --no-pager log \(reference.map { Shell.quote($0) + " " } ?? (allBranches ? "--all " : ""))--topo-order -z --skip=\(max(0, skip)) -n 51 --date=iso-strict \(filterArguments)--format='%H%x00%s%x00%an%x00%ad%x00%P%x00%D' --", cwd: path, outputLimit: 2 * 1024 * 1024)
        guard result.status == 0, !result.truncated else {
            return GitHistoryPage(error: result.truncated ? "提交列表超过单页读取限制。 / Commit page exceeds the read limit." : result.output)
        }
        let after = await historyRevision(at: path)
        guard let afterRevision = after.token else { return GitHistoryPage(error: after.error ?? "无法读取仓库。 / Cannot read repository.") }
        guard refsRevision == afterRevision else { return changed() }
        let fields = result.output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var commits: [GitCommit] = []
        for index in stride(from: 0, to: max(0, fields.count - 5), by: 6) {
            guard [40, 64].contains(fields[index].count), fields[index].allSatisfy(\.isHexDigit) else {
                return GitHistoryPage(error: "无法解析提交列表。 / Cannot parse commit list.")
            }
            commits.append(GitCommit(hash: fields[index], subject: fields[index + 1], author: fields[index + 2], date: fields[index + 3], parents: fields[index + 4].split(separator: " ").map(String.init), refs: fields[index + 5].components(separatedBy: ", ").filter { !$0.isEmpty }))
        }
        return GitHistoryPage(commits: Array(commits.prefix(50)), revision: revision, hasMore: commits.count > 50)
    }
}

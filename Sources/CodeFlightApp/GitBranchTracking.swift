import SwiftUI

struct GitBranchTracking: Equatable, Sendable {
    var upstream: String?
    var ahead: Int?
    var behind: Int?
    var gone = false
    var detached = false
    var unborn = false
}

extension GitService {
    static func parseBranchHeader(_ record: String) -> (branch: String, tracking: GitBranchTracking) {
        var body = record.hasPrefix("## ") ? String(record.dropFirst(3)) : record
        var tracking = GitBranchTracking()
        for prefix in ["No commits yet on ", "Initial commit on "] where body.hasPrefix(prefix) {
            tracking.unborn = true
            body = String(body.dropFirst(prefix.count))
            break
        }
        if body == "HEAD (no branch)" {
            tracking.detached = true
            return (body, tracking)
        }
        guard let split = body.range(of: "...") else { return (body, tracking) }
        let branch = String(body[..<split.lowerBound])
        let remainder = String(body[split.upperBound...])
        let metadata = remainder.range(of: " [")
        tracking.upstream = metadata.map { String(remainder[..<$0.lowerBound]) } ?? remainder
        if let metadata {
            let suffix = String(remainder[metadata.upperBound...].dropLast(remainder.hasSuffix("]") ? 1 : 0))
            if suffix == "gone" { tracking.gone = true }
            else {
                var ahead = 0, behind = 0, valid = true
                for entry in suffix.components(separatedBy: ", ") {
                    if entry.hasPrefix("ahead "), let count = Int(entry.dropFirst(6)), count >= 0 { ahead = count }
                    else if entry.hasPrefix("behind "), let count = Int(entry.dropFirst(7)), count >= 0 { behind = count }
                    else { valid = false }
                }
                if valid { tracking.ahead = ahead; tracking.behind = behind }
            }
        } else { tracking.ahead = 0; tracking.behind = 0 }
        return (branch, tracking)
    }
}

struct GitTrackingSummary: View {
    let tracking: GitBranchTracking
    let language: AppLanguage
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: language) }
    var body: some View {
        HStack(spacing: 7) {
            if tracking.unborn {
                Text(text("尚无提交", "No commits yet"))
            } else if tracking.detached {
                Label(text("分离 HEAD", "Detached HEAD"), systemImage: "point.topleft.down.curvedto.point.bottomright.up")
            } else if let upstream = tracking.upstream {
                Text(upstream).lineLimit(1).truncationMode(.middle).help(upstream)
                Spacer(minLength: 0)
                if tracking.gone { Text(text("跟踪引用已失效", "Upstream gone")).foregroundStyle(.orange) }
                else if let ahead = tracking.ahead, let behind = tracking.behind {
                    if ahead > 0 { Text("↑ \(ahead)").foregroundStyle(Color.accentColor).help(text("领先 \(ahead) 个提交，可推送", "Ahead by \(ahead) commits; ready to push")) }
                    if behind > 0 { Text("↓ \(behind)").foregroundStyle(.orange).help(text("落后 \(behind) 个提交，可拉取", "Behind by \(behind) commits; ready to pull")) }
                    if ahead == 0 && behind == 0 { Text(text("已获取版本一致", "Fetched refs match")) }
                } else { Text(text("状态未知", "Status unknown")) }
            } else { Text(text("未设置跟踪分支", "No upstream branch")) }
        }.font(.system(size: 10)).foregroundStyle(.secondary)
            .help(text("基于本地已获取的跟踪引用；Fetch 后更新，不会自动访问网络。", "Based on locally fetched tracking refs. Fetch to update; no automatic network access."))
    }
}

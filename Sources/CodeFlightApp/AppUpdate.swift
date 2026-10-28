import Foundation

struct CodeFlightRelease: Decodable, Sendable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let assets: [Asset]

    struct Asset: Decodable, Sendable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body
        case htmlURL = "html_url"
        case assets
    }
}

enum CodeFlightUpdateCheckResult: Sendable {
    case current
    case available(release: CodeFlightRelease, downloadURL: URL)
}

enum CodeFlightUpdateError: LocalizedError, Sendable {
    case invalidResponse
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "无法读取 GitHub Release 信息。"
        case .unavailable: return "暂时无法连接 GitHub，请稍后重试。"
        }
    }
}

enum CodeFlightUpdater {
    static let repositoryURL = URL(string: "https://api.github.com/repos/jqmzfj/CodeFlight/releases/latest")!
    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

    static func check() async throws -> CodeFlightUpdateCheckResult {
        var request = URLRequest(url: repositoryURL)
        request.setValue("CodeFlight/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw CodeFlightUpdateError.unavailable
        }
        let release: CodeFlightRelease
        do {
            release = try JSONDecoder().decode(CodeFlightRelease.self, from: data)
        } catch {
            throw CodeFlightUpdateError.invalidResponse
        }
        guard isNewer(release.tagName, than: currentVersion) else { return .current }
        let preferred = release.assets.first(where: { $0.name.hasSuffix(".dmg") })
            ?? release.assets.first(where: { $0.name.hasSuffix(".zip") })
        return .available(release: release, downloadURL: preferred?.browserDownloadURL ?? release.htmlURL)
    }

    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        func components(_ value: String) -> [Int] {
            value.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".")
                .map { Int($0.split(whereSeparator: { !$0.isNumber }).first ?? "0") ?? 0 }
        }
        let lhs = components(candidate), rhs = components(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}

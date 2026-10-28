import SwiftUI

struct GitGraphRow {
    struct Edge { let from: Int; let to: Int; let lane: Int }
    let lane: Int
    let hasIncoming: Bool
    let through: [Edge]
    let parents: [Int]
    let width: Int
}

enum GitGraphLayout {
    static func rows(_ commits: [GitCommit]) -> [String: GitGraphRow] {
        var lanes: [String] = []
        var result: [String: GitGraphRow] = [:]
        for commit in commits {
            let existing = lanes.firstIndex(of: commit.hash)
            let lane = existing ?? lanes.count
            if existing == nil { lanes.append(commit.hash) }
            let before = lanes
            lanes.remove(at: lane)
            var insertion = min(lane, lanes.count)
            for parent in commit.parents where !lanes.contains(parent) {
                lanes.insert(parent, at: insertion)
                insertion += 1
            }
            let through = before.enumerated().compactMap { index, hash -> GitGraphRow.Edge? in
                guard hash != commit.hash, let target = lanes.firstIndex(of: hash) else { return nil }
                return .init(from: index, to: target, lane: index)
            }
            result[commit.hash] = GitGraphRow(lane: lane, hasIncoming: existing != nil, through: through,
                                             parents: commit.parents.compactMap { lanes.firstIndex(of: $0) }, width: max(before.count, lanes.count))
        }
        return result
    }
}

struct GitGraphCell: View {
    static let rowHeight: CGFloat = 24
    let row: GitGraphRow
    let columns: Int
    // Native Table adds four points above and below each cell. Extend the
    // drawing through those insets without increasing the content row height.
    var verticalOverflow: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    private var palette: [Color] {
        // JetBrains keeps VCS lanes muted and stable: gold for the primary
        // lane, then restrained purple/olive/gray accents for branches.
        if colorScheme == .dark {
            return [
                Color(red: 0.74, green: 0.58, blue: 0.22),
                Color(red: 0.58, green: 0.48, blue: 0.72),
                Color(red: 0.45, green: 0.58, blue: 0.34),
                Color(red: 0.55, green: 0.55, blue: 0.55),
                Color(red: 0.72, green: 0.43, blue: 0.26),
                Color(red: 0.36, green: 0.62, blue: 0.62)
            ]
        }
        return [
            Color(red: 0.64, green: 0.44, blue: 0.10),
            Color(red: 0.42, green: 0.32, blue: 0.62),
            Color(red: 0.28, green: 0.50, blue: 0.28),
            Color(red: 0.42, green: 0.42, blue: 0.42),
            Color(red: 0.68, green: 0.34, blue: 0.17),
            Color(red: 0.22, green: 0.48, blue: 0.50)
        ]
    }
    private func x(_ lane: Int) -> CGFloat { CGFloat(min(lane, 11)) * 12 + 8 }
    var body: some View {
        Canvas { context, size in
            func edge(_ from: CGPoint, _ to: CGPoint, color: Color) {
                var path = Path(); path.move(to: from)
                let middle = (from.y + to.y) / 2
                path.addCurve(to: to, control1: CGPoint(x: from.x, y: middle), control2: CGPoint(x: to.x, y: middle))
                context.stroke(path, with: .color(color.opacity(0.7)), lineWidth: 1.4)
            }
            let center = CGPoint(x: x(row.lane), y: size.height / 2)
            for line in row.through { edge(CGPoint(x: x(line.from), y: 0), CGPoint(x: x(line.to), y: size.height), color: palette[line.lane % palette.count]) }
            if row.hasIncoming { edge(CGPoint(x: center.x, y: 0), center, color: palette[row.lane % palette.count]) }
            for lane in row.parents { edge(center, CGPoint(x: x(lane), y: size.height), color: palette[lane % palette.count]) }
            let dot = CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: dot), with: .color(palette[row.lane % palette.count]))
        }.frame(width: CGFloat(min(max(1, columns), 12)) * 12 + 4, height: Self.rowHeight + verticalOverflow * 2)
            .padding(.vertical, -verticalOverflow).accessibilityHidden(true)
    }
}

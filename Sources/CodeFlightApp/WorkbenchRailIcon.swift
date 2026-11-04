import SwiftUI

/// The rail uses a single optical size and stroke, independent of SF Symbol metrics.
struct WorkbenchRailIcon: View {
    enum Kind {
        case files, commit, run, services, terminal, history

        init(_ tool: BottomTool) {
            switch tool {
            case .processes: self = .run
            case .services: self = .services
            case .console: self = .terminal
            case .gitTree: self = .history
            }
        }
    }

    let kind: Kind

    var body: some View {
        Glyph(kind: kind)
            .stroke(style: StrokeStyle(lineWidth: 1.45, lineCap: .round, lineJoin: .round))
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }

    private struct Glyph: Shape {
        let kind: Kind

        func path(in rect: CGRect) -> Path {
            // Draw on a common 20-point grid, with padding for round line caps.
            var p = Path()
            func line(_ points: CGPoint...) {
                guard let first = points.first else { return }
                p.move(to: first)
                for point in points.dropFirst() { p.addLine(to: point) }
            }
            switch kind {
            case .files:
                p.move(to: CGPoint(x: 2, y: 6))
                p.addLine(to: CGPoint(x: 2, y: 4))
                p.addQuadCurve(to: CGPoint(x: 4, y: 2), control: CGPoint(x: 2, y: 2))
                p.addLine(to: CGPoint(x: 8, y: 2))
                p.addLine(to: CGPoint(x: 10, y: 5))
                p.addLine(to: CGPoint(x: 16, y: 5))
                p.addQuadCurve(to: CGPoint(x: 18, y: 7), control: CGPoint(x: 18, y: 5))
                p.addLine(to: CGPoint(x: 18, y: 16))
                p.addQuadCurve(to: CGPoint(x: 16, y: 18), control: CGPoint(x: 18, y: 18))
                p.addLine(to: CGPoint(x: 4, y: 18))
                p.addQuadCurve(to: CGPoint(x: 2, y: 16), control: CGPoint(x: 2, y: 18))
                p.addLine(to: CGPoint(x: 2, y: 6))
                line(CGPoint(x: 2, y: 7), CGPoint(x: 18, y: 7))
            case .commit:
                p.addRoundedRect(in: CGRect(x: 2, y: 2, width: 16, height: 16), cornerSize: CGSize(width: 4, height: 4))
                line(CGPoint(x: 6, y: 10), CGPoint(x: 9, y: 13), CGPoint(x: 14, y: 7))
            case .run:
                p.move(to: CGPoint(x: 5, y: 3))
                p.addLine(to: CGPoint(x: 17, y: 10))
                p.addLine(to: CGPoint(x: 5, y: 17))
                p.closeSubpath()
            case .services:
                for y: CGFloat in [2, 12] {
                    p.addRoundedRect(in: CGRect(x: 2, y: y, width: 16, height: 6), cornerSize: CGSize(width: 2, height: 2))
                    line(CGPoint(x: 5, y: y + 3), CGPoint(x: 5.2, y: y + 3))
                    line(CGPoint(x: 10, y: y + 3), CGPoint(x: 15, y: y + 3))
                }
            case .terminal:
                p.addRoundedRect(in: CGRect(x: 1, y: 3, width: 18, height: 14), cornerSize: CGSize(width: 3, height: 3))
                line(CGPoint(x: 5, y: 7), CGPoint(x: 8, y: 10), CGPoint(x: 5, y: 13))
                line(CGPoint(x: 11, y: 13), CGPoint(x: 15, y: 13))
            case .history:
                line(CGPoint(x: 5, y: 6), CGPoint(x: 5, y: 14))
                p.move(to: CGPoint(x: 5, y: 13))
                p.addCurve(to: CGPoint(x: 15, y: 6), control1: CGPoint(x: 5, y: 8), control2: CGPoint(x: 15, y: 11))
                for point in [CGPoint(x: 5, y: 3), CGPoint(x: 5, y: 17), CGPoint(x: 15, y: 3)] {
                    p.addEllipse(in: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5))
                }
            }
            return p.applying(CGAffineTransform(scaleX: rect.width / 20, y: rect.height / 20)
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
        }
    }
}

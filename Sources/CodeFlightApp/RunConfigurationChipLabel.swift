import SwiftUI

/// Toolbar chip for the selected run configuration. The width is measured by
/// the caller, so a long generated name (for example an imported IDEA test)
/// truncates in the middle instead of stretching the window toolbar.
struct RunConfigurationChipLabel: View {
    let name: String
    let width: CGFloat

    var body: some View {
        HStack(spacing: 5) {
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: width, alignment: .leading)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 3.5)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
    }
}

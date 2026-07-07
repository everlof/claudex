import SwiftUI

/// A simple left-to-right wrapping layout (like text runs). Used for the chart legend so
/// series chips wrap to the next line instead of clipping when there are several.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows = [[LayoutSubview]]()
        var row = [LayoutSubview]()
        var rowWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, !row.isEmpty {
                rows.append(row); row = []; rowWidth = 0
            }
            row.append(view)
            rowWidth += size.width + spacing
        }
        if !row.isEmpty { rows.append(row) }

        var height: CGFloat = 0
        for r in rows {
            let rowHeight = r.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            height += rowHeight + lineSpacing
        }
        return CGSize(width: maxWidth == .infinity ? rowWidth : maxWidth,
                      height: max(0, height - lineSpacing))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

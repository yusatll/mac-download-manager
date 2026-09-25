import HDMCore
import SwiftUI

/// The file as one bar: each segment's downloaded part is filled; segments with a live connection are brighter.
struct SegmentBar: View {
    let segments: [Segment]
    let total: Int64?
    let activeSegments: Set<Int>

    var body: some View {
        Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3), with: .color(.secondary.opacity(0.15)))
            guard let total, total > 0 else { return }
            let scale = size.width / CGFloat(total)
            for (index, segment) in segments.enumerated() where !segment.isOpenEnded {
                let x = CGFloat(segment.start) * scale
                let filled = CGRect(x: x, y: 0, width: CGFloat(segment.received) * scale, height: size.height)
                context.fill(Path(filled), with: .color(activeSegments.contains(index) ? Color.accentColor : Color.accentColor.opacity(0.55)))
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.primary.opacity(0.3)))
            }
        }
        .accessibilityLabel(Text("Segments"))
    }
}

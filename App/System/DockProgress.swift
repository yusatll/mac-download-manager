import AppKit

@MainActor
final class DockProgress {
    private let view = DockTileProgressView()

    func update(fraction: Double?, activeCount: Int) {
        let tile = NSApp.dockTile
        tile.badgeLabel = activeCount > 0 ? "\(activeCount)" : nil
        if let fraction, activeCount > 0 {
            if tile.contentView !== view {
                view.frame = NSRect(origin: .zero, size: tile.size)
                tile.contentView = view
            }
            view.fraction = fraction
        } else {
            tile.contentView = nil
        }
        tile.display()
    }
}

final class DockTileProgressView: NSView {
    var fraction: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let bar = NSRect(x: bounds.width * 0.1, y: bounds.height * 0.08, width: bounds.width * 0.8, height: bounds.height * 0.1)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
        var fill = bar.insetBy(dx: 2, dy: 2)
        fill.size.width = max(fill.height, fill.width * fraction)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: fill.height / 2, yRadius: fill.height / 2).fill()
    }
}

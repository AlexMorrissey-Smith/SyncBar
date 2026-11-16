import AppKit

/// Draws SyncBar's menu bar icon: a solid cloud with a badge punched out of
/// its lower-right corner, in the style of Dropbox's own icon.
enum MenuBarIcon {
    static let size = NSSize(width: 22, height: 18)

    /// Badge centre and radius, in points from the bottom-left.
    private static let badgeCenter = NSPoint(x: 16, y: 5.5)
    private static let badgeRadius: CGFloat = 5.5
    /// Clear gap between the badge and the cloud.
    private static let gap: CGFloat = 1.25

    /// - Parameter rotation: radians, for the spinning sync badge.
    static func image(for state: CombinedState, rotation: CGFloat = 0) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            drawCloud()
            if let badge = badgeSymbol(for: state) {
                punchHole()
                drawBadge(named: badge, rotation: state == .syncing ? rotation : 0)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = state.tooltip
        return image
    }

    private static func badgeSymbol(for state: CombinedState) -> String? {
        switch state {
        case .idle: nil
        case .paused: "pause.circle.fill"
        case .syncing: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    private static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    private static func drawCloud() {
        guard let cloud = symbol("icloud.fill", pointSize: 15, weight: .regular) else { return }
        let cloudSize = cloud.size
        let origin = NSPoint(x: (size.width - cloudSize.width) / 2 - 1, y: (size.height - cloudSize.height) / 2 + 1)
        cloud.draw(in: NSRect(origin: origin, size: cloudSize))
    }

    private static func punchHole() {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.compositingOperation = .destinationOut
        let r = badgeRadius + gap
        NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - r, y: badgeCenter.y - r, width: r * 2, height: r * 2)).fill()
        context.restoreGraphicsState()
    }

    private static func drawBadge(named name: String, rotation: CGFloat) {
        guard let badge = symbol(name, pointSize: badgeRadius * 2, weight: .bold),
              let context = NSGraphicsContext.current else { return }
        // Scale the symbol so its circle matches the badge diameter.
        let scale = (badgeRadius * 2) / max(badge.size.width, badge.size.height)
        let drawSize = NSSize(width: badge.size.width * scale, height: badge.size.height * scale)

        context.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: badgeCenter.x, yBy: badgeCenter.y)
        transform.rotate(byRadians: -rotation) // clockwise
        transform.concat()
        badge.draw(in: NSRect(x: -drawSize.width / 2, y: -drawSize.height / 2, width: drawSize.width, height: drawSize.height))
        context.restoreGraphicsState()
    }
}

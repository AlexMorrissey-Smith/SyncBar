import AppKit

// Renders the layers of SyncBar's Icon Composer icon (SyncBar/AppIcon.icon).
// macOS draws the background, squircle mask, glass and dark/tinted variants;
// these layers are plain white glyphs on a transparent 1024 px canvas.
//
//   swift Scripts/make-icon.swift SyncBar/AppIcon.icon/Assets

let outDir = URL(filePath: CommandLine.arguments[1])
let canvas = 1024

let cloudCenter = CGPoint(x: 478, y: 548)
let cloudPointSize: CGFloat = 580
let badgeCenter = CGPoint(x: 724, y: 362)
let badgeRadius: CGFloat = 178
let badgeGap: CGFloat = 38

func symbol(_ name: String, pointSize: CGFloat) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        .applying(.init(paletteColors: [.white]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}

func render(_ name: String, draw: (CGContext) -> Void) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    draw(context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: outDir.appending(path: name))
}

func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
    CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Cloud, with a ring cut out around the badge.
try render("cloud.png") { cg in
    let cloud = symbol("icloud.fill", pointSize: cloudPointSize)
    cloud.draw(in: CGRect(x: cloudCenter.x - cloud.size.width / 2, y: cloudCenter.y - cloud.size.height / 2,
                          width: cloud.size.width, height: cloud.size.height))
    cg.setBlendMode(.clear)
    cg.fillEllipse(in: circle(badgeCenter, badgeRadius + badgeGap))
}

// Badge: a solid disc with the sync arrows cut out of it.
try render("badge.png") { cg in
    cg.setFillColor(NSColor.white.cgColor)
    cg.fillEllipse(in: circle(badgeCenter, badgeRadius))
    let arrows = symbol("arrow.trianglehead.2.clockwise", pointSize: 10)
    let scale = badgeRadius * 1.3 / max(arrows.size.width, arrows.size.height)
    let w = arrows.size.width * scale, h = arrows.size.height * scale
    cg.setBlendMode(.destinationOut)
    arrows.draw(in: CGRect(x: badgeCenter.x - w / 2, y: badgeCenter.y - h / 2, width: w, height: h),
                from: .zero, operation: .destinationOut, fraction: 1)
}

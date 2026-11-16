import AppKit

// Renders SyncBar's 1024 px app icon: blue gradient squircle, white cloud,
// cut-out sync badge.
let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

// macOS icon grid: 824 px body centred, corner radius ~185.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Shadow
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
cg.addPath(path); cg.setFillColor(NSColor.black.cgColor); cg.fillPath()
cg.restoreGState()

cg.saveGState()
cg.addPath(path); cg.clip()
let colors = [NSColor(srgbRed: 0.33, green: 0.72, blue: 1.0, alpha: 1).cgColor,
              NSColor(srgbRed: 0.10, green: 0.36, blue: 0.92, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
cg.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Top sheen
let sheen = [NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray
cg.drawLinearGradient(CGGradient(colorsSpace: nil, colors: sheen, locations: [0, 1])!,
                      start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
cg.restoreGState()

func symbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        .applying(.init(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}

// Cloud, with a transparency layer so the badge can punch a hole in it.
let cloud = symbol("icloud.fill", pointSize: 470, color: .white)
let cloudRect = CGRect(x: 480 - cloud.size.width / 2, y: 490 - cloud.size.height / 2,
                       width: cloud.size.width, height: cloud.size.height)
let badgeCenter = CGPoint(x: cloudRect.maxX - 60, y: cloudRect.minY + 30)
let badgeRadius: CGFloat = 135

cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: NSColor.black.withAlphaComponent(0.18).cgColor)
cg.beginTransparencyLayer(auxiliaryInfo: nil)
cloud.draw(in: cloudRect)
cg.setBlendMode(.clear)
cg.fillEllipse(in: CGRect(x: badgeCenter.x - badgeRadius - 26, y: badgeCenter.y - badgeRadius - 26,
                          width: (badgeRadius + 26) * 2, height: (badgeRadius + 26) * 2))
cg.setBlendMode(.normal)
cg.setFillColor(NSColor.white.cgColor)
cg.fillEllipse(in: CGRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                          width: badgeRadius * 2, height: badgeRadius * 2))
let arrows = symbol("arrow.trianglehead.2.clockwise.rotate.90", pointSize: 10,
                    color: NSColor(srgbRed: 0.15, green: 0.45, blue: 0.95, alpha: 1))
let scale = badgeRadius * 1.15 / max(arrows.size.width, arrows.size.height)
let bw = arrows.size.width * scale, bh = arrows.size.height * scale
arrows.draw(in: CGRect(x: badgeCenter.x - bw / 2, y: badgeCenter.y - bh / 2, width: bw, height: bh))
cg.endTransparencyLayer()
cg.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(filePath: out))

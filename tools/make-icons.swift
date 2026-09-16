#!/usr/bin/env swift
// Renders the macOS app icon from the MacID mark, so the app, the menu bar and
// the website stay the same shape. The geometry mirrors
// web/components/ScanMark.tsx: twelve rays from a centre, an ellipse, and four
// detection brackets, in a 200-unit viewBox.
//
// Drawing goes into explicitly sized NSBitmapImageReps rather than through
// NSImage.lockFocus(), which picks up the display's backing scale and silently
// doubles every file on a Retina Mac.
import AppKit
import Foundation

let iconset = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/MacID.iconset"

let ink = CGColor(srgbRed: 0x0D / 255, green: 0x0E / 255, blue: 0x0C / 255, alpha: 1)
let inkLifted = CGColor(srgbRed: 0x1C / 255, green: 0x1D / 255, blue: 0x1B / 255, alpha: 1)

func white(_ alpha: CGFloat) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }

/// Draws the mark centred on `center`, with the bracket box `width` wide.
func drawMark(_ cg: CGContext, center: CGPoint, width: CGFloat) {
    // Brackets span 44...156 in the viewBox: 112 units.
    let unit = width / 112
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: center.x + (x - 100) * unit, y: center.y - (y - 100) * unit)
    }

    cg.setLineCap(.round)
    cg.setLineJoin(.round)

    // Heavier than the web version: an icon is seen at 16pt as well as 512.
    cg.setStrokeColor(white(0.5))
    cg.setLineWidth(2.4 * unit)
    for i in 0..<12 {
        let angle = CGFloat(i) * .pi / 12
        let length: CGFloat = i % 3 == 0 ? 58 : 42
        let dx = cos(angle) * length, dy = sin(angle) * length
        cg.move(to: p(100 - dx, 100 - dy))
        cg.addLine(to: p(100 + dx, 100 + dy))
    }
    cg.strokePath()

    cg.setStrokeColor(white(0.35))
    cg.setLineWidth(2.4 * unit)
    cg.strokeEllipse(in: CGRect(x: center.x - 33 * unit, y: center.y - 42 * unit,
                                width: 66 * unit, height: 84 * unit))

    cg.setStrokeColor(white(1))
    cg.setLineWidth(6 * unit)
    for corner in [[p(44, 70), p(44, 44), p(70, 44)],
                   [p(130, 44), p(156, 44), p(156, 70)],
                   [p(156, 130), p(156, 156), p(130, 156)],
                   [p(70, 156), p(44, 156), p(44, 130)]] {
        cg.addLines(between: corner)
        cg.strokePath()
    }
}

func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.setShouldAntialias(true)
    let side = CGFloat(pixels)

    // Apple's macOS icon grid: an 824-unit rounded tile centred on 1024.
    let inset = side * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = side * 185 / 1024
    let shape = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -side * 0.012), blur: side * 0.03,
                 color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))
    cg.addPath(shape)
    cg.setFillColor(ink)
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                 colors: [inkLifted, ink] as CFArray, locations: [0, 1]) {
        cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY),
                              end: CGPoint(x: 0, y: tile.minY), options: [])
    }
    drawMark(cg, center: CGPoint(x: side / 2, y: side / 2), width: tile.width * 0.56)
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                        (256, 1), (256, 2), (512, 1), (512, 2)] {
    let path = "\(iconset)/icon_\(points)x\(points)\(scale == 1 ? "" : "@2x").png"
    guard let data = render(pixels: points * scale) else {
        FileHandle.standardError.write(Data("failed to render \(path)\n".utf8))
        exit(1)
    }
    try! data.write(to: URL(fileURLWithPath: path))
}
print("wrote \(iconset)")

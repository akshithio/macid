#!/usr/bin/env swift
import AppKit
import Foundation

let iconset = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/MacID.iconset"

let ink = CGColor(srgbRed: 0x0D / 255, green: 0x0E / 255, blue: 0x0C / 255, alpha: 1)
let inkLifted = CGColor(srgbRed: 0x1C / 255, green: 0x1D / 255, blue: 0x1B / 255, alpha: 1)

let cream = CGColor(srgbRed: 0xFB / 255, green: 0xF8 / 255, blue: 0xF3 / 255, alpha: 1)

/// Draws the ID monogram centred on `center`, `width` wide, counter knocked out even-odd.
func drawMark(_ cg: CGContext, center: CGPoint, width: CGFloat) {
    let unit = width / 56
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: center.x + (x - 51) * unit, y: center.y - (y - 50) * unit)
    }

    let path = CGMutablePath()

    let iRect = CGRect(x: p(23, 74).x, y: p(23, 74).y, width: 13 * unit, height: 48 * unit)
    path.addRoundedRect(in: iRect, cornerWidth: 6.5 * unit, cornerHeight: 6.5 * unit)

    path.move(to: p(45, 26))
    path.addLine(to: p(55, 26))
    path.addArc(center: p(55, 50), radius: 24 * unit,
                startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
    path.addLine(to: p(45, 74))
    path.closeSubpath()

    path.addEllipse(in: CGRect(x: p(55, 50).x - 8 * unit, y: p(55, 50).y - 8 * unit,
                               width: 16 * unit, height: 16 * unit))

    cg.addPath(path)
    cg.setFillColor(cream)
    cg.fillPath(using: .evenOdd)
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
    drawMark(cg, center: CGPoint(x: side / 2, y: side / 2), width: tile.width * 0.60)
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

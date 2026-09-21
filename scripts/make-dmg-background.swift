#!/usr/bin/env swift
// Draws the DMG window background at 1x and 2x: scripts/make-dmg-background.swift <out-dir>
import AppKit
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"

/// Window content size in points; scripts/dmg-settings.py places the icons on this grid.
let size = CGSize(width: 640, height: 400)

let paper = NSColor(srgbRed: 0xFA / 255, green: 0xF9 / 255, blue: 0xF7 / 255, alpha: 1)
let ink = NSColor(srgbRed: 0x1F / 255, green: 0x1F / 255, blue: 0x1D / 255, alpha: 1)
let muted = NSColor(srgbRed: 0x8C / 255, green: 0x8A / 255, blue: 0x84 / 255, alpha: 1)
let rule = NSColor(srgbRed: 0x1F / 255, green: 0x1F / 255, blue: 0x1D / 255, alpha: 0.12)

/// Top-left origin, to match Finder's icon coordinates.
func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: size.height - y) }

/// The ID monogram, `height` tall, its top-left at `origin` (top-left coordinates).
func drawMark(_ cg: CGContext, origin: CGPoint, height: CGFloat) {
    let unit = height / 48
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        pt(origin.x + (x - 23) * unit, origin.y + (y - 26) * unit)
    }
    let path = CGMutablePath()
    let stem = p(23, 74)
    path.addRoundedRect(in: CGRect(x: stem.x, y: stem.y, width: 13 * unit, height: 48 * unit),
                        cornerWidth: 6.5 * unit, cornerHeight: 6.5 * unit)
    path.move(to: p(45, 26))
    path.addLine(to: p(55, 26))
    path.addArc(center: p(55, 50), radius: 24 * unit,
                startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
    path.addLine(to: p(45, 74))
    path.closeSubpath()
    let eye = p(55, 50)
    path.addEllipse(in: CGRect(x: eye.x - 8 * unit, y: eye.y - 8 * unit,
                               width: 16 * unit, height: 16 * unit))
    cg.addPath(path)
    cg.setFillColor(ink.cgColor)
    cg.fillPath(using: .evenOdd)
}

/// Draws `text` with its top-left (or top-right when `alignRight`) at `at`.
func text(_ s: String, at: CGPoint, font: NSFont, color: NSColor, kern: CGFloat = 0, alignRight: Bool = false) {
    let attributed = NSAttributedString(string: s, attributes: [
        .font: font, .foregroundColor: color, .kern: kern,
    ])
    let bounds = attributed.size()
    let x = alignRight ? at.x - bounds.width : at.x
    attributed.draw(at: CGPoint(x: x, y: size.height - at.y - bounds.height))
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext

    cg.setFillColor(paper.cgColor)
    cg.fill(CGRect(origin: .zero, size: size))

    // Header: mark and name, then the mono caption.
    drawMark(cg, origin: CGPoint(x: 40, y: 36), height: 20)
    text("MacID", at: CGPoint(x: 70, y: 34), font: .systemFont(ofSize: 19, weight: .regular), color: ink)
    text("DRAG TO INSTALL", at: CGPoint(x: 40, y: 72),
         font: .monospacedSystemFont(ofSize: 10, weight: .regular), color: muted, kern: 0.6)

    // Arrow from the app slot (x 170) to Applications (x 470), on the icon row (y 200).
    let y: CGFloat = 196
    cg.setStrokeColor(ink.cgColor)
    cg.setLineWidth(2)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.move(to: pt(262, y))
    cg.addLine(to: pt(378, y))
    cg.move(to: pt(366, y - 10))
    cg.addLine(to: pt(378, y))
    cg.addLine(to: pt(366, y + 10))
    cg.strokePath()

    // Footer rule and lines.
    cg.setFillColor(rule.cgColor)
    cg.fill(CGRect(x: 40, y: size.height - 344, width: size.width - 80, height: 1))
    text("Then open MacID from Applications.", at: CGPoint(x: 40, y: 358),
         font: .systemFont(ofSize: 12), color: muted)
    text("macid.akshith.io", at: CGPoint(x: size.width - 40, y: 359),
         font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: muted, alignRight: true)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (scale, name) in [(1.0, "dmg-background.png"), (2.0, "dmg-background@2x.png")] {
    let data = render(scale: scale).representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}

import AppKit

/// The MacID mark for the menu bar: the ID monogram, redrawn for 18x16.
///
/// Not the app icon shrunk. On the icon's 100-unit grid the D's stem is two
/// units wide, which at this size is 0.54 of a pixel — it would vanish, and the
/// D would read as a blob with a hole in it. So the menu bar gets its own
/// optical size: the same two shapes and the same counter, proportioned so the
/// stem survives. A thicker stem and a relatively smaller counter is the trade,
/// and it is the usual one — an icon at 512 and a glyph at 16 are different
/// drawings of one idea.
///
/// Drawn from vectors so it stays crisp at every menu bar scale, and a template
/// image so macOS tints it for light, dark and highlighted menu bars — which is
/// why state is carried by alpha, not colour.
enum BrandMark {
    static func menuBarImage(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }

            let path = CGMutablePath()

            // I
            path.addRoundedRect(in: CGRect(x: 2.8, y: 3, width: 2.6, height: 10),
                                cornerWidth: 1.3, cornerHeight: 1.3)

            // D: left edge at x 8, bowl of radius 5 about (10.2, 8).
            path.move(to: CGPoint(x: 8, y: 13))
            path.addLine(to: CGPoint(x: 10.2, y: 13))
            path.addArc(center: CGPoint(x: 10.2, y: 8), radius: 5,
                        startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
            path.addLine(to: CGPoint(x: 8, y: 3))
            path.closeSubpath()

            // The counter, 1.2pt clear of the D's left edge — proportionally
            // over twice the icon's stem, so it holds at this size.
            path.addEllipse(in: CGRect(x: 9.2, y: 6.4, width: 3.2, height: 3.2))

            // Off is dimmed rather than replaced: it is still MacID, just not
            // one that will unlock anything right now.
            cg.setFillColor(CGColor(gray: 0, alpha: active ? 1 : 0.4))
            cg.addPath(path)
            cg.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = active ? "MacID, face unlock on" : "MacID, face unlock off"
        return image
    }
}

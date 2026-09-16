import AppKit

/// The MacID mark for the menu bar: detection brackets around a small ring.
///
/// Drawn from vectors so it stays crisp at every menu bar scale, and a template
/// image so macOS tints it for light, dark and highlighted menu bars — which is
/// why state is carried by alpha, not colour.
enum BrandMark {
    static func menuBarImage(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }

            let box = CGRect(x: 1.5, y: 1, width: 15, height: 14)
            let arm: CGFloat = 4.5
            let corners: [[CGPoint]] = [
                [CGPoint(x: box.minX, y: box.maxY - arm), CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.minX + arm, y: box.maxY)],
                [CGPoint(x: box.maxX - arm, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY - arm)],
                [CGPoint(x: box.maxX, y: box.minY + arm), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX - arm, y: box.minY)],
                [CGPoint(x: box.minX + arm, y: box.minY), CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.minX, y: box.minY + arm)],
            ]

            // Off is dimmed rather than replaced: it is still MacID, just not
            // one that will unlock anything right now.
            let alpha: CGFloat = active ? 1 : 0.4
            cg.setStrokeColor(CGColor(gray: 0, alpha: alpha))
            cg.setLineWidth(1.6)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for corner in corners {
                cg.addLines(between: corner)
                cg.strokePath()
            }

            cg.setLineWidth(1.4)
            cg.strokeEllipse(in: CGRect(x: rect.midX - 3, y: rect.midY - 3.5, width: 6, height: 7))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = active ? "MacID, face unlock on" : "MacID, face unlock off"
        return image
    }
}

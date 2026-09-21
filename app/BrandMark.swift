import AppKit

/// The MacID menu bar template image, drawn for 18x16.
enum BrandMark {
    static func menuBarImage(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }

            let path = CGMutablePath()

            path.addRoundedRect(in: CGRect(x: 2.8, y: 3, width: 2.6, height: 10),
                                cornerWidth: 1.3, cornerHeight: 1.3)

            path.move(to: CGPoint(x: 8, y: 13))
            path.addLine(to: CGPoint(x: 10.2, y: 13))
            path.addArc(center: CGPoint(x: 10.2, y: 8), radius: 5,
                        startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
            path.addLine(to: CGPoint(x: 8, y: 3))
            path.closeSubpath()

            path.addEllipse(in: CGRect(x: 9.2, y: 6.4, width: 3.2, height: 3.2))

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

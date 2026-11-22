import AppKit

enum BadgeImages {
    static let definitions: [(String, String)] = [
        ("waiting", "Waiting to upload"),
        ("uploading-0", "Uploading — 0% step"),
        ("uploading-25", "Uploading — 25% step"),
        ("uploading-50", "Uploading — 50% step"),
        ("uploading-75", "Uploading — 75% step"),
        ("done", "Uploaded"), ("error", "Upload error"),
        ("retrying", "Retrying upload"), ("offline", "Offline / unreachable")
    ]

    static func image(for identifier: String) -> NSImage {
        // Explicit 1x and 2x representations keep strokes sharp on Retina displays.
        let image = NSImage(size: NSSize(width: 16, height: 16))
        for scale in [1, 2] {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16 * scale,
                pixelsHigh: 16 * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            bitmap.size = NSSize(width: 16, height: 16)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            draw(identifier)
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(bitmap)
        }
        image.isTemplate = false
        return image
    }

    private static func line(_ points: [NSPoint], color: NSColor = .white, width: CGFloat = 1.7) {
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: first)
        for point in points.dropFirst() { path.line(to: point) }
        color.setStroke()
        path.stroke()
    }

    private static func draw(_ id: String) {
        let grey = NSColor(calibratedWhite: 0.30, alpha: 1)
        let blue = NSColor(calibratedRed: 0.02, green: 0.34, blue: 0.80, alpha: 1)
        let green = NSColor(calibratedRed: 0.02, green: 0.48, blue: 0.19, alpha: 1)
        let red = NSColor(calibratedRed: 0.80, green: 0.06, blue: 0.10, alpha: 1)
        let orange = NSColor(calibratedRed: 0.66, green: 0.29, blue: 0.00, alpha: 1)
        // White halo and dark edge remain visible on light and dark file thumbnails.
        let halo = NSBezierPath(ovalIn: NSRect(x: 0.5, y: 0.5, width: 15, height: 15))
        NSColor.white.setFill()
        halo.fill()
        NSColor.black.withAlphaComponent(0.85).setStroke()
        halo.lineWidth = 0.6
        halo.stroke()

        if id == "error" {
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: 8, y: 14))
            triangle.line(to: NSPoint(x: 14, y: 3))
            triangle.line(to: NSPoint(x: 2, y: 3))
            triangle.close()
            red.setFill()
            triangle.fill()
            line([NSPoint(x: 8, y: 10.5), NSPoint(x: 8, y: 7)], width: 2)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 7.1, y: 4.2, width: 1.8, height: 1.8)).fill()
            return
        }
        if id == "offline" {
            let cloud = NSBezierPath(roundedRect: NSRect(x: 2, y: 4, width: 12, height: 6), xRadius: 3, yRadius: 3)
            grey.setFill()
            cloud.fill()
            NSBezierPath(ovalIn: NSRect(x: 4, y: 7, width: 7, height: 6)).fill()
            line([NSPoint(x: 3.5, y: 3), NSPoint(x: 12.5, y: 13)], color: .white, width: 3.5)
            line([NSPoint(x: 3.5, y: 3), NSPoint(x: 12.5, y: 13)], color: grey, width: 1.5)
            return
        }
        let circle = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 12, height: 12))
        if id.hasPrefix("uploading-") {
            let percent = Double(id.dropFirst("uploading-".count)) ?? 0
            blue.setStroke()
            circle.lineWidth = 1.7
            circle.stroke()
            if percent > 0 {
                let pie = NSBezierPath()
                pie.move(to: NSPoint(x: 8, y: 8))
                pie.appendArc(withCenter: NSPoint(x: 8, y: 8), radius: 4.5,
                              startAngle: 90, endAngle: CGFloat(90 - percent * 3.6), clockwise: true)
                pie.close()
                blue.setFill()
                pie.fill()
            } else {
                // A zero-step pie has only the blue circular outline.
                line([NSPoint(x: 8, y: 8), NSPoint(x: 8, y: 12.5)], color: blue, width: 1)
            }
        } else if id == "retrying" {
            orange.setFill()
            circle.fill()
            let arc = NSBezierPath()
            arc.lineWidth = 1.7
            arc.lineCapStyle = .round
            arc.appendArc(withCenter: NSPoint(x: 8, y: 8), radius: 3.6,
                          startAngle: 40, endAngle: 320, clockwise: false)
            NSColor.white.setStroke()
            arc.stroke()
            line([NSPoint(x: 8.8, y: 5.2), NSPoint(x: 11, y: 5.5), NSPoint(x: 11.2, y: 3.5)], width: 1.5)
        } else {
            (id == "done" ? green : grey).setFill()
            circle.fill()
            if id == "done" {
                line([NSPoint(x: 4.3, y: 7.6), NSPoint(x: 7, y: 5), NSPoint(x: 11.7, y: 10.6)], width: 2)
            } else {
                line([NSPoint(x: 8, y: 11.8), NSPoint(x: 8, y: 8), NSPoint(x: 10.5, y: 6.5)], width: 1.6)
            }
        }
    }
}

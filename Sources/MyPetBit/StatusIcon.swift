import AppKit

/// Значок в строке меню: силуэт Бита-шаблон (система красит его под строку меню), глаза повторяют настроение.
enum StatusIcon {
    static func image(for state: PetState) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Система Бита 200x200 → 18 точек: силуэт x 30...170, y 16...164, центр (100, 90).
            let s: CGFloat = 0.12
            ctx.translateBy(x: 9 - 100 * s, y: 9 - 90 * s)
            ctx.scaleBy(x: s, y: s)
            ctx.setFillColor(.black)
            ctx.setStrokeColor(.black)
            ctx.setLineCap(.round)

            // Антенна, ушки, ножки, корпус.
            ctx.setLineWidth(9)
            ctx.move(to: CGPoint(x: 100, y: 52))
            ctx.addLine(to: CGPoint(x: 100, y: 30))
            ctx.strokePath()
            ctx.fillEllipse(in: CGRect(x: 89, y: 14, width: 22, height: 22))
            for r in [CGRect(x: 28, y: 84, width: 18, height: 34), CGRect(x: 154, y: 84, width: 18, height: 34),
                      CGRect(x: 62, y: 144, width: 28, height: 20), CGRect(x: 110, y: 144, width: 28, height: 20)] {
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil))
            }
            ctx.addPath(CGPath(roundedRect: CGRect(x: 40, y: 50, width: 120, height: 104), cornerWidth: 34, cornerHeight: 34, transform: nil))
            ctx.fillPath()

            // Экран — вырез.
            ctx.setBlendMode(.clear)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 56, y: 68, width: 88, height: 62), cornerWidth: 20, cornerHeight: 20, transform: nil))
            ctx.fillPath()
            ctx.setBlendMode(.normal)

            // Глаза — крупнее, чем на самом Бите, иначе в 18 точках не читаются.
            ctx.setLineWidth(11)
            switch state {
            case .sleep, .drowsy, .shush:
                ctx.move(to: CGPoint(x: 70, y: 100)); ctx.addLine(to: CGPoint(x: 90, y: 100))
                ctx.move(to: CGPoint(x: 110, y: 100)); ctx.addLine(to: CGPoint(x: 130, y: 100))
                ctx.strokePath()
            case .happy, .purr, .dance, .note:
                ctx.move(to: CGPoint(x: 70, y: 106)); ctx.addQuadCurve(to: CGPoint(x: 90, y: 106), control: CGPoint(x: 80, y: 86))
                ctx.move(to: CGPoint(x: 110, y: 106)); ctx.addQuadCurve(to: CGPoint(x: 130, y: 106), control: CGPoint(x: 120, y: 86))
                ctx.strokePath()
            case .surprised, .dizzy:
                ctx.fillEllipse(in: CGRect(x: 70, y: 88, width: 22, height: 22))
                ctx.fillEllipse(in: CGRect(x: 108, y: 88, width: 22, height: 22))
            default:
                ctx.addPath(CGPath(roundedRect: CGRect(x: 72, y: 82, width: 18, height: 34), cornerWidth: 9, cornerHeight: 9, transform: nil))
                ctx.addPath(CGPath(roundedRect: CGRect(x: 110, y: 82, width: 18, height: 34), cornerWidth: 9, cornerHeight: 9, transform: nil))
                ctx.fillPath()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MyPetBit"
        return image
    }

    /// Для проверки рисунка: MyPetBit -exportStatusIcons <папка> пишет PNG 36x36 по состояниям и выходит.
    static func export(to folder: String) {
        let url = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for state in [PetState.idle, .happy, .sleep, .surprised] {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = NSSize(width: 18, height: 18)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image(for: state).draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("status-\(state.rawValue).png"))
        }
    }
}

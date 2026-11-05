// Рисует иконку приложения — Бит на «скругленном квадрате» macOS — во все размеры iconset.
// Запуск из корня проекта:
//   swiftc -O tools/make-icon.swift -o .build/make-icon && .build/make-icon build/AppIcon.iconset \
//     && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func roundRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}

/// Холст 1024x1024, y вниз. Фон по сетке Big Sur: квадрат 824 со скруглением 185 и отступом 100.
func drawIcon(_ ctx: CGContext) {
    let background = roundRect(100, 100, 824, 824, 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: rgb(0x000000, 0.35))
    ctx.addPath(background)
    ctx.setFillColor(rgb(0x0E1626))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(background)
    ctx.clip()
    let fill = CGGradient(colorsSpace: sRGB, colors: [rgb(0x26385C), rgb(0x0E1626)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    let glow = CGGradient(colorsSpace: sRGB, colors: [rgb(0x5CF2E0, 0.32), rgb(0x5CF2E0, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 500), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 500), endRadius: 430, options: [])
    ctx.restoreGState()

    // Бит в своей системе 200x200 (как в BitLayerView), центр силуэта (100, 90) → (512, 520).
    ctx.saveGState()
    let scale: CGFloat = 3.6
    ctx.translateBy(x: 512 - 100 * scale, y: 520 - 90 * scale)
    ctx.scaleBy(x: scale, y: scale)
    ctx.setLineCap(.round)

    ctx.setFillColor(rgb(0x000000, 0.3))
    ctx.fillEllipse(in: CGRect(x: 58, y: 176, width: 84, height: 12))

    ctx.setStrokeColor(rgb(0xC9CDD6))
    ctx.setLineWidth(4)
    ctx.move(to: CGPoint(x: 100, y: 52))
    ctx.addLine(to: CGPoint(x: 100, y: 34))
    ctx.strokePath()
    ctx.setFillColor(rgb(0xFF7A6B, 0.25))
    ctx.fillEllipse(in: CGRect(x: 86, y: 16, width: 28, height: 28))
    ctx.setFillColor(rgb(0xFF7A6B))
    ctx.fillEllipse(in: CGRect(x: 93.5, y: 23.5, width: 13, height: 13))

    ctx.setFillColor(rgb(0xD5D9E1))
    for (x, y, w, h, r) in [(64.0, 146.0, 24.0, 16.0, 7.0), (112, 146, 24, 16, 7), (32, 86, 12, 30, 6), (156, 86, 12, 30, 6)] {
        ctx.addPath(roundRect(x, y, w, h, r))
    }
    ctx.fillPath()

    ctx.addPath(roundRect(40, 50, 120, 104, 34))
    ctx.setFillColor(rgb(0xF4F5F7))
    ctx.setStrokeColor(rgb(0xE2E5EB))
    ctx.setLineWidth(2)
    ctx.drawPath(using: .fillStroke)
    ctx.addPath(roundRect(54, 66, 92, 66, 22))
    ctx.setFillColor(rgb(0x1B1F2A))
    ctx.fillPath()

    ctx.setStrokeColor(rgb(0xFFFFFF, 0.12))
    ctx.setLineWidth(3)
    ctx.move(to: CGPoint(x: 64, y: 76))
    ctx.addQuadCurve(to: CGPoint(x: 80, y: 70), control: CGPoint(x: 70, y: 70))
    ctx.strokePath()

    ctx.setFillColor(rgb(0x5CF2E0))
    ctx.addPath(roundRect(76, 88, 12, 20, 6))
    ctx.addPath(roundRect(112, 88, 12, 20, 6))
    ctx.fillPath()
    ctx.setStrokeColor(rgb(0x5CF2E0))
    ctx.setLineWidth(3)
    ctx.move(to: CGPoint(x: 94, y: 117))
    ctx.addQuadCurve(to: CGPoint(x: 106, y: 117), control: CGPoint(x: 100, y: 122))
    ctx.strokePath()
    ctx.restoreGState()
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (points, factor) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = points * factor
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: CGFloat(px) / 1024, y: -CGFloat(px) / 1024)
    drawIcon(ctx)
    let name = "icon_\(points)x\(points)\(factor == 2 ? "@2x" : "").png"
    let destination = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
}
print("iconset: \(out.path)")

// Рисует фон окна установки из образа — в стиле Бита: тёмно-синее небо, сам Бит, название и два шага.
//
//   swift tools/make-dmg-background.swift 1.0.0
//
// Пишет build/dmg-background.png и build/dmg-background@2x.png; tools/make-dmg.sh сшивает их в один tiff,
// и Finder сам берёт нужное разрешение (на ретине фон не мылится). Устроено как в Trunook.
//
// Под значками фон не рисует ничего, что должно с ними совпасть: Finder ставит значки от одного края окна,
// а фон — от другого, и с полосой вкладок значки уезжают вниз на её высоту. Всё, что должно читаться, — в шапке.
// Сами значки стоят на «столе» — полосе приглушённого серо-синего: подписи Finder рисует чёрным в светлой теме
// и белым в тёмной (выбрать нельзя), и на этом цвете читаются обе — контраст около 4,5:1.

import AppKit
import Foundation

let version = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "?"

/// Размер окна в точках — ровно его же tools/dmg-window.applescript задаёт Finder'у.
let W: CGFloat = 660
let H: CGFloat = 540

// MARK: - Координаты: макет сверху вниз, AppKit рисует снизу вверх

func flip(_ y: CGFloat) -> CGFloat { H - y }
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: flip(y + h), width: w, height: h) }
func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: flip(y)) }

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Цвета Бита (BitLayerView, облачко, окна настроек).
let ink = rgb(0x1B1F2A)
let glow = rgb(0x5CF2E0)
let text = rgb(0xE8FBF8)
let dim = rgb(0x9FB3B8)
let lamp = rgb(0xFF7A6B)
let shell = rgb(0xF5F6F8)
let ears = rgb(0xD9DCE3)

func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
}

func centered(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, baseline: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let height = size * 1.4
    (string as NSString).draw(in: rect(0, baseline - height, W, height),
                              withAttributes: [.font: rounded(size, weight), .foregroundColor: color, .paragraphStyle: style])
}

// MARK: - Бит: как в BitLayerView, в своей системе 200×200, уменьшенный

func drawBit(centerX: CGFloat, top: CGFloat, size: CGFloat) {
    let k = size / 200
    let ox = centerX - size / 2
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { rect(ox + x * k, top + y * k, w * k, h * k) }
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { point(ox + x * k, top + y * k) }

    // Тень на «полу» и свечение лампочки.
    rgb(0x000000, 0.22).setFill()
    NSBezierPath(ovalIn: r(56, 182, 88, 12)).fill()
    NSGradient(colors: [lamp.withAlphaComponent(0.35), lamp.withAlphaComponent(0)])?
        .draw(fromCenter: p(100, 30), radius: 0, toCenter: p(100, 30), radius: 22 * k, options: [])

    // Антенна.
    let stem = NSBezierPath()
    stem.move(to: p(100, 52))
    stem.line(to: p(100, 34))
    stem.lineWidth = 4 * k
    stem.lineCapStyle = .round
    rgb(0xC9CDD6).setStroke()
    stem.stroke()
    lamp.setFill()
    NSBezierPath(ovalIn: r(93.5, 23.5, 13, 13)).fill()

    // Ушки, ножки, корпус.
    ears.setFill()
    NSBezierPath(roundedRect: r(20, 84, 18, 34), xRadius: 6 * k, yRadius: 6 * k).fill()
    NSBezierPath(roundedRect: r(162, 84, 18, 34), xRadius: 6 * k, yRadius: 6 * k).fill()
    NSBezierPath(roundedRect: r(64, 140, 28, 16), xRadius: 6 * k, yRadius: 6 * k).fill()
    NSBezierPath(roundedRect: r(108, 140, 28, 16), xRadius: 6 * k, yRadius: 6 * k).fill()
    shell.setFill()
    NSBezierPath(roundedRect: r(32, 52, 136, 98), xRadius: 30 * k, yRadius: 30 * k).fill()
    rgb(0xFFFFFF, 0.6).setStroke()
    let rim = NSBezierPath(roundedRect: r(33, 53, 134, 96), xRadius: 29 * k, yRadius: 29 * k)
    rim.lineWidth = 1.5 * k
    rim.stroke()

    // Экран и лицо: глаза-таблетки и улыбка.
    ink.setFill()
    NSBezierPath(roundedRect: r(50, 66, 100, 66), xRadius: 18 * k, yRadius: 18 * k).fill()
    glow.setFill()
    NSBezierPath(roundedRect: r(77, 84, 11, 20), xRadius: 5.5 * k, yRadius: 5.5 * k).fill()
    NSBezierPath(roundedRect: r(112, 84, 11, 20), xRadius: 5.5 * k, yRadius: 5.5 * k).fill()
    let smile = NSBezierPath()
    smile.move(to: p(91, 114))
    smile.curve(to: p(109, 114), controlPoint1: p(95, 121), controlPoint2: p(105, 121))
    smile.lineWidth = 3.5 * k
    smile.lineCapStyle = .round
    glow.setStroke()
    smile.stroke()
}

// MARK: - Шаги установки

let stepFont = rounded(12.5, .medium)

func stepWidth(_ string: String) -> CGFloat { 20 + 9 + (string as NSString).size(withAttributes: [.font: stepFont]).width }

/// Кружок с номером и подпись; левый край общий у всех шагов — список читается списком.
func step(_ number: String, _ string: String, left: CGFloat, top: CGFloat) {
    let circle = rect(left, top, 20, 20)
    glow.withAlphaComponent(0.16).setFill()
    NSBezierPath(ovalIn: circle).fill()
    glow.withAlphaComponent(0.6).setStroke()
    let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5))
    ring.lineWidth = 1
    ring.stroke()
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    (number as NSString).draw(in: rect(left, top + 3, 20, 15),
                              withAttributes: [.font: rounded(11, .bold), .foregroundColor: glow, .paragraphStyle: style])
    (string as NSString).draw(in: rect(left + 29, top + 2, stepWidth(string), 17),
                              withAttributes: [.font: stepFont, .foregroundColor: text.withAlphaComponent(0.82)])
}

// MARK: - Отрисовка

func draw() {
    // Небо, как на снимках Бита: светлее сверху слева, к краям — почти чёрное.
    rgb(0x12141F).setFill()
    CGRect(x: 0, y: 0, width: W, height: H).fill()
    NSGradient(colors: [rgb(0x29345A), rgb(0x12141F)])?
        .draw(fromCenter: point(W * 0.35, 40), radius: 0, toCenter: point(W / 2, H / 2), radius: W * 0.8, options: [])
    // Редкие звёзды — только в шапке, где нет значков.
    var seed: UInt64 = 7
    func random() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
    }
    for _ in 0..<26 {
        let x = random() * W, y = random() * 220
        if abs(x - W / 2) < 90 && y < 140 { continue }  // не над Битом
        rgb(0xFFFFFF, 0.15 + random() * 0.3).setFill()
        let d = 1 + random() * 1.6
        NSBezierPath(ovalIn: rect(x, y, d, d)).fill()
    }

    // Стол под значками: от шапки до низа, с мягкой бирюзовой кромкой.
    let deskTop: CGFloat = 262
    NSGradient(colors: [rgb(0x6E7B98), rgb(0x606C88)])?.draw(in: rect(0, deskTop, W, H - deskTop), angle: -90)
    NSGradient(colors: [glow.withAlphaComponent(0.55), glow.withAlphaComponent(0)])?.draw(in: rect(0, deskTop, W, 3), angle: -90)
    rgb(0x000000, 0.18).setFill()
    rect(0, deskTop - 1, W, 1).fill()

    drawBit(centerX: W / 2, top: 14, size: 108)
    centered("MyPetBit", size: 25, weight: .bold, color: text, baseline: 154)
    centered("Бит — маленький робот на твоём рабочем столе", size: 11.5, weight: .regular, color: glow.withAlphaComponent(0.8),
             baseline: 174)

    let first = "Перетащи меня в папку «Программы» →"
    let second = "Открой «Install» внутри — там одна команда, без неё macOS меня не пустит"
    let column = (W - max(stepWidth(first), stepWidth(second))) / 2
    step("1", first, left: column, top: 194)
    step("2", second, left: column, top: 222)

    // Видна не у всех: с полосой вкладок низ окна обрезан — здесь только то, без чего можно.
    centered("Drag me to Applications · 把我拖到“应用程序”  ·  MyPetBit \(version) · MIT", size: 10.5, weight: .regular,
             color: ink.withAlphaComponent(0.6), baseline: 500)
}

func render(scale: CGFloat, to path: String) {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        FileHandle.standardError.write(Data("не удалось создать растр\n".utf8))
        exit(1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: scale, y: scale)  // макет один, множитель — у контекста
    draw()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    try? data.write(to: URL(fileURLWithPath: path))
    print("нарисовано: \(path) — \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)")
}

try? FileManager.default.createDirectory(atPath: "build", withIntermediateDirectories: true)
render(scale: 1, to: "build/dmg-background.png")
render(scale: 2, to: "build/dmg-background@2x.png")

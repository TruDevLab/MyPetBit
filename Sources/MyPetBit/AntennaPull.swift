import AppKit
import QuartzCore

/// Вытянутая антенна: пока её тянут вверх, она рисуется в отдельном прозрачном окне за Битом
/// (окно Бита по размеру с самого Бита). Стебель уходит за корпус, поэтому при покачивании Бита разрыва нет.
/// Каждые 3,5 точки — минута таймера, до часа; отметки на стебле — через 5 минут.
@MainActor
final class AntennaOverlay {
    static let perMinute: CGFloat = 3.5
    static let maxMinutes = 60
    static var maxPull: CGFloat { perMinute * CGFloat(maxMinutes) }

    private let panel: BubblePanel
    private let root = CALayer()
    private let stem = CALayer()
    private let ticks = CAShapeLayer()
    private let glow = CAShapeLayer()
    private let lamp = CAShapeLayer()
    private let label = CALayer()
    private let labelText = CATextLayer()
    private var scale: CGFloat = 0.75
    private var rest: CGFloat = 16.5      // стебель от корпуса до центра лампочки без вытягивания
    private static let width: CGFloat = 190  // с запасом справа под плашку «NN мин»
    private static let below: CGFloat = 12  // столько окна ниже основания антенны: стебель уходит за корпус

    init() {
        panel = BubblePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true  // мышь остаётся у окна Бита, где начали тянуть
        panel.isReleasedWhenClosed = false
        let view = NSView()
        view.layer = root
        view.wantsLayer = true
        panel.contentView = view

        stem.backgroundColor = rgb(0xC9CDD6)
        stem.anchorPoint = CGPoint(x: 0.5, y: 0)
        ticks.fillColor = nil
        ticks.strokeColor = rgb(0xC9CDD6)
        ticks.lineCap = .round
        glow.fillColor = rgb(0xFF7A6B, 0.3)
        lamp.fillColor = rgb(0xFF7A6B)
        label.backgroundColor = rgb(0x1B1F2A, 0.95)
        label.borderColor = rgb(0x5CF2E0, 0.45)
        label.borderWidth = 1
        label.anchorPoint = CGPoint(x: 0, y: 0.5)
        labelText.alignmentMode = .center
        label.addSublayer(labelText)
        for l in [stem, ticks, glow, lamp, label] { root.addSublayer(l) }
    }

    /// base — основание антенны на корпусе (экранные координаты), scale — масштаб Бита (окно / 200).
    func begin(base: NSPoint, scale: CGFloat, below window: NSWindow) {
        self.scale = scale
        rest = (52 - 30) * scale
        let height = Self.below + rest + Self.maxPull + 30
        panel.setFrame(NSRect(x: base.x - Self.width / 2, y: base.y - Self.below, width: Self.width, height: height), display: false)
        for l in [root, stem, ticks, glow, lamp, label, labelText] { l.contentsScale = window.backingScaleFactor }
        root.removeAllAnimations()
        update(pull: 0, minutes: 0)
        panel.orderFront(nil)
        panel.order(.below, relativeTo: window.windowNumber)
    }

    func update(pull: CGFloat, minutes: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layout(pull: pull)
        let r = 6.5 * scale
        ticks.lineWidth = 1.5 * scale
        let marks = CGMutablePath()
        var k = 1
        while CGFloat(k * 5) * Self.perMinute <= pull {
            // Отметка на высоте, где была лампочка на k·5 минутах: пройденные пять минут.
            let y = Self.below + rest + CGFloat(k * 5) * Self.perMinute - r - 4
            marks.move(to: CGPoint(x: Self.width / 2 - 4 * scale, y: y))
            marks.addLine(to: CGPoint(x: Self.width / 2 + 4 * scale, y: y))
            k += 1
        }
        ticks.path = marks
        label.isHidden = minutes == 0
        if minutes > 0 {
            let base = NSFont.systemFont(ofSize: 12, weight: .semibold)
            let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: 12) ?? base
            let text = NSAttributedString(string: L("%@ мин", "\(minutes)"),
                                          attributes: [.font: font, .foregroundColor: NSColor(cgColor: rgb(0x5CF2E0)) ?? .cyan])
            labelText.string = text
            let w = ceil(text.size().width) + 14
            let line = ceil(font.ascender - font.descender)
            label.bounds = CGRect(x: 0, y: 0, width: w, height: 20)
            label.cornerRadius = 10
            labelText.frame = CGRect(x: 0, y: (20 - line) / 2, width: w, height: line)
        }
        CATransaction.commit()
    }

    /// Отпустили — антенна пружинкой возвращается на место, окно прячется.
    func end(_ done: @escaping @MainActor () -> Void) {
        let fromStem = stem.bounds.height
        let fromLamp = lamp.position.y
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.isHidden = true
        ticks.path = nil
        layout(pull: 0)
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                self?.panel.orderOut(nil)
                done()
            }
        }
        func spring(_ key: String, _ from: CGFloat, _ to: CGFloat) -> CASpringAnimation {
            let a = CASpringAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.mass = 0.6
            a.stiffness = 320
            a.damping = 11
            a.duration = min(a.settlingDuration, 0.7)
            return a
        }
        stem.add(spring("bounds.size.height", fromStem, stem.bounds.height), forKey: "back")
        for l in [lamp, glow] { l.add(spring("position.y", fromLamp, lamp.position.y), forKey: "back") }
        CATransaction.commit()
    }

    private func layout(pull: CGFloat) {
        let x = Self.width / 2
        let top = Self.below + rest + pull
        stem.bounds = CGRect(x: 0, y: 0, width: 4 * scale, height: top)
        stem.position = CGPoint(x: x, y: 0)
        stem.cornerRadius = 2 * scale
        let r = 6.5 * scale
        let g = 13 * scale
        lamp.bounds = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
        lamp.path = CGPath(ellipseIn: lamp.bounds, transform: nil)
        lamp.position = CGPoint(x: x, y: top)
        glow.bounds = CGRect(x: 0, y: 0, width: 2 * g, height: 2 * g)
        glow.path = CGPath(ellipseIn: glow.bounds, transform: nil)
        glow.position = CGPoint(x: x, y: top)
        label.position = CGPoint(x: x + g + 2, y: top)
    }

    private func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

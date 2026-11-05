import AppKit
import QuartzCore

/// Пункт быстрого меню Бита.
struct QuickItem {
    var title: String
    /// Имя SF Symbol.
    var symbol: String
    /// Переключатель: щелчок меняет его и оставляет меню открытым; nil — обычный пункт, меню закрывается.
    var isOn: Bool?
    /// Тонкая линия над пунктом.
    var separated = false
    var action: () -> Void
}

/// Быстрое меню по нажатию двумя пальцами на Бите: тёмная карточка в цвет экрана Бита,
/// раскрывается пружинкой из угла корпуса, пункты выезжают по очереди.
@MainActor
final class QuickMenu {
    /// Курсор над пунктом (nil — ни над каким): Бит повторяет подсветку на своём экране.
    var onHover: ((Int?) -> Void)?
    /// Переключатель сменился: индекс и новое значение.
    var onToggle: ((Int, Bool) -> Void)?
    var onClose: (() -> Void)?
    private(set) var isOpen = false
    /// Когда закрылось: второе нажатие двумя пальцами закрывает меню, а не открывает заново.
    private(set) var closedAt = Date.distantPast

    private let panel: BubblePanel
    private let view = MenuView()
    private var items: [QuickItem] = []
    private var monitors: [Any] = []

    fileprivate static let margin: CGFloat = 12  // поле под тень
    fileprivate static let gap: CGFloat = 6       // от угла корпуса до карточки

    init() {
        panel = BubblePanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        view.onHover = { [weak self] index in self?.onHover?(index) }
        view.onPick = { [weak self] index in self?.pick(index) }
    }

    func show(title: String, subtitle: String, items: [QuickItem], near anchor: NSRect) {
        if isOpen { close() }
        self.items = items
        view.build(title: title, subtitle: subtitle, items: items)
        let fromLeft = place(near: anchor)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        view.popIn(fromLeft: fromLeft)
        isOpen = true
        // Щелчок мимо меню — закрыть. Свои окна — локальным монитором, чужие — глобальным.
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel { self.close() }
            }
            return event
        }) { monitors.append(local) }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        closedAt = Date()
        view.popOut { [weak self] in
            guard let self, !self.isOpen else { return }
            self.panel.orderOut(nil)
        }
        onClose?()
    }

    private func pick(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        if let on = item.isOn {
            items[index].isOn = !on
            view.setToggle(index, !on)
            onToggle?(index, !on)
            item.action()
        } else {
            close()
            item.action()
        }
    }

    /// Слева сверху от Бита, нижним правым углом к левому верхнему углу корпуса.
    /// Слева нет места — справа; сверху нет места — вниз от нижнего угла. true — карточка слева от Бита.
    private func place(near anchor: NSRect) -> Bool {
        let size = view.contentSize
        let m = Self.margin
        let screen = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        // Углы корпуса в окне Бита (холст 200x200): скругление на (50, 60) сверху и (50, 144) снизу.
        let left = anchor.minX + anchor.width * 0.24
        let right = anchor.maxX - anchor.width * 0.24
        let top = anchor.maxY - anchor.height * 0.29
        let bottom = anchor.minY + anchor.height * 0.27
        let body = NSSize(width: size.width - 2 * m, height: size.height - 2 * m)
        let onLeft = left - Self.gap - body.width >= screen.minX + 4
        let up = top + body.height <= screen.maxY - 4
        var x = onLeft ? left - Self.gap - body.width - m : right + Self.gap - m
        var y = up ? top - m : bottom - body.height - m
        x = min(max(x, screen.minX - m + 4), screen.maxX - size.width + m - 4)
        y = min(max(y, screen.minY - m + 4), screen.maxY - size.height + m - 4)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
        // Раскрывается из угла, ближнего к Биту.
        view.layoutCard(origin: CGPoint(x: onLeft ? 1 : 0, y: up ? 0 : 1))
        return onLeft
    }

    // MARK: - Вид

    private final class MenuView: NSView {
        var onHover: ((Int?) -> Void)?
        var onPick: ((Int) -> Void)?
        private(set) var contentSize = NSSize(width: 200, height: 200)

        private let container = CALayer()
        private let body = CAShapeLayer()
        private let titleLayer = CATextLayer()
        private let subtitleLayer = CATextLayer()
        private let headerLine = CALayer()
        private var rows: [Row] = []
        private var toggles: [Bool?] = []
        private var cardSize = CGSize.zero
        private var hovered: Int?
        private var pressed: Int?

        private struct Row {
            let layer: CALayer
            let highlight: CALayer
            let icon: CALayer
            let text: CATextLayer
            let track: CALayer?
            let knob: CALayer?
            let separator: CALayer?
        }

        private static let rowHeight: CGFloat = 30
        private static let header: CGFloat = 46
        private static let inset: CGFloat = 6
        private static let toggleSize = CGSize(width: 28, height: 16)
        private static let font = rounded(13, .medium)
        private static let titleFont = rounded(14, .bold)
        private static let subtitleFont = rounded(11.5, .regular)

        override init(frame: NSRect) {
            super.init(frame: frame)
            layer = CALayer()
            wantsLayer = true
            layer?.addSublayer(container)
            container.addSublayer(body)
            body.fillColor = Self.rgb(0x1B1F2A, 0.97)
            body.strokeColor = Self.rgb(0x5CF2E0, 0.45)
            body.lineWidth = 1
            body.shadowColor = .black
            body.shadowOpacity = 0.4
            body.shadowRadius = 8
            body.shadowOffset = CGSize(width: 0, height: -3)
            for t in [titleLayer, subtitleLayer] {
                t.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
                container.addSublayer(t)
            }
            headerLine.backgroundColor = Self.rgb(0x5CF2E0, 0.14)
            container.addSublayer(headerLine)
        }

        convenience init() { self.init(frame: .zero) }

        required init?(coder: NSCoder) { fatalError() }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        func build(title: String, subtitle: String, items: [QuickItem]) {
            rows.forEach {
                $0.layer.removeFromSuperlayer()
                $0.separator?.removeFromSuperlayer()
            }
            rows = []
            toggles = items.map(\.isOn)
            hovered = nil
            pressed = nil
            let scale = NSScreen.main?.backingScaleFactor ?? 2

            let titleText = Self.string(title, Self.titleFont, 0xE8FBF8)
            let subtitleText = Self.string(subtitle, Self.subtitleFont, 0x9FB3B8)
            titleLayer.string = titleText
            subtitleLayer.string = subtitleText
            let hasToggle = items.contains { $0.isOn != nil }
            let widest = items.map { Self.string($0.title, Self.font, 0).size().width }.max() ?? 0
            var width = 46 + ceil(widest) + (hasToggle ? 14 + Self.toggleSize.width : 0) + 16
            width = max(width, ceil(max(titleText.size().width, subtitleText.size().width)) + 32, 210)
            let separators = items.filter(\.separated).count
            let height = Self.header + CGFloat(items.count) * Self.rowHeight + CGFloat(separators) * 9 + 2 * Self.inset
            cardSize = CGSize(width: ceil(width), height: ceil(height))
            let m = QuickMenu.margin
            contentSize = NSSize(width: cardSize.width + 2 * m, height: cardSize.height + 2 * m)

            let tint = NSColor(cgColor: Self.rgb(0x5CF2E0)) ?? .cyan
            for item in items {
                let row = CALayer()
                let highlight = CALayer()
                highlight.cornerRadius = 8
                highlight.backgroundColor = Self.rgb(0x5CF2E0, 0.14)
                highlight.opacity = 0
                row.addSublayer(highlight)

                let icon = CALayer()
                icon.contentsGravity = .resizeAspect
                icon.contentsScale = scale
                let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
                if let image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                    icon.contents = image.layerContents(forContentsScale: scale)
                }
                row.addSublayer(icon)

                let text = CATextLayer()
                text.contentsScale = scale
                text.string = Self.string(item.title, Self.font, 0xE8FBF8)
                row.addSublayer(text)

                var track: CALayer?
                var knob: CALayer?
                if let on = item.isOn {
                    let t = CALayer()
                    t.cornerRadius = Self.toggleSize.height / 2
                    let k = CALayer()
                    k.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
                    k.cornerRadius = 6
                    k.backgroundColor = Self.rgb(0xE8FBF8)
                    k.shadowOpacity = 0.3
                    k.shadowRadius = 1.5
                    k.shadowOffset = CGSize(width: 0, height: -1)
                    t.addSublayer(k)
                    row.addSublayer(t)
                    track = t
                    knob = k
                    paint(track: t, knob: k, on: on, animated: false)
                }
                var separator: CALayer?
                if item.separated {
                    let line = CALayer()
                    line.backgroundColor = Self.rgb(0x5CF2E0, 0.12)
                    container.addSublayer(line)
                    separator = line
                }
                container.addSublayer(row)
                rows.append(Row(layer: row, highlight: highlight, icon: icon, text: text, track: track, knob: knob, separator: separator))
            }
        }

        /// origin — угол карточки, ближний к Биту, в долях (0…1): из него карточка растёт.
        func layoutCard(origin: CGPoint) {
            let m = QuickMenu.margin
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.bounds = bounds  // не frame: после закрытия у контейнера остаётся уменьшение
            let card = CGRect(x: m, y: m, width: cardSize.width, height: cardSize.height)
            body.path = CGPath(roundedRect: card, cornerWidth: 15, cornerHeight: 15, transform: nil)
            body.shadowPath = body.path

            let titleHeight = ceil(Self.titleFont.ascender - Self.titleFont.descender) + 2
            let subtitleHeight = ceil(Self.subtitleFont.ascender - Self.subtitleFont.descender) + 2
            titleLayer.frame = CGRect(x: card.minX + 16, y: card.maxY - 9 - titleHeight, width: card.width - 32, height: titleHeight)
            subtitleLayer.frame = CGRect(x: card.minX + 16, y: titleLayer.frame.minY - subtitleHeight + 2,
                                         width: card.width - 32, height: subtitleHeight)
            headerLine.frame = CGRect(x: card.minX + 12, y: card.maxY - Self.header, width: card.width - 24, height: 1)

            var y = card.maxY - Self.header - Self.inset
            let lineHeight = ceil(Self.font.ascender - Self.font.descender) + 1
            for (i, row) in rows.enumerated() {
                if let separator = row.separator {
                    y -= 9
                    separator.frame = CGRect(x: card.minX + 12, y: y + 4, width: card.width - 24, height: 1)
                }
                y -= Self.rowHeight
                row.layer.frame = CGRect(x: card.minX + Self.inset, y: y, width: card.width - 2 * Self.inset, height: Self.rowHeight)
                row.highlight.frame = row.layer.bounds
                row.icon.frame = CGRect(x: 10, y: (Self.rowHeight - 18) / 2, width: 18, height: 18)
                row.text.frame = CGRect(x: 38, y: (Self.rowHeight - lineHeight) / 2, width: row.layer.bounds.width - 38, height: lineHeight)
                if let track = row.track, let knob = row.knob {
                    track.frame = CGRect(x: row.layer.bounds.width - 10 - Self.toggleSize.width,
                                         y: (Self.rowHeight - Self.toggleSize.height) / 2,
                                         width: Self.toggleSize.width, height: Self.toggleSize.height)
                    knob.position = knobPosition(on: toggles[i] ?? false)
                }
            }

            let corner = CGPoint(x: card.minX + card.width * origin.x, y: card.minY + card.height * origin.y)
            container.anchorPoint = CGPoint(x: corner.x / bounds.width, y: corner.y / bounds.height)
            container.position = corner
            CATransaction.commit()

            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                           owner: self, userInfo: nil))
        }

        func popIn(fromLeft: Bool) {
            container.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.opacity = 1
            container.transform = CATransform3DIdentity
            CATransaction.commit()
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.2
            spring.toValue = 1
            spring.mass = 0.7
            spring.stiffness = 240
            spring.damping = 15
            spring.duration = spring.settlingDuration
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.12
            container.add(spring, forKey: "pop")
            container.add(fade, forKey: "fade")
            // Пункты выезжают по очереди со стороны Бита — как строчки на его экране.
            let now = CACurrentMediaTime()
            for (i, row) in rows.enumerated() {
                let slide = CABasicAnimation(keyPath: "transform.translation.x")
                slide.fromValue = fromLeft ? 14 : -14
                slide.toValue = 0
                let show = CABasicAnimation(keyPath: "opacity")
                show.fromValue = 0
                show.toValue = 1
                let group = CAAnimationGroup()
                group.animations = [slide, show]
                group.duration = 0.22
                group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                group.beginTime = now + QuickMenu.rowDelay(i)
                group.fillMode = .backwards
                row.layer.add(group, forKey: "in")
            }
        }

        func popOut(_ done: @escaping @MainActor () -> Void) {
            CATransaction.begin()
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } }
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1
            shrink.toValue = 0.5
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [shrink, fade]
            group.duration = 0.17
            CATransaction.setDisableActions(true)
            container.opacity = 0
            container.transform = CATransform3DMakeScale(0.5, 0.5, 1)
            container.add(group, forKey: "out")
            CATransaction.commit()
        }

        func setToggle(_ index: Int, _ on: Bool) {
            guard rows.indices.contains(index), let track = rows[index].track, let knob = rows[index].knob else { return }
            toggles[index] = on
            paint(track: track, knob: knob, on: on, animated: true)
        }

        private func paint(track: CALayer, knob: CALayer, on: Bool, animated: Bool) {
            CATransaction.begin()
            CATransaction.setDisableActions(!animated)
            CATransaction.setAnimationDuration(0.18)
            track.backgroundColor = on ? Self.rgb(0x5CF2E0) : Self.rgb(0x2E3546)
            knob.position = knobPosition(on: on)
            CATransaction.commit()
        }

        private func knobPosition(on: Bool) -> CGPoint {
            CGPoint(x: on ? Self.toggleSize.width - 8 : 8, y: Self.toggleSize.height / 2)
        }

        // MARK: Мышь

        override func mouseMoved(with event: NSEvent) { hover(row(at: event)) }
        override func mouseEntered(with event: NSEvent) { hover(row(at: event)) }
        override func mouseExited(with event: NSEvent) { hover(nil) }
        override func mouseDown(with event: NSEvent) { pressed = row(at: event) }
        override func mouseUp(with event: NSEvent) {
            if let index = row(at: event), index == pressed { onPick?(index) }
            pressed = nil
        }

        private func row(at event: NSEvent) -> Int? {
            let p = convert(event.locationInWindow, from: nil)
            return rows.firstIndex { $0.layer.frame.contains(p) }
        }

        private func hover(_ index: Int?) {
            guard index != hovered else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.12)
            if let old = hovered, rows.indices.contains(old) { rows[old].highlight.opacity = 0 }
            if let index { rows[index].highlight.opacity = 1 }
            CATransaction.commit()
            hovered = index
            (index == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
            onHover?(index)
        }

        // MARK: Помощники

        private static func string(_ s: String, _ font: NSFont, _ color: UInt32) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: rgb(color)) ?? .white])
        }

        private static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
        }

        private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
    }

    /// Задержка появления строки: те же такты у карточки и у строчек на экране Бита.
    nonisolated static func rowDelay(_ index: Int) -> CFTimeInterval { 0.08 + 0.035 * Double(index) }
}

import AppKit
import QuartzCore

/// Реплика Бита во всплывающем облачке.
struct Speech {
    /// Важность: встреча перебивает уведомление, уведомление — болтовню.
    enum Kind: Int, Comparable {
        case chat, notice, meeting
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    var text: String
    var detail: String?
    var kind: Kind = .chat
    /// Кнопка в облачке; без неё щелчок просто закрывает облачко.
    var button: String?
    var action: (() -> Void)?
    /// Сколько держать, пока пользователь за компьютером. Отошёл — облачко ждёт.
    var seconds: TimeInterval = 5
    /// После этого момента реплика уже не к месту (встреча прошла): убирается, даже если пользователь отошёл.
    var expires: Date?

    var isExpired: Bool { expires.map { Date() >= $0 } ?? false }
}

/// Говорит по одной реплике: важное перебивает, остальное ждёт в очереди, болтовня не копится.
@MainActor
final class Speaker {
    /// Рамка окна Бита — облачко держится над ним.
    var anchor: () -> NSRect = { .zero }
    /// Пользователь отошёл: время показа не тратится.
    var isAway: () -> Bool = { false }
    /// Бит начал говорить — пусть шевелит ртом.
    var onSpeak: ((Speech) -> Void)?
    /// Что сейчас в облачке (nil — пусто): по нему мигает антенна.
    var onChange: ((Speech?) -> Void)?

    private let bubble = SpeechBubble()
    private var queue: [Speech] = []
    private var remaining: TimeInterval = 0
    private var timer: Timer?
    private var nextAllowed = Date.distantPast
    /// Открыто меню: новые реплики ждут, текущая (кроме болтовни) вернётся после.
    private var suspended = false

    var isSpeaking: Bool { bubble.current != nil }

    init() {
        bubble.onClick = { [weak self] onButton in
            guard let self, let speech = self.bubble.current else { return }
            if onButton { speech.action?() }
            self.finish()
        }
    }

    func say(_ speech: Speech) {
        guard !speech.isExpired else { return }
        if suspended {
            enqueue(speech)
            return
        }
        guard let current = bubble.current else {
            if Date() >= nextAllowed { present(speech) } else { enqueue(speech) }
            return
        }
        if current.text == speech.text && current.detail == speech.detail {
            remaining = max(remaining, speech.seconds)
        } else if speech.kind > current.kind {
            if current.kind != .chat { queue.insert(current, at: 0) }
            present(speech)
        } else {
            enqueue(speech)
        }
    }

    /// Бит сдвинулся — облачко за ним.
    func follow() {
        if bubble.current != nil { bubble.place(near: anchor()) }
    }

    /// Убрать облачко на время (меню открыто); важное дождётся resume().
    func suspend() {
        suspended = true
        if let current = bubble.current {
            if current.kind != .chat { queue.insert(current, at: 0) }
            bubble.hide()
            onChange?(nil)
            timer?.invalidate()
            timer = nil
        }
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        scheduleNext()
    }

    func hide() {
        queue.removeAll()
        if bubble.current != nil { finish() }
    }

    private func enqueue(_ speech: Speech) {
        guard speech.kind != .chat else { return }  // болтовня к месту только сейчас
        guard !queue.contains(where: { $0.text == speech.text && $0.detail == speech.detail }) else { return }
        queue.append(speech)
        queue.sort { $0.kind > $1.kind }
        if queue.count > 4 { queue.removeLast() }
        if bubble.current == nil && !suspended { scheduleNext() }
    }

    private func present(_ speech: Speech) {
        remaining = speech.seconds
        bubble.show(speech, near: anchor())
        onSpeak?(speech)
        onChange?(speech)
        if timer == nil {
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.countdown() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func countdown() {
        guard let current = bubble.current else { return }
        // Mac спал или пользователь отошёл: устаревшее не ждёт его возвращения.
        if current.isExpired {
            finish()
            return
        }
        guard !isAway() else { return }
        remaining -= 0.5
        if remaining <= 0 { finish() }
    }

    private func finish() {
        bubble.hide()
        onChange?(nil)
        timer?.invalidate()
        timer = nil
        nextAllowed = Date().addingTimeInterval(0.4)
        scheduleNext()
    }

    private func scheduleNext() {
        queue.removeAll { $0.isExpired }
        guard !queue.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.suspended, self.bubble.current == nil else { return }
                self.queue.removeAll { $0.isExpired }
                guard !self.queue.isEmpty else { return }
                self.present(self.queue.removeFirst())
            }
        }
    }
}

final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Окошко-облачко: тёмное, как экран Бита, с хвостиком к его голове. Появляется пружинкой из хвостика.
@MainActor
final class SpeechBubble {
    private(set) var current: Speech?
    /// Щелчок по облачку; true — по кнопке.
    var onClick: ((Bool) -> Void)?

    private let panel: BubblePanel
    private let view = BubbleView()
    /// Хвостик снизу — облачко над Битом; сверху — под ним, когда над Битом нет места.
    private var tailDown = true

    fileprivate static let pad: CGFloat = 13
    fileprivate static let margin: CGFloat = 10  // поле под тень
    fileprivate static let tail: CGFloat = 9
    fileprivate static let maxText: CGFloat = 230
    fileprivate static let tailInset: CGFloat = 24  // основание хвостика от бокового края облачка
    fileprivate static let slant: CGFloat = 7        // хвостик наклонён к Биту

    init() {
        panel = BubblePanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 60),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        view.onClick = { [weak self] onButton in self?.onClick?(onButton) }
    }

    func show(_ speech: Speech, near anchor: NSRect) {
        let replacing = current != nil
        current = speech
        view.build(speech)
        place(near: anchor)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        view.popIn(quick: replacing)
    }

    func hide() {
        guard current != nil else { return }
        current = nil
        view.popOut { [weak self] in
            guard let self, self.current == nil else { return }
            self.panel.orderOut(nil)
        }
    }

    /// Слева сверху от Бита: хвостик выходит из левого верхнего угла корпуса.
    /// Слева нет места — справа от правого угла; сверху нет места — снизу от нижнего угла.
    func place(near anchor: NSRect) {
        let size = view.contentSize
        let m = Self.margin
        let screen = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        // Углы корпуса в окне Бита (холст 200x200): скругление на (50, 60) сверху и (50, 144) снизу.
        let left = anchor.minX + anchor.width * 0.24
        let right = anchor.maxX - anchor.width * 0.24
        let top = anchor.maxY - anchor.height * 0.29
        let bottom = anchor.minY + anchor.height * 0.27
        // Кончик хвостика в облачке: у правого края, если облачко слева, и наоборот.
        let inset = Self.tailInset - Self.slant
        let leftTip = size.width - m - inset
        let onLeft = left - leftTip >= screen.minX - m + 4
        let tipX = onLeft ? leftTip : m + inset
        let tip = CGPoint(x: onLeft ? left : right, y: top)
        tailDown = tip.y + size.height - m <= screen.maxY
        var x = tip.x - tipX
        x = min(max(x, screen.minX - m + 4), screen.maxX - size.width + m - 4)
        let y = tailDown ? tip.y - m : bottom - (size.height - m)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
        let slant = onLeft ? Self.slant : -Self.slant
        view.layout(tailDown: tailDown, tailX: tip.x - x - slant, slant: slant)
    }

    // MARK: - Вид

    private final class BubbleView: NSView {
        var onClick: ((Bool) -> Void)?
        private(set) var contentSize = NSSize(width: 100, height: 60)

        private let container = CALayer()
        private let body = CAShapeLayer()
        private let textLayer = LabelLayer()
        private let detailLayer = LabelLayer()
        private let buttonLayer = CALayer()
        private let buttonText = LabelLayer()
        /// Крестик «закрыть» в правом верхнем углу — у облачек с кнопкой, чтобы было видно, как отказаться.
        private let closeLayer = CAShapeLayer()
        private var textSize = CGSize.zero
        private var detailSize = CGSize.zero
        private var buttonHeight: CGFloat = 0
        private var bodySize = CGSize.zero
        private var hovering = false
        private var hoveringClose = false
        private static let closeSize: CGFloat = 16

        private static let ink = rgb(0x1B1F2A, 0.97)
        private static let glow = rgb(0x5CF2E0)
        private static let font = rounded(13, .semibold)
        private static let detailFont = rounded(11.5, .regular)
        private static let buttonFont = rounded(12, .semibold)

        override init(frame: NSRect) {
            super.init(frame: frame)
            layer = CALayer()
            wantsLayer = true
            layer?.addSublayer(container)
            container.addSublayer(body)
            body.fillColor = Self.ink
            body.strokeColor = Self.rgb(0x5CF2E0, 0.45)
            body.lineWidth = 1
            body.shadowColor = .black
            body.shadowOpacity = 0.35
            body.shadowRadius = 6
            body.shadowOffset = CGSize(width: 0, height: -2)
            container.addSublayer(textLayer)
            container.addSublayer(detailLayer)
            buttonLayer.cornerRadius = 8
            buttonLayer.addSublayer(buttonText)
            container.addSublayer(buttonLayer)
            closeLayer.fillColor = nil
            closeLayer.strokeColor = Self.rgb(0x9FB3B8)
            closeLayer.lineWidth = 1.6
            closeLayer.lineCap = .round
            container.addSublayer(closeLayer)
        }

        convenience init() { self.init(frame: .zero) }

        required init?(coder: NSCoder) { fatalError() }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        func build(_ speech: Speech) {
            let pad = SpeechBubble.pad
            let text = Self.string(speech.text, Self.font, 0xE8FBF8)
            textLayer.text = text
            textSize = Self.measure(text)
            if let detail = speech.detail {
                let d = Self.string(detail, Self.detailFont, 0x9FB3B8)
                detailLayer.text = d
                detailSize = Self.measure(d)
            } else {
                detailLayer.text = nil
                detailSize = .zero
            }
            var buttonWidth: CGFloat = 0
            if let title = speech.button {
                let b = Self.string(title, Self.buttonFont, 0x10141C, centered: true)
                buttonText.text = b
                buttonWidth = max(Self.measure(b).width + 28, 96)
                buttonHeight = 26
            } else {
                buttonText.text = nil
                buttonHeight = 0
            }
            buttonLayer.isHidden = speech.button == nil
            detailLayer.isHidden = speech.detail == nil
            closeLayer.isHidden = speech.button == nil
            hovering = false
            hoveringClose = false
            paintButton()

            let closeRoom = closeLayer.isHidden ? 0 : Self.closeSize + 2
            let width = max(textSize.width + closeRoom, detailSize.width, buttonWidth) + 2 * pad
            var height = textSize.height + 2 * (pad - 3)
            if speech.detail != nil { height += 3 + detailSize.height }
            if speech.button != nil { height += 9 + buttonHeight }
            bodySize = CGSize(width: ceil(width), height: ceil(height))
            let m = SpeechBubble.margin
            contentSize = NSSize(width: bodySize.width + 2 * m, height: bodySize.height + SpeechBubble.tail + 2 * m)
        }

        func layout(tailDown: Bool, tailX: CGFloat, slant: CGFloat) {
            let m = SpeechBubble.margin
            let pad = SpeechBubble.pad
            let tail = SpeechBubble.tail
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.bounds = bounds  // не frame: после исчезновения у контейнера остаётся уменьшение
            let rect = CGRect(x: m, y: tailDown ? m + tail : m, width: bodySize.width, height: bodySize.height)
            let tx = min(max(tailX, rect.minX + 20), rect.maxX - 20)
            body.path = Self.bubblePath(rect, tailX: tx, slant: slant, tailDown: tailDown, tail: tail)
            body.shadowPath = body.path

            var y = rect.maxY - (pad - 3) - textSize.height
            textLayer.frame = CGRect(x: rect.minX + pad, y: y, width: textSize.width + 2, height: textSize.height)
            if !detailLayer.isHidden {
                y -= 3 + detailSize.height
                detailLayer.frame = CGRect(x: rect.minX + pad, y: y, width: detailSize.width + 2, height: detailSize.height)
            }
            if !buttonLayer.isHidden {
                y -= 9 + buttonHeight
                buttonLayer.frame = CGRect(x: rect.minX + pad, y: y, width: rect.width - 2 * pad, height: buttonHeight)
                let lineHeight = ceil(Self.buttonFont.ascender - Self.buttonFont.descender)
                buttonText.frame = CGRect(x: 0, y: (buttonHeight - lineHeight) / 2, width: buttonLayer.bounds.width, height: lineHeight)
            }
            if !closeLayer.isHidden {
                let c = Self.closeSize
                closeLayer.frame = CGRect(x: rect.maxX - 7 - c, y: rect.maxY - 7 - c, width: c, height: c)
                let cross = CGMutablePath()
                let i: CGFloat = 4.5
                cross.move(to: CGPoint(x: i, y: i))
                cross.addLine(to: CGPoint(x: c - i, y: c - i))
                cross.move(to: CGPoint(x: c - i, y: i))
                cross.addLine(to: CGPoint(x: i, y: c - i))
                closeLayer.path = cross
            }
            // Растёт из кончика хвостика.
            let tip = CGPoint(x: tx + slant, y: tailDown ? m : rect.maxY + tail)
            container.anchorPoint = CGPoint(x: tip.x / bounds.width, y: tip.y / bounds.height)
            container.position = tip
            CATransaction.commit()

            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                           owner: self, userInfo: nil))
        }

        func popIn(quick: Bool) {
            container.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.opacity = 1
            container.transform = CATransform3DIdentity
            CATransaction.commit()
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = quick ? 0.85 : 0.25
            spring.toValue = 1
            spring.mass = 0.7
            spring.stiffness = 260
            spring.damping = 13
            spring.duration = spring.settlingDuration
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.14
            container.add(spring, forKey: "pop")
            container.add(fade, forKey: "fade")
        }

        func popOut(_ done: @escaping @MainActor () -> Void) {
            CATransaction.begin()
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } }
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1
            shrink.toValue = 0.6
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [shrink, fade]
            group.duration = 0.18
            CATransaction.setDisableActions(true)
            container.opacity = 0
            container.transform = CATransform3DMakeScale(0.6, 0.6, 1)
            container.add(group, forKey: "out")
            CATransaction.commit()
        }

        override func mouseDown(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            onClick?(!onClose(p) && onButton(p))
        }

        override func mouseMoved(with event: NSEvent) { hover(convert(event.locationInWindow, from: nil)) }
        override func mouseEntered(with event: NSEvent) { hover(convert(event.locationInWindow, from: nil)) }
        override func mouseExited(with event: NSEvent) {
            hovering = false
            hoveringClose = false
            paintButton()
            NSCursor.arrow.set()
        }

        private func hover(_ p: NSPoint) {
            let over = onButton(p)
            let close = onClose(p)
            if over != hovering || close != hoveringClose {
                hovering = over
                hoveringClose = close
                paintButton()
            }
            (over || close ? NSCursor.pointingHand : NSCursor.arrow).set()
        }

        private func onButton(_ p: NSPoint) -> Bool {
            !buttonLayer.isHidden && buttonLayer.frame.insetBy(dx: -2, dy: -3).contains(p)
        }

        private func onClose(_ p: NSPoint) -> Bool {
            !closeLayer.isHidden && closeLayer.frame.insetBy(dx: -5, dy: -5).contains(p)
        }

        private func paintButton() {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.12)
            buttonLayer.backgroundColor = hovering ? Self.rgb(0x8AF7EA) : Self.glow
            closeLayer.strokeColor = hoveringClose ? Self.rgb(0xE8FBF8) : Self.rgb(0x9FB3B8)
            CATransaction.commit()
        }

        /// Скруглённый прямоугольник с хвостиком одной линией, чтобы обводка не разрывалась.
        private static func bubblePath(_ r: CGRect, tailX: CGFloat, slant: CGFloat, tailDown: Bool, tail: CGFloat) -> CGPath {
            let radius: CGFloat = 13
            let half: CGFloat = 8
            let p = CGMutablePath()
            p.move(to: CGPoint(x: r.minX + radius, y: r.minY))
            if tailDown {
                p.addLine(to: CGPoint(x: tailX - half, y: r.minY))
                p.addQuadCurve(to: CGPoint(x: tailX + slant, y: r.minY - tail), control: CGPoint(x: tailX - 1, y: r.minY - 3))
                p.addQuadCurve(to: CGPoint(x: tailX + half, y: r.minY), control: CGPoint(x: tailX + 3, y: r.minY - 3))
            }
            p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
            p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + radius), radius: radius)
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
            p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - radius, y: r.maxY), radius: radius)
            if !tailDown {
                p.addLine(to: CGPoint(x: tailX + half, y: r.maxY))
                p.addQuadCurve(to: CGPoint(x: tailX + slant, y: r.maxY + tail), control: CGPoint(x: tailX + 1, y: r.maxY + 3))
                p.addQuadCurve(to: CGPoint(x: tailX - half, y: r.maxY), control: CGPoint(x: tailX - 3, y: r.maxY + 3))
            }
            p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
            p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - radius), radius: radius)
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
            p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + radius, y: r.minY), radius: radius)
            p.closeSubpath()
            return p
        }

        private static func string(_ s: String, _ font: NSFont, _ color: UInt32, centered: Bool = false) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = centered ? .center : .natural
            return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: rgb(color)) ?? .white,
                                                              .paragraphStyle: paragraph])
        }

        private static func measure(_ s: NSAttributedString) -> CGSize {
            let r = s.boundingRect(with: NSSize(width: SpeechBubble.maxText, height: 1000),
                                   options: [.usesLineFragmentOrigin, .usesFontLeading])
            return CGSize(width: ceil(r.width), height: ceil(r.height))
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
}

/// Текст, нарисованный тем же движком, которым он измерен (`boundingRect`). `CATextLayer` переносил строки иначе
/// и обрезал пояснение в одну строку там, где облачко рассчитано на две.
final class LabelLayer: CALayer {
    var text: NSAttributedString? {
        didSet { setNeedsDisplay() }
    }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    override init(layer: Any) {
        super.init(layer: layer)
        text = (layer as? LabelLayer)?.text
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(in ctx: CGContext) {
        guard let text else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        text.draw(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }
}

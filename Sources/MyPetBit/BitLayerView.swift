import AppKit
import Combine

/// Бит на слоях Core Animation: анимации крутит система, приложение тратит CPU только на смену состояния и взгляда.
/// Координаты — те же 200x200 (y вниз), что в references/pets.js, чтобы сверять с референсом.
final class BitLayerView: NSView {
    weak var controller: PetController?

    private let model: PetModel
    private var subscriptions: Set<AnyCancellable> = []

    private let canvas = CALayer()       // система 200x200, масштаб под окно
    private let groundShadow = CAShapeLayer()
    private let motion = CALayer()       // постоянное: парение или дыхание во сне
    private let gesture = CALayer()      // разовое: прыжок, качание
    private let lampGlow = CAShapeLayer()
    private let lamp = CAShapeLayer()
    private let lampFlash = CALayer()    // вспышки лампочки при уведомлении; смена состояния её не сбрасывает
    private let faceMove = CALayer()     // лицо, смещается за взглядом
    private let zz = CALayer()
    private let facePartsLayer = CALayer()  // глаза и рот текущего состояния
    private let screenIcon = CALayer()      // значок на экране, над глазами
    private let headphoneBand = CAShapeLayer()  // дужка — за корпусом
    private let headphoneCups = CALayer()       // чашки — поверх ушек
    private let sweat = CAShapeLayer()          // капля, когда жарко
    private let flashLayer = CAShapeLayer()     // вспышка экрана при скриншоте
    private var lowPower = false
    private var accessoryLayers: [Accessory: CALayer] = [:]
    private var worn: Set<Accessory> = []
    private var pendingHide: Set<ObjectIdentifier> = []  // аксессуары, которые сейчас снимаются
    private let screenText = CALayer()    // таймер и часы: крупные цифры, подпись, рамка-прогресс по краю экрана
    private let screenBig = CATextLayer()
    private let screenSmall = CATextLayer()
    private let screenTrack = CAShapeLayer()
    private let screenProgress = CAShapeLayer()
    private var screenShown: (big: String, small: String?, progress: Double?, tint: UInt32)?
    private let statsLayer = CALayer()     // нагрузка: три строки «CPU / ОЗУ / ДИСК» с полосками и процентами
    private var statsRows: [(label: CATextLayer, track: CALayer, bar: CALayer, value: CATextLayer)] = []
    private var statsShown = false
    private let coffeeLayer = CALayer()   // кружка кофе в углу экрана, пока включён кофе-режим
    private var coffeeOn = false
    private let menuMirror = CALayer()    // строчки меню на экране, пока меню открыто
    private let mirrorCursor = CAShapeLayer()
    private var mirrorLines: [CALayer] = []
    private var mirrorPills: [Int: CALayer] = [:]
    private let leavingLayer = CALayer()  // уходящее лицо: тает, предметы убираются вниз
    private var accessoriesShown = false  // первое надевание — без анимации
    private var antennaStem: CALayer?
    private var antennaCovered = false    // шапка-тыква закрывает антенну
    private var antennaPulled = false     // антенну тянут: её рисует окно AntennaOverlay

    private static let full = CGRect(x: 0, y: 0, width: 200, height: 200)
    /// Файл в руках: у правого нижнего угла корпуса (система 200x200, y вниз). Отсюда его и утаскивают.
    static let heldZone = CGRect(x: 122, y: 110, width: 54, height: 54)
    private let heldLayer = CALayer()
    private let heldIcon = CALayer()
    private let heldBadge = CAShapeLayer()
    private let heldCount = CATextLayer()
    private var heldShown = false
    private static let settle: CFTimeInterval = 0.3   // сколько тело «досматривает» прежнее движение
    private static let propName = "prop"             // предмет на экране: достаётся снизу, убирается вниз
    private static let faceColor = rgb(0x5CF2E0)

    init(model: PetModel, size: CGFloat) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        buildLayers(scale: size / 200)
        model.$state.sink { [weak self] in self?.apply($0) }.store(in: &subscriptions)
        model.$look.sink { [weak self] in self?.applyLook($0) }.store(in: &subscriptions)
        model.$badge.removeDuplicates().sink { [weak self] in self?.applyBadge($0) }.store(in: &subscriptions)
        // sink приходит до записи свойства, поэтому новое значение берём из аргумента.
        model.$lowPower.removeDuplicates().sink { [weak self] on in
            guard let self else { return }
            self.lowPower = on
            self.apply(self.model.state)
        }.store(in: &subscriptions)
        model.$accessories.removeDuplicates().sink { [weak self] worn in
            self?.worn = worn
            self?.updateAccessories()
        }.store(in: &subscriptions)
        applyAppearance()
        buildHeld()
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    // MARK: - Файлы: перетаскивают на Бита — он ловит

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { controller?.filesDragEntered(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { controller?.filesDragEntered(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.filesDragExited() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { controller?.filesDropped(sender) ?? false }

    // MARK: - Мышь: передаём контроллеру

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { controller?.mouseDown(event) }
    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged(event) }
    override func mouseUp(with event: NSEvent) { controller?.mouseUp(event) }
    // Нажатие двумя пальцами (или правой кнопкой) — быстрое меню в стиле Бита.
    override func rightMouseDown(with event: NSEvent) { controller?.showQuickMenu() }
    // Свайп двумя пальцами по трекпаду над Битом — переключить трек.
    override func scrollWheel(with event: NSEvent) { controller?.scrolled(event) }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    // MARK: - Сборка

    private func buildLayers(scale: CGFloat) {
        canvas.bounds = Self.full
        canvas.position = CGPoint(x: bounds.midX, y: bounds.midY)
        canvas.transform = CATransform3DMakeScale(scale, scale, 1)
        canvas.isGeometryFlipped = true
        layer?.addSublayer(canvas)

        groundShadow.frame = CGRect(x: 56, y: 180, width: 88, height: 12)
        groundShadow.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 88, height: 12), transform: nil)
        groundShadow.fillColor = Self.rgb(0x000000, 0.14)
        canvas.addSublayer(groundShadow)
        addAccessories([.mug, .cactus], to: canvas)  // стоят «на полу», не парят

        // Опорная точка — под ножками: оттуда дыхание и качание.
        for l in [motion, gesture] {
            l.bounds = Self.full
            l.anchorPoint = CGPoint(x: 0.5, y: 0.81)
            l.position = CGPoint(x: 100, y: 162)
        }
        canvas.addSublayer(motion)
        motion.addSublayer(gesture)

        let stem = CGMutablePath()
        stem.move(to: CGPoint(x: 100, y: 52))
        stem.addLine(to: CGPoint(x: 100, y: 34))
        let stemLayer = Self.stroke(stem, Self.rgb(0xC9CDD6), 4)
        antennaStem = stemLayer
        gesture.addSublayer(stemLayer)
        lampGlow.frame = Self.full
        lampGlow.path = Self.ellipse(88, 18, 24, 24)
        lampGlow.fillColor = Self.rgb(0xFF7A6B, 0.18)
        lamp.frame = Self.full
        lamp.path = Self.ellipse(93.5, 23.5, 13, 13)
        gesture.addSublayer(lampGlow)
        gesture.addSublayer(lamp)

        // Ножки и ушки-динамики, корпус, экран, блик.
        let parts = Self.rgb(0xD5D9E1)
        for (x, y, w, h, r) in [(64.0, 146.0, 24.0, 16.0, 7.0), (112, 146, 24, 16, 7), (32, 86, 12, 30, 6), (156, 86, 12, 30, 6)] {
            gesture.addSublayer(Self.fill(Self.roundRect(x, y, w, h, r), parts))
        }
        // Наушники: дужка за корпусом видна только над головой.
        let band = CGMutablePath()
        band.move(to: CGPoint(x: 36, y: 92))
        band.addQuadCurve(to: CGPoint(x: 164, y: 92), control: CGPoint(x: 100, y: -40))
        headphoneBand.frame = Self.full
        headphoneBand.path = band
        headphoneBand.fillColor = nil
        headphoneBand.strokeColor = Self.rgb(0x2B303B)
        headphoneBand.lineWidth = 6
        headphoneBand.lineCap = .round
        headphoneBand.addSublayer(Self.stroke(band, Self.rgb(0xFFFFFF, 0.18), 1.5))
        headphoneBand.isHidden = true
        gesture.addSublayer(headphoneBand)

        let shell = Self.fill(Self.roundRect(40, 50, 120, 104, 34), Self.rgb(0xF4F5F7))
        shell.strokeColor = Self.rgb(0xE2E5EB)
        shell.lineWidth = 2
        gesture.addSublayer(shell)
        let screenPath = Self.roundRect(54, 66, 92, 66, 22)
        gesture.addSublayer(Self.fill(screenPath, Self.rgb(0x1B1F2A)))
        let glare = CGMutablePath()
        glare.move(to: CGPoint(x: 64, y: 76))
        glare.addQuadCurve(to: CGPoint(x: 80, y: 70), control: CGPoint(x: 70, y: 70))
        gesture.addSublayer(Self.stroke(glare, Self.rgb(0xFFFFFF, 0.12), 3))

        headphoneCups.frame = Self.full
        for x in [24.0, 158.0] {
            headphoneCups.addSublayer(Self.shaded(Self.roundRect(x, 80, 18, 42, 9), [0x5A6273, 0x2B303B, 0x161A22],
                                                  outline: 0x454C5C))
            headphoneCups.addSublayer(Self.fill(Self.roundRect(x + 6, 90, 6, 22, 3), Self.rgb(0x5CF2E0, 0.8)))
            headphoneCups.addSublayer(Self.stroke(Self.line(x + 4, 86, x + 4, 96), Self.rgb(0xFFFFFF, 0.25), 2))
        }
        headphoneCups.isHidden = true
        gesture.addSublayer(headphoneCups)

        // Головные уборы поверх корпуса; лампочка антенны снова наверх — торчит из шапки.
        addAccessories([.santa, .party], to: gesture)
        gesture.addSublayer(lampGlow)
        gesture.addSublayer(lamp)
        // Вспышка: широкое свечение и яркая середина поверх лампочки (центр — 100, 30).
        lampFlash.frame = Self.full
        lampFlash.opacity = 0
        let flashGlow = Self.fill(Self.ellipse(78, 8, 44, 44), Self.rgb(0xFF7A6B, 0.3))
        let flashRing = Self.fill(Self.ellipse(86, 16, 28, 28), Self.rgb(0xFF7A6B, 0.55))
        let flashCore = Self.fill(Self.ellipse(92.5, 22.5, 15, 15), Self.rgb(0xFFF1EE))
        lampFlash.addSublayer(flashRing)
        lampFlash.addSublayer(flashGlow)
        lampFlash.addSublayer(flashCore)
        gesture.addSublayer(lampFlash)
        addAccessories([.flower], to: gesture)

        // Капля пота у правого верхнего угла корпуса.
        let drop = CGMutablePath()
        drop.move(to: CGPoint(x: 152.5, y: 50))
        drop.addQuadCurve(to: CGPoint(x: 157.5, y: 62), control: CGPoint(x: 158, y: 56))
        drop.addQuadCurve(to: CGPoint(x: 147.5, y: 62), control: CGPoint(x: 152.5, y: 69))
        drop.addQuadCurve(to: CGPoint(x: 152.5, y: 50), control: CGPoint(x: 147, y: 56))
        sweat.frame = Self.full
        sweat.path = drop
        sweat.fillColor = Self.rgb(0x7FD8FF)
        sweat.isHidden = true
        gesture.addSublayer(sweat)

        // Лицо не выходит за экран: маска по форме экрана.
        let faceClip = CALayer()
        faceClip.frame = Self.full
        let mask = Self.fill(screenPath, Self.rgb(0x000000))
        faceClip.mask = mask
        faceMove.frame = Self.full
        leavingLayer.frame = Self.full
        faceMove.addSublayer(leavingLayer)
        facePartsLayer.frame = Self.full
        faceMove.addSublayer(facePartsLayer)
        addAccessories([.glasses], to: faceMove)  // очки двигаются вместе с глазами
        faceClip.addSublayer(faceMove)
        menuMirror.frame = Self.full
        faceClip.addSublayer(menuMirror)
        buildScreenText()
        faceClip.addSublayer(screenText)
        buildStats()
        faceClip.addSublayer(statsLayer)
        buildCoffee()
        faceClip.addSublayer(coffeeLayer)
        // Значок — в правом верхнем углу экрана, неподвижно (лицо за взглядом ездит, значок нет).
        screenIcon.frame = CGRect(x: 121, y: 71, width: 14, height: 14)
        screenIcon.contentsGravity = .resizeAspect
        screenIcon.isHidden = true
        faceClip.addSublayer(screenIcon)
        gesture.addSublayer(faceClip)
        flashLayer.frame = Self.full
        flashLayer.path = screenPath
        flashLayer.fillColor = Self.rgb(0xFFFFFF)
        flashLayer.opacity = 0
        gesture.addSublayer(flashLayer)
        addAccessories([.bow, .scarf], to: gesture)
        // Шапка-тыква надевается на всю голову — поверх экрана, из прорези видны глаза.
        addAccessories([.pumpkin], to: gesture)

        // «Zz» во сне: три буквы поднимаются и тают по очереди.
        zz.frame = Self.full
        canvas.addSublayer(zz)
        let letters: [(String, CGFloat, CGFloat, CGFloat)] = [("z", 132, 48, 14), ("z", 140, 42, 17), ("Z", 150, 36, 20)]
        for (i, (letter, x, y, size)) in letters.enumerated() {
            let text = CATextLayer()
            text.string = letter
            text.font = NSFont.boldSystemFont(ofSize: size)
            text.fontSize = size
            text.foregroundColor = Self.rgb(0x8A93A6)
            text.frame = CGRect(x: x, y: y - size, width: size + 4, height: size + 4)
            text.opacity = 0
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: text.position)
            move.toValue = NSValue(point: CGPoint(x: text.position.x + 10, y: text.position.y - 22))
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 0]
            fade.keyTimes = [0, 0.2, 1]
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.duration = 3
            group.repeatCount = .infinity
            group.timeOffset = Double(i)
            group.isRemovedOnCompletion = false
            text.add(group, forKey: "zz")
            zz.addSublayer(text)
        }
    }

    // MARK: - Аксессуары

    private func addAccessories(_ list: [Accessory], to parent: CALayer) {
        for accessory in list {
            let layer = Self.makeAccessory(accessory)
            accessoryLayers[accessory] = layer
            parent.addSublayer(layer)
        }
    }

    private func updateAccessories() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var appeared: [CALayer] = []
        var vanished: [CALayer] = []
        func show(_ layer: CALayer, _ visible: Bool) {
            let id = ObjectIdentifier(layer)
            if visible {
                if layer.isHidden || pendingHide.contains(id) { appeared.append(layer) }
                pendingHide.remove(id)
                layer.removeAnimation(forKey: "dressOff")
                layer.isHidden = false
            } else if !layer.isHidden && !pendingHide.contains(id) {
                if accessoriesShown { vanished.append(layer) } else { layer.isHidden = true }
            }
        }
        for (accessory, layer) in accessoryLayers { show(layer, worn.contains(accessory)) }
        let headphones = worn.contains(.headphones)
        show(headphoneBand, headphones)
        show(headphoneCups, headphones)
        antennaCovered = worn.contains(.pumpkin)
        refreshAntenna(model.state)
        CATransaction.commit()

        // Снимает: вещь уходит вверх и тает. Надевает: падает сверху с пружинкой — после того, как снял прежнюю.
        let now = CACurrentMediaTime()
        for layer in vanished {
            let id = ObjectIdentifier(layer)
            pendingHide.insert(id)
            let off = CAAnimationGroup()
            let lift = CABasicAnimation(keyPath: "transform.translation.y")
            lift.fromValue = 0
            lift.toValue = -24
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            off.animations = [lift, fade]
            off.duration = 0.3
            off.timingFunction = CAMediaTimingFunction(name: .easeIn)
            off.fillMode = .forwards
            off.isRemovedOnCompletion = false
            layer.add(off, forKey: "dressOff")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
                guard let self, self.pendingHide.contains(id) else { return }
                self.pendingHide.remove(id)
                layer.isHidden = true
                layer.removeAnimation(forKey: "dressOff")
            }
        }
        if accessoriesShown {
            let delay = vanished.isEmpty ? 0 : 0.3
            for layer in appeared {
                let drop = CAKeyframeAnimation(keyPath: "transform.translation.y")
                drop.values = [-26, 4, 0]
                drop.keyTimes = [0, 0.7, 1]
                drop.duration = 0.45
                drop.beginTime = now + delay
                drop.fillMode = .backwards
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = 0.25
                fade.beginTime = now + delay
                fade.fillMode = .backwards
                layer.add(drop, forKey: "dressDrop")
                layer.add(fade, forKey: "dressFade")
            }
        }
        accessoriesShown = true
        updateContentsScale()
    }

    /// Перетекание лица: старое тает, предметы на экране убираются вниз; потом новое проявляется,
    /// а его предметы достаются снизу — сначала убрал прежнее, потом достал новое.
    private func swapFace(to parts: [CALayer]) {
        let now = CACurrentMediaTime()
        let old = facePartsLayer.sublayers ?? []
        let propsLeaving = old.contains { $0.name == Self.propName }
        for layer in old {
            let isProp = layer.name == Self.propName
            let opacity = layer.presentation()?.opacity ?? layer.opacity
            layer.removeFromSuperlayer()
            leavingLayer.addSublayer(layer)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = opacity
            fade.toValue = 0
            // Лицо тает внахлёст с новым, без пустого экрана; предметы — пока убираются.
            fade.duration = isProp ? 0.35 : (propsLeaving ? 0.5 : 0.25)
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            layer.add(fade, forKey: "leave")
            if isProp {
                let away = CABasicAnimation(keyPath: "transform.translation.y")
                away.fromValue = 0
                away.toValue = 46
                away.duration = 0.35
                away.timingFunction = CAMediaTimingFunction(name: .easeIn)
                away.fillMode = .forwards
                away.isRemovedOnCompletion = false
                layer.add(away, forKey: "away")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { old.forEach { $0.removeFromSuperlayer() } }

        let delay = propsLeaving ? 0.3 : 0.08
        for layer in parts {
            facePartsLayer.addSublayer(layer)
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.duration = 0.22
            appear.beginTime = now + delay
            appear.fillMode = .backwards
            layer.add(appear, forKey: "appear")
            if layer.name == Self.propName {
                let takeOut = CAKeyframeAnimation(keyPath: "transform.translation.y")
                takeOut.values = [46, -3, 0]
                takeOut.keyTimes = [0, 0.75, 1]
                takeOut.duration = 0.45
                takeOut.beginTime = now + delay
                takeOut.fillMode = .backwards
                takeOut.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
                layer.add(takeOut, forKey: "takeOut")
            }
        }
    }

    /// Предметы на экране собираются в один слой: так их можно достать и убрать целиком.
    private static func prop(_ layers: [CALayer]) -> CALayer {
        let group = CALayer()
        group.frame = full
        group.name = propName
        layers.forEach(group.addSublayer)
        return group
    }

    /// Задержка, после которой предметы уже достаны — с неё начинаются действия с ними (письмо).
    private static let afterTakeOut: CFTimeInterval = 0.8

    /// Купол шапки: от левого края головы до правого, верх примерно на y = 32.
    private static func dome() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 46, y: 58))
        p.addQuadCurve(to: CGPoint(x: 154, y: 58), control: CGPoint(x: 100, y: 6))
        p.closeSubpath()
        return p
    }

    private static func polygon(_ points: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: points)
        p.closeSubpath()
        return p
    }

    /// Объём: заливка фигуры градиентом, как свет на корпусе Бита (светлее сверху-слева).
    /// Точки градиента — в долях рамки фигуры, y вниз.
    private static func shaded(_ path: CGPath, _ colors: [UInt32],
                               from start: CGPoint = CGPoint(x: 0.2, y: 0), to end: CGPoint = CGPoint(x: 0.8, y: 1),
                               radial: Bool = false, locations: [NSNumber]? = nil, evenOdd: Bool = false,
                               outline: UInt32? = nil) -> CALayer {
        let box = path.boundingBoxOfPath.insetBy(dx: -1, dy: -1)
        let gradient = CAGradientLayer()
        gradient.frame = box
        gradient.colors = colors.map { rgb($0) }
        gradient.locations = locations
        gradient.startPoint = start
        gradient.endPoint = end
        if radial { gradient.type = .radial }
        var shift = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        let mask = CAShapeLayer()
        mask.frame = gradient.bounds
        mask.path = path.copy(using: &shift)
        mask.fillRule = evenOdd ? .evenOdd : .nonZero
        gradient.mask = mask
        guard let outline else { return gradient }
        let group = CALayer()
        group.frame = full
        group.addSublayer(gradient)
        group.addSublayer(stroke(path, rgb(outline), 1.2))
        return group
    }

    private static let leftLit = (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))   // цилиндр: свет слева
    private static let topLit = (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1))    // свет сверху
    private static let ballLit = (CGPoint(x: 0.35, y: 0.3), CGPoint(x: 1, y: 1))  // шар: блик слева сверху

    /// Ладошка на экране (руки у Бита есть только там): бирюзовая, с тёмным контуром экрана.
    private static func mitten(_ x: CGFloat, _ y: CGFloat) -> CAShapeLayer {
        let m = fill(roundRect(x, y, 12, 13, 6), faceColor)
        m.strokeColor = rgb(0x1B1F2A)
        m.lineWidth = 1.5
        return m
    }

    /// Слой аксессуара в системе 200x200, скрыт до надевания. Объём — градиентами, бликами и тенями, как у корпуса.
    /// Наушники рисуются отдельными слоями (дужка за корпусом).
    private static func makeAccessory(_ accessory: Accessory) -> CALayer {
        let l = CALayer()
        l.frame = full
        l.isHidden = true
        let shade = rgb(0x000000, 0.1)
        func highlight(_ x1: CGFloat, _ y1: CGFloat, _ cx: CGFloat, _ cy: CGFloat, _ x2: CGFloat, _ y2: CGFloat,
                       width: CGFloat = 3.5) {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x1, y: y1))
            p.addQuadCurve(to: CGPoint(x: x2, y: y2), control: CGPoint(x: cx, y: cy))
            l.addSublayer(stroke(p, rgb(0xFFFFFF, 0.5), width))
        }
        switch accessory {
        case .santa:
            l.addSublayer(fill(roundRect(46, 64, 108, 5, 2.5), shade))
            l.addSublayer(shaded(dome(), [0xFF7A7E, 0xE5484D, 0xAD2229]))
            highlight(60, 50, 66, 40, 86, 37)
            // Пушистый отворот — из кружков, как мех.
            let fluff = CGMutablePath()
            for x in stride(from: 46.0, through: 154, by: 9) { fluff.addEllipse(in: CGRect(x: x - 7, y: 48, width: 14, height: 17)) }
            l.addSublayer(shaded(fluff, [0xFFFFFF, 0xF1F3F6, 0xCDD2DA], from: topLit.0, to: topLit.1))
            l.addSublayer(shaded(ellipse(138, 28, 20, 20), [0xFFFFFF, 0xEDEFF3, 0xC4C9D2], from: ballLit.0, to: ballLit.1, radial: true))

        case .party:
            let cone = polygon([CGPoint(x: 54, y: 62), CGPoint(x: 88, y: 58), CGPoint(x: 66, y: 14)])
            l.addSublayer(fill(ellipse(54, 57, 34, 7), shade))
            l.addSublayer(shaded(cone, [0xFFD98C, 0xFFB547, 0xD98A12], from: leftLit.0, to: leftLit.1))
            let stripes = CALayer()
            stripes.frame = full
            for y in [26.0, 40, 54] {
                stripes.addSublayer(fill(polygon([CGPoint(x: 40, y: y + 6), CGPoint(x: 100, y: y - 4),
                                                  CGPoint(x: 100, y: y + 2), CGPoint(x: 40, y: y + 12)]), rgb(0xFF7A6B, 0.9)))
            }
            stripes.mask = fill(cone, rgb(0x000000))
            l.addSublayer(stripes)
            highlight(60, 54, 61, 38, 65, 22, width: 2.5)
            l.addSublayer(shaded(ellipse(58, 5, 16, 16), [0xFFB0A6, 0xFF7A6B, 0xC9483D], from: ballLit.0, to: ballLit.1, radial: true))

        case .headphones:
            break

        case .glasses:
            // Очки — на экране, цветом лица.
            for x in [70.0, 106.0] {
                l.addSublayer(fill(roundRect(x, 85, 24, 24, 9), rgb(0x5CF2E0, 0.1)))
                l.addSublayer(stroke(roundRect(x, 85, 24, 24, 9), faceColor, 2.5))
                l.addSublayer(stroke(line(x + 5, 91, x + 9, 89), rgb(0xFFFFFF, 0.55), 2))
            }
            l.addSublayer(stroke(line(94, 95, 106, 95), faceColor, 2.5))

        case .bow:
            l.addSublayer(fill(ellipse(82, 150, 36, 5), shade))
            for side in [-1.0, 1.0] {
                let wing = CGMutablePath()
                wing.move(to: CGPoint(x: 100 + 2 * side, y: 145))
                wing.addQuadCurve(to: CGPoint(x: 100 + 16 * side, y: 136), control: CGPoint(x: 100 + 8 * side, y: 135))
                wing.addQuadCurve(to: CGPoint(x: 100 + 16 * side, y: 154), control: CGPoint(x: 100 + 22 * side, y: 145))
                wing.addQuadCurve(to: CGPoint(x: 100 + 2 * side, y: 145), control: CGPoint(x: 100 + 8 * side, y: 155))
                wing.closeSubpath()
                l.addSublayer(shaded(wing, [0xFFA597, 0xFF7A6B, 0xC9483D], from: topLit.0, to: topLit.1))
                l.addSublayer(stroke(line(100 + 5 * side, 145, 100 + 12 * side, 141), rgb(0xC9483D, 0.6), 1.2))
                l.addSublayer(stroke(line(100 + 5 * side, 145, 100 + 12 * side, 149), rgb(0xC9483D, 0.6), 1.2))
            }
            l.addSublayer(shaded(roundRect(95, 140, 10, 10, 4), [0xFF9A8E, 0xE0655A, 0xA8413A], from: ballLit.0, to: ballLit.1, radial: true))
            highlight(85, 140, 87, 138, 90, 138, width: 2)

        case .scarf:
            // Хвост свисает из-под намотки, с полосками и бахромой.
            let tail = roundRect(122, 142, 18, 34, 7)
            l.addSublayer(shaded(tail, [0xC9554B, 0xFF8F82, 0xE96E62, 0xC9554B], from: leftLit.0, to: leftLit.1,
                                 locations: [0, 0.35, 0.6, 1]))
            for y in [154.0, 163.0] { l.addSublayer(stroke(line(124, y, 138, y), rgb(0xFFFFFF, 0.75), 3)) }
            for x in stride(from: 125.0, through: 137, by: 4) { l.addSublayer(stroke(line(x, 176, x, 181), rgb(0xC9554B), 2)) }
            l.addSublayer(fill(roundRect(44, 147, 112, 4, 2), shade))
            l.addSublayer(shaded(roundRect(42, 133, 116, 16, 8), [0xFFA597, 0xFF7A6B, 0xC9554B], from: topLit.0, to: topLit.1))
            for x in stride(from: 48.0, through: 148, by: 8) {
                for y in [137.0, 142] {
                    let knit = CGMutablePath()
                    knit.addLines(between: [CGPoint(x: x, y: y), CGPoint(x: x + 4, y: y + 4), CGPoint(x: x + 8, y: y)])
                    l.addSublayer(stroke(knit, rgb(0xFFFFFF, 0.3), 1.5))
                }
            }

        case .flower:
            let stem = CGMutablePath()
            stem.move(to: CGPoint(x: 101, y: 46))
            stem.addQuadCurve(to: CGPoint(x: 112, y: 38), control: CGPoint(x: 108, y: 46))
            l.addSublayer(stroke(stem, rgb(0x4E9A5C), 2.5))
            let leaf = CGMutablePath()
            leaf.move(to: CGPoint(x: 104, y: 45))
            leaf.addQuadCurve(to: CGPoint(x: 112, y: 47), control: CGPoint(x: 106, y: 51))
            leaf.addQuadCurve(to: CGPoint(x: 104, y: 45), control: CGPoint(x: 110, y: 42))
            l.addSublayer(shaded(leaf, [0x8BDB98, 0x4E9A5C], from: topLit.0, to: topLit.1))
            for i in 0..<5 {
                let angle = Double(i) * 2 * .pi / 5 - .pi / 2
                l.addSublayer(shaded(ellipse(116 + 6 * cos(angle) - 4.5, 34 + 6 * sin(angle) - 4.5, 9, 9),
                                     [0xFFC6DB, 0xFF8FB8, 0xE0679C], from: ballLit.0, to: ballLit.1, radial: true))
            }
            l.addSublayer(shaded(ellipse(112, 30, 8, 8), [0xFFE39A, 0xFFB547, 0xD98A12], from: ballLit.0, to: ballLit.1, radial: true))

        case .mug:
            l.addSublayer(fill(ellipse(156, 183, 28, 5), rgb(0x000000, 0.14)))
            let steam = CALayer()
            steam.frame = full
            for (x, top) in [(165.0, 136.0), (172.0, 142.0)] {
                let s = CGMutablePath()
                s.move(to: CGPoint(x: x, y: 160))
                s.addQuadCurve(to: CGPoint(x: x, y: (160 + top) / 2), control: CGPoint(x: x - 4, y: (160 + (160 + top) / 2) / 2))
                s.addQuadCurve(to: CGPoint(x: x, y: top), control: CGPoint(x: x + 4, y: ((160 + top) / 2 + top) / 2))
                steam.addSublayer(stroke(s, rgb(0xFFFFFF, 0.55), 2))
            }
            let rise = CAAnimationGroup()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.2
            fade.toValue = 1
            let lift = CABasicAnimation(keyPath: "transform.translation.y")
            lift.fromValue = 0
            lift.toValue = -4
            rise.animations = [fade, lift]
            rise.duration = 1.2
            rise.autoreverses = true
            rise.repeatCount = .infinity
            steam.add(rise, forKey: "steam")
            l.addSublayer(steam)
            l.addSublayer(stroke(roundRect(172, 170, 13, 12, 5), rgb(0xC9CDD6), 3.5))
            l.addSublayer(stroke(roundRect(172, 170, 13, 12, 5), rgb(0xFFFFFF, 0.6), 1))
            l.addSublayer(shaded(roundRect(160, 166, 18, 20, 4), [0xC9CDD6, 0xFFFFFF, 0xF4F5F7, 0xC9CDD6],
                                 from: leftLit.0, to: leftLit.1, locations: [0, 0.3, 0.6, 1], outline: 0xC9CDD6))
            l.addSublayer(fill(roundRect(160, 174, 18, 3, 1), rgb(0x5CF2E0, 0.9)))
            let rim = fill(ellipse(160, 163.5, 18, 5), rgb(0xF4F5F7))
            rim.strokeColor = rgb(0xC9CDD6)
            rim.lineWidth = 1
            l.addSublayer(rim)
            l.addSublayer(shaded(ellipse(161.5, 164.5, 15, 3.5), [0x8A6450, 0x5C3D2E], from: topLit.0, to: topLit.1))

        case .cactus:
            l.addSublayer(fill(ellipse(154, 183, 32, 5), rgb(0x000000, 0.14)))
            let greens: [UInt32] = [0x3E8A4E, 0x8BDB98, 0x5AB46A, 0x3E8A4E]
            let round: [NSNumber] = [0, 0.3, 0.55, 1]
            for rect in [CGRect(x: 158, y: 156, width: 8, height: 10), CGRect(x: 174, y: 152, width: 8, height: 12),
                         CGRect(x: 164, y: 144, width: 12, height: 26)] {
                let r = min(rect.width, rect.height) / 2
                l.addSublayer(shaded(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil), greens,
                                     from: leftLit.0, to: leftLit.1, locations: round))
            }
            l.addSublayer(stroke(line(170, 149, 170, 166), rgb(0x3E8A4E, 0.5), 1.2))
            for (x, y) in [(166.0, 150.0), (173, 158), (166, 162), (176, 156)] { l.addSublayer(fill(ellipse(x, y, 2, 2), rgb(0xFFFFFF, 0.75))) }
            l.addSublayer(shaded(ellipse(166, 140, 8, 6), [0xFFC6DB, 0xFF8FB8], from: ballLit.0, to: ballLit.1, radial: true))
            l.addSublayer(shaded(polygon([CGPoint(x: 158, y: 172), CGPoint(x: 182, y: 172), CGPoint(x: 179, y: 186), CGPoint(x: 161, y: 186)]),
                                 [0xB94A40, 0xFF8F82, 0xE0655A, 0xA8413A], from: leftLit.0, to: leftLit.1, locations: round))
            l.addSublayer(shaded(roundRect(156, 168, 28, 6, 3), [0xFF9A8E, 0xD9584B], from: topLit.0, to: topLit.1))

        case .pumpkin:
            // Шапка-тыква по референсу: тыква на всю голову, прорезь по форме экрана с «бровями»,
            // нижний край закрывает рот и свисает клыками, сверху хвостик вместо антенны.
            let outer = CGMutablePath()
            outer.move(to: CGPoint(x: 34, y: 138))
            outer.addCurve(to: CGPoint(x: 100, y: 26), control1: CGPoint(x: 22, y: 84), control2: CGPoint(x: 44, y: 28))
            outer.addCurve(to: CGPoint(x: 166, y: 138), control1: CGPoint(x: 156, y: 28), control2: CGPoint(x: 178, y: 84))
            for point in [CGPoint(x: 154, y: 162), CGPoint(x: 144, y: 142), CGPoint(x: 128, y: 168), CGPoint(x: 116, y: 144),
                          CGPoint(x: 100, y: 152), CGPoint(x: 84, y: 144), CGPoint(x: 72, y: 168), CGPoint(x: 56, y: 142),
                          CGPoint(x: 46, y: 162)] { outer.addLine(to: point) }
            outer.closeSubpath()
            let hole = CGMutablePath()
            hole.move(to: CGPoint(x: 54, y: 104))
            hole.addQuadCurve(to: CGPoint(x: 76, y: 68), control: CGPoint(x: 56, y: 72))
            hole.addQuadCurve(to: CGPoint(x: 100, y: 82), control: CGPoint(x: 92, y: 66))
            hole.addQuadCurve(to: CGPoint(x: 124, y: 68), control: CGPoint(x: 108, y: 66))
            hole.addQuadCurve(to: CGPoint(x: 146, y: 104), control: CGPoint(x: 144, y: 72))
            for point in [CGPoint(x: 140, y: 116), CGPoint(x: 130, y: 110), CGPoint(x: 120, y: 118), CGPoint(x: 110, y: 111),
                          CGPoint(x: 100, y: 118), CGPoint(x: 90, y: 111), CGPoint(x: 80, y: 118), CGPoint(x: 70, y: 110),
                          CGPoint(x: 60, y: 116)] { hole.addLine(to: point) }
            hole.closeSubpath()
            let shape = CGMutablePath()
            shape.addPath(outer)
            shape.addPath(hole)

            l.addSublayer(shaded(roundRect(90, 8, 20, 26, 9), [0x5A9A2E, 0xA6DB6A, 0x7BC043, 0x5A9A2E],
                                 from: leftLit.0, to: leftLit.1, locations: [0, 0.3, 0.6, 1], outline: 0x4E8A26))
            l.addSublayer(shaded(shape, [0xFFA35C, 0xFF7A1F, 0xD2560A], from: CGPoint(x: 0.3, y: 0), to: CGPoint(x: 0.7, y: 1),
                                 evenOdd: true))
            let edge = stroke(shape, rgb(0xC24F0A), 2)
            edge.lineJoin = .round
            l.addSublayer(edge)
            // Дольки: тёмные дуги, не заходящие в прорезь.
            let ribs = CALayer()
            ribs.frame = full
            for x in [52.0, 74, 126, 148] {
                let rib = CGMutablePath()
                rib.move(to: CGPoint(x: 100 + (x - 100) * 0.35, y: 30))
                rib.addQuadCurve(to: CGPoint(x: x, y: 140), control: CGPoint(x: x + (x - 100) * 0.3, y: 70))
                ribs.addSublayer(stroke(rib, rgb(0xC24F0A, 0.8), 2.5))
            }
            ribs.addSublayer(stroke(line(100, 28, 100, 80), rgb(0xC24F0A, 0.8), 2.5))
            let ribMask = fill(shape, rgb(0x000000))
            ribMask.fillRule = .evenOdd
            ribs.mask = ribMask
            l.addSublayer(ribs)
            highlight(44, 100, 42, 58, 66, 42, width: 4)
        }
        return l
    }

    /// Сердечко с центром (cx, cy) и размером s: нижний кончик внизу (y вниз).
    private static func heart(_ cx: CGFloat, _ cy: CGFloat, _ s: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: cx, y: cy + 0.45 * s))
        p.addCurve(to: CGPoint(x: cx, y: cy - 0.2 * s),
                   control1: CGPoint(x: cx - 0.65 * s, y: cy + 0.05 * s), control2: CGPoint(x: cx - 0.35 * s, y: cy - 0.6 * s))
        p.addCurve(to: CGPoint(x: cx, y: cy + 0.45 * s),
                   control1: CGPoint(x: cx + 0.35 * s, y: cy - 0.6 * s), control2: CGPoint(x: cx + 0.65 * s, y: cy + 0.05 * s))
        p.closeSubpath()
        return p
    }

    // MARK: - Состояние и взгляд

    private func apply(_ state: PetState) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let awake = state != .sleep
        // Перетекание тела: текущее движение плавно возвращается в покой, новые циклы начинаются после (см. loop).
        for l in [motion, gesture, groundShadow] {
            let current = l.presentation()?.transform ?? l.transform
            let opacity = l.presentation()?.opacity ?? l.opacity
            l.removeAllAnimations()
            let back = CABasicAnimation(keyPath: "transform")
            back.fromValue = NSValue(caTransform3D: current)
            back.toValue = NSValue(caTransform3D: l.transform)
            back.duration = Self.settle
            back.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            l.add(back, forKey: "settle")
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = opacity
            fade.toValue = l.opacity
            fade.duration = Self.settle
            l.add(fade, forKey: "settleFade")
        }
        for l in [lamp, sweat] { l.removeAllAnimations() }

        if awake {
            // Устал или грустит — парит медленнее; при энергосбережении всё ещё в полтора раза медленнее.
            let half = (state == .drowsy || state == .sad ? 2.6 : 1.6) * (lowPower ? 1.5 : 1)
            motion.add(Self.loop("transform.translation.y", 0, -6, half), forKey: "float")
            groundShadow.add(Self.loop("transform.scale.x", 1, 0.86, half), forKey: "scale")
            groundShadow.add(Self.loop("opacity", 1, 0.57, half), forKey: "fade")
        } else {
            motion.add(Self.loop("transform",
                                 NSValue(caTransform3D: CATransform3DIdentity),
                                 NSValue(caTransform3D: CATransform3DMakeScale(1.025, 0.975, 1)), 2.4), forKey: "breathe")
        }

        if state == .happy {
            let jump = CAKeyframeAnimation(keyPath: "transform.translation.y")
            jump.values = [0, -12, 0]
            jump.keyTimes = [0, 0.5, 1]
            jump.duration = 0.4
            jump.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
            gesture.add(jump, forKey: "jump")
        }
        if state == .dizzy {
            gesture.add(Self.loop("transform.rotation.z", -0.09, 0.09, 0.35), forKey: "wobble")
        }
        if state == .purr {
            gesture.add(Self.loop("transform.translation.x", -0.8, 0.8, 0.06), forKey: "purr")  // мелкая дрожь
        }
        if state == .dance {
            gesture.add(Self.loop("transform.rotation.z", -0.07, 0.07, 0.45), forKey: "sway")
        }
        if state == .boxing {
            gesture.add(Self.loop("transform.translation.x", -2.5, 2.5, 0.3), forKey: "bob")  // пританцовывает
        }
        sweat.isHidden = state != .hot && state != .workout
        if state == .hot || state == .workout {
            let drip = CAAnimationGroup()
            let fall = CABasicAnimation(keyPath: "transform.translation.y")
            fall.fromValue = 0
            fall.toValue = 10
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.2, 0.7, 1]
            drip.animations = [fall, fade]
            drip.duration = 1.6
            drip.repeatCount = .infinity
            sweat.add(drip, forKey: "drip")
        }

        lamp.fillColor = awake ? Self.rgb(0xFF7A6B) : Self.rgb(0x6B5A60)
        refreshAntenna(state)
        if state == .work { lamp.add(Self.loop("opacity", 1, 0.35, 0.7), forKey: "pulse") }
        zz.isHidden = awake
        if !awake { faceMove.setAffineTransform(.identity) }

        swapFace(to: Self.faceParts(state))
        if state != .timer && state != .clock {
            hideScreenText()
            hideStats()
        }
        updateCoffee(state)
        updateContentsScale()
    }

    /// Значок на экране: новый сначала крупно вместо лица, потом уезжает в правый верхний угол экрана.
    private func applyBadge(_ badge: PetBadge?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let badge else {
            screenIcon.isHidden = true
            screenIcon.removeAllAnimations()
            facePartsLayer.removeAnimation(forKey: "badgeIntro")
            return
        }
        let config = NSImage.SymbolConfiguration(pointSize: 40, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(cgColor: Self.rgb(badge.color)) ?? .systemRed]))
        let symbol = NSImage(systemSymbolName: badge.symbol, accessibilityDescription: badge.title)
            ?? NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: badge.title)
        let image = symbol?.withSymbolConfiguration(config)
        screenIcon.contents = image?.layerContents(forContentsScale: window?.backingScaleFactor ?? 2)
        screenIcon.isHidden = false

        // Центр значка (128, 78) → центр экрана (100, 99), размер 14 → 44.
        let big = CATransform3DScale(CATransform3DMakeTranslation(-28, 21, 0), 44.0 / 14, 44.0 / 14, 1)
        let intro = CAKeyframeAnimation(keyPath: "transform")
        intro.values = [CATransform3DScale(big, 0.3, 0.3, 1), big, big, CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
        intro.keyTimes = [0, 0.1, 0.72, 1]
        intro.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear),
                                 CAMediaTimingFunction(name: .easeInEaseOut)]
        intro.duration = 2.2
        screenIcon.add(intro, forKey: "badgeIntro")
        // Пока значок крупный, лица нет.
        let hideFace = CAKeyframeAnimation(keyPath: "opacity")
        hideFace.values = [0, 0, 1]
        hideFace.keyTimes = [0, 0.72, 1]
        hideFace.duration = 2.2
        facePartsLayer.add(hideFace, forKey: "badgeIntro")
    }

    /// Антенну тянут — своя прячется, пока её рисует окно поверх.
    func setAntennaPulled(_ pulled: Bool) {
        antennaPulled = pulled
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        refreshAntenna(model.state)
        CATransaction.commit()
    }

    private func refreshAntenna(_ state: PetState) {
        let hidden = antennaCovered || antennaPulled
        antennaStem?.isHidden = hidden
        lamp.isHidden = hidden
        lampFlash.isHidden = hidden
        lampGlow.isHidden = hidden || state == .sleep || lowPower
    }

    /// Уведомление в облачке: лампочка антенны мигает двойными вспышками, пока облачко висит.
    func setAntennaAlert(_ on: Bool) {
        guard on else {
            lampFlash.removeAnimation(forKey: "alert")
            return
        }
        guard lampFlash.animation(forKey: "alert") == nil else { return }
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [0, 1, 0.1, 1, 0, 0]
        blink.keyTimes = [0, 0.08, 0.2, 0.3, 0.45, 1]
        blink.duration = 1.4
        blink.repeatCount = .infinity
        lampFlash.add(blink, forKey: "alert")
    }

    /// Вспышка экрана — «щёлк» при скриншоте.
    func flash() {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [0, 0.9, 0]
        a.keyTimes = [0, 0.15, 1]
        a.duration = 0.5
        flashLayer.add(a, forKey: "flash")
    }

    /// Вздрогнуть и отпрянуть в сторону `direction` (-1 влево, 1 вправо). На canvas, чтобы смена состояния не сбросила.
    func flinch(_ direction: CGFloat) {
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, 10 * direction, 0]
        a.keyTimes = [0, 0.3, 1]
        a.duration = 0.45
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        canvas.add(a, forKey: "flinch")
    }

    /// Тёмная тема: чёрная тень на тёмных обоях не видна.
    private func applyAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        groundShadow.fillColor = dark ? Self.rgb(0xFFFFFF, 0.12) : Self.rgb(0x000000, 0.14)
        CATransaction.commit()
    }

    private func applyLook(_ look: CGPoint) {
        guard model.state != .sleep else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        faceMove.setAffineTransform(CGAffineTransform(translationX: look.x * 6, y: look.y * 4))
        CATransaction.commit()
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? 2
        func walk(_ l: CALayer) {
            l.contentsScale = scale
            l.sublayers?.forEach(walk)
        }
        walk(canvas)
    }

    private static func faceParts(_ state: PetState) -> [CALayer] {
        let c = faceColor
        switch state {
        case .idle:
            return [eye(76, 88, 12, 20), eye(112, 88, 12, 20), stroke(arc(94, 117, 106, controlY: 122), c, 3)]

        case .talk:
            // Говорит: глаза приветливо прищурены снизу, рот открывается и закрывается в такт словам.
            let mouth = CAShapeLayer()
            mouth.frame = CGRect(x: 93, y: 111, width: 14, height: 11)
            mouth.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 14, height: 11), transform: nil)
            mouth.fillColor = rgb(0x2E3546)
            mouth.strokeColor = c
            mouth.lineWidth = 3
            let chatter = CAKeyframeAnimation(keyPath: "transform.scale.y")
            chatter.values = [0.25, 1, 0.45, 0.9, 0.25, 0.25]
            chatter.keyTimes = [0, 0.18, 0.36, 0.56, 0.78, 1]
            chatter.duration = 0.9
            chatter.repeatCount = .infinity
            chatter.beginTime = CACurrentMediaTime() + settle
            chatter.fillMode = .backwards
            mouth.add(chatter, forKey: "chatter")
            return [eye(76, 87, 12, 19), eye(112, 87, 12, 19), mouth]

        case .timer:
            return []  // весь экран — цифры и рамка (showScreenText)

        case .clock:
            return []  // весь экран — часы

        case .menu:
            // Открыто меню: глаза поднимаются к верху экрана, ниже — строчки меню (showMenuMirror).
            return [eye(80, 72, 10, 14), eye(110, 72, 10, 14)]

        case .wave:
            // Машет: радостные глаза и рот чуть левее, справа на экране ладошка качается от запястья.
            let smile = arc(84, 111, 100, controlY: 124)
            smile.closeSubpath()
            let mouth = fill(smile, c)
            mouth.strokeColor = c
            mouth.lineWidth = 2
            mouth.lineJoin = .round
            let palm = CALayer()
            palm.bounds = CGRect(x: 0, y: 0, width: 14, height: 18)
            palm.anchorPoint = CGPoint(x: 0.5, y: 1)  // качается от запястья
            palm.position = CGPoint(x: 126, y: 117)
            palm.addSublayer(mitten(1, 0))
            palm.addSublayer(fill(roundRect(4.5, 12, 5, 6, 2), c))  // запястье уходит за край экрана
            palm.add(loop("transform.rotation.z", -0.45, 0.35, 0.22), forKey: "wave")
            return [stroke(arc(66, 101, 82, controlY: 88), c, 5), stroke(arc(96, 101, 112, controlY: 88), c, 5), mouth, prop([palm])]

        case .happy:
            let mouthPath = arc(91, 113, 109, controlY: 127)
            mouthPath.closeSubpath()
            let mouth = fill(mouthPath, c)
            mouth.strokeColor = c
            mouth.lineWidth = 2
            mouth.lineJoin = .round
            return [stroke(arc(73, 104, 91, controlY: 90), c, 5), stroke(arc(109, 104, 127, controlY: 90), c, 5), mouth]

        case .sleep:
            let dim = rgb(0x5CF2E0, 0.7)
            return [stroke(arc(73, 100, 91, controlY: 107), dim, 4), stroke(arc(109, 100, 127, controlY: 107), dim, 4),
                    stroke(ellipse(97, 114, 6, 6), dim, 2.5)]

        case .work:
            let track = CALayer()
            track.frame = CGRect(x: 70, y: 110, width: 60, height: 7)
            track.backgroundColor = rgb(0x2E3546)
            track.cornerRadius = 3.5
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0, y: 0.5)
            bar.bounds = CGRect(x: 0, y: 0, width: 60, height: 7)
            bar.position = CGPoint(x: 70, y: 113.5)
            bar.backgroundColor = c
            bar.cornerRadius = 3.5
            let grow = CAKeyframeAnimation(keyPath: "bounds.size.width")
            grow.values = [3, 60, 60]
            grow.keyTimes = [0, 0.8, 1]
            grow.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear)]
            grow.duration = 2.4
            grow.repeatCount = .infinity
            bar.add(grow, forKey: "progress")
            return [eye(78, 84, 11, 15), eye(111, 84, 11, 15), track, bar]

        case .surprised:
            return [fill(ellipse(74, 88, 16, 16), c), fill(ellipse(110, 88, 16, 16), c), stroke(ellipse(95, 111, 10, 11), c, 3)]

        case .sad:
            // Брови домиком: внутренние концы выше внешних; рот — дуга вниз.
            return [eye(77, 92, 11, 16), eye(112, 92, 11, 16),
                    stroke(line(74, 87, 88, 82), c, 3), stroke(line(112, 82, 126, 87), c, 3),
                    stroke(arc(93, 121, 107, controlY: 114), c, 3)]

        case .drowsy:
            // Полуприкрытые глаза-полумесяцы, медленно слипаются; рот — маленькое «о».
            return [sleepyEye(74, 96), sleepyEye(110, 96), stroke(ellipse(97, 115, 6, 5), c, 2.5)]

        case .purr:
            // Жмурится, румянец, кошачий рот «ω».
            let blush = rgb(0xFF7A6B, 0.45)
            let mouth = CGMutablePath()
            mouth.move(to: CGPoint(x: 92, y: 116))
            mouth.addQuadCurve(to: CGPoint(x: 100, y: 116), control: CGPoint(x: 96, y: 121))
            mouth.addQuadCurve(to: CGPoint(x: 108, y: 116), control: CGPoint(x: 104, y: 121))
            return [stroke(arc(73, 102, 91, controlY: 92), c, 4.5), stroke(arc(109, 102, 127, controlY: 92), c, 4.5),
                    fill(ellipse(62, 108, 14, 7), blush), fill(ellipse(124, 108, 14, 7), blush),
                    stroke(mouth, c, 3)]

        case .shush:
            // «Тсс»: глаза закрыты, у губ — палец.
            return [stroke(arc(73, 100, 91, controlY: 105), c, 4), stroke(arc(109, 100, 127, controlY: 105), c, 4),
                    stroke(ellipse(94, 113, 12, 9), c, 2.5), fill(roundRect(97, 102, 6, 24, 3), c)]

        case .yawn:
            let mouth = fill(ellipse(90, 104, 20, 22), rgb(0x2E3546))
            mouth.strokeColor = c
            mouth.lineWidth = 3
            let open = CABasicAnimation(keyPath: "transform.scale.y")
            open.fromValue = 0.4
            open.toValue = 1
            open.duration = 0.8
            open.timingFunction = CAMediaTimingFunction(name: .easeOut)
            mouth.frame = CGRect(x: 90, y: 104, width: 20, height: 22)
            mouth.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 20, height: 22), transform: nil)
            mouth.add(open, forKey: "open")
            return [stroke(arc(72, 94, 90, controlY: 89), c, 4), stroke(arc(110, 94, 128, controlY: 89), c, 4), mouth]

        case .hot:
            // Глаза «> <», рот волной.
            let left = CGMutablePath()
            left.addLines(between: [CGPoint(x: 75, y: 90), CGPoint(x: 88, y: 97), CGPoint(x: 75, y: 104)])
            let right = CGMutablePath()
            right.addLines(between: [CGPoint(x: 125, y: 90), CGPoint(x: 112, y: 97), CGPoint(x: 125, y: 104)])
            let mouth = CGMutablePath()
            mouth.move(to: CGPoint(x: 90, y: 119))
            mouth.addQuadCurve(to: CGPoint(x: 100, y: 119), control: CGPoint(x: 95, y: 114))
            mouth.addQuadCurve(to: CGPoint(x: 110, y: 119), control: CGPoint(x: 105, y: 124))
            return [stroke(left, c, 4), stroke(right, c, 4), stroke(mouth, c, 3)]

        case .note:
            // Записывает: лицо почти на обычном месте, глаза чуть опущены, от усердия кончик языка.
            // Ладошка с карандашом выдвигается снизу и выводит строчку по низу экрана, под ртом.
            var parts: [CALayer] = [eye(77, 92, 11, 15), eye(112, 92, 11, 15),
                                    stroke(line(95, 117, 103, 117), c, 2.5), fill(ellipse(98, 116, 5, 5), rgb(0xFF7A6B))]
            let scribble = CGMutablePath()
            scribble.move(to: CGPoint(x: 74, y: 126))
            for i in 1...10 {
                scribble.addQuadCurve(to: CGPoint(x: 74 + CGFloat(i) * 4, y: 126),
                                      control: CGPoint(x: 72 + CGFloat(i) * 4, y: i % 2 == 0 ? 123.5 : 128.5))
            }
            let writing = stroke(scribble, c, 1.5)
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = 1.8
            draw.beginTime = CACurrentMediaTime() + afterTakeOut
            draw.fillMode = .backwards
            writing.add(draw, forKey: "draw")
            let hand = CALayer()
            hand.bounds = CGRect(x: 0, y: 0, width: 24, height: 18)
            hand.anchorPoint = CGPoint(x: 0, y: 1)  // кончик карандаша
            hand.addSublayer(stroke(line(1, 17, 15, 9), rgb(0xFFB547), 3))
            hand.addSublayer(fill(ellipse(0, 15.5, 3, 3), c))
            let mitt = fill(roundRect(13, 3, 10, 11, 5), c)
            mitt.strokeColor = rgb(0x1B1F2A)
            mitt.lineWidth = 1.5
            hand.addSublayer(mitt)
            let move = CAKeyframeAnimation(keyPath: "position")
            move.values = (0...10).map { i in NSValue(point: CGPoint(x: 74 + Double(i) * 4, y: i % 2 == 0 ? 126 : 128)) }
            move.duration = 1.8
            move.beginTime = CACurrentMediaTime() + afterTakeOut
            move.fillMode = .backwards
            hand.add(move, forKey: "write")
            hand.position = CGPoint(x: 114, y: 126)
            parts.append(prop([writing, hand]))
            return parts

        case .dance:
            return [stroke(arc(73, 102, 91, controlY: 92), c, 4.5), stroke(arc(109, 102, 127, controlY: 92), c, 4.5),
                    stroke(arc(92, 115, 108, controlY: 123), c, 3)]

        case .love:
            // Глаза-сердечки, румянец, кошачий рот «ω» — гладят на высшем уровне привязанности.
            let pink = rgb(0xFF5E8A)
            let beat = CABasicAnimation(keyPath: "transform.scale")
            beat.fromValue = 1
            beat.toValue = 1.15
            beat.duration = 0.4
            beat.autoreverses = true
            beat.repeatCount = .infinity
            var parts: [CALayer] = []
            for cx in [82.0, 118.0] {
                let h = fill(heart(11, 11, 22), pink)
                h.frame = CGRect(x: cx - 11, y: 87, width: 22, height: 22)
                h.add(beat, forKey: "beat")
                parts.append(h)
            }
            let mouth = CGMutablePath()
            mouth.move(to: CGPoint(x: 92, y: 116))
            mouth.addQuadCurve(to: CGPoint(x: 100, y: 116), control: CGPoint(x: 96, y: 121))
            mouth.addQuadCurve(to: CGPoint(x: 108, y: 116), control: CGPoint(x: 104, y: 121))
            parts += [fill(ellipse(62, 108, 14, 7), rgb(0xFF7A6B, 0.45)), fill(ellipse(124, 108, 14, 7), rgb(0xFF7A6B, 0.45)),
                      stroke(mouth, c, 3)]
            return parts

        case .reading:
            // Читает: книгу держат две ладошки, глаза бегут по строчкам. Руки у Бита есть только на экране.
            var parts: [CALayer] = []
            for x in [84.0, 108.0] {
                let e = eye(x, 74, 8, 10)
                let scan = CAKeyframeAnimation(keyPath: "position.x")
                scan.values = [e.position.x - 3, e.position.x + 3, e.position.x - 3]
                scan.keyTimes = [0, 0.85, 1]
                scan.duration = 2.4
                scan.repeatCount = .infinity
                e.add(scan, forKey: "scan")
                parts.append(e)
            }
            let leftPage = CGMutablePath()
            leftPage.move(to: CGPoint(x: 64, y: 98))
            leftPage.addQuadCurve(to: CGPoint(x: 99, y: 100), control: CGPoint(x: 82, y: 92))
            leftPage.addLine(to: CGPoint(x: 99, y: 124))
            leftPage.addQuadCurve(to: CGPoint(x: 64, y: 122), control: CGPoint(x: 82, y: 116))
            leftPage.closeSubpath()
            var mirror = CGAffineTransform(translationX: 200, y: 0).scaledBy(x: -1, y: 1)
            let rightPage = leftPage.copy(using: &mirror)!
            for page in [leftPage, rightPage] {
                let p = fill(page, rgb(0x5CF2E0, 0.14))
                p.strokeColor = c
                p.lineWidth = 2
                p.lineJoin = .round
                parts.append(p)
            }
            for i in 0..<3 {
                let y = 104 + CGFloat(i) * 6
                parts.append(stroke(line(69, y, 93, y + 1), rgb(0x5CF2E0, 0.45), 1.5))
                parts.append(stroke(line(107, y + 1, 131, y), rgb(0x5CF2E0, 0.45), 1.5))
            }
            // Перелистывается правая страница вокруг корешка.
            let flipping = CAShapeLayer()
            flipping.bounds = full
            flipping.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            flipping.position = CGPoint(x: 100, y: 100)
            flipping.path = rightPage
            flipping.fillColor = rgb(0x1B1F2A)
            flipping.strokeColor = c
            flipping.lineWidth = 2
            let flip = CAKeyframeAnimation(keyPath: "transform.scale.x")
            flip.values = [1, 1, -1, -1]
            flip.keyTimes = [0, 0.8, 0.92, 1]
            flip.duration = 5
            flip.repeatCount = .infinity
            let show = CAKeyframeAnimation(keyPath: "opacity")
            show.values = [0, 0, 1, 1, 0]
            show.keyTimes = [0, 0.78, 0.8, 0.97, 1]
            show.duration = 5
            show.repeatCount = .infinity
            flipping.add(flip, forKey: "flip")
            flipping.add(show, forKey: "show")
            parts.append(flipping)
            for x in [57.0, 131.0] { parts.append(mitten(x, 112)) }
            return Array(parts[..<2]) + [prop(Array(parts[2...]))]

        case .tetris:
            // Экран — игровое поле: стопка внизу и падающая фигура «Т», которая ложится в просвет.
            let colors: [UInt32] = [0x5CF2E0, 0xFF7A6B, 0xFFB547, 0x5AB46A, 0x3A7BFF]
            var parts: [CALayer] = [stroke(roundRect(74, 70, 52, 58, 4), rgb(0xFFFFFF, 0.15), 1.5)]
            let stack = [(0, 8, 0), (1, 8, 1), (2, 8, 1), (4, 8, 2), (5, 8, 3), (6, 8, 3), (7, 8, 4),
                         (0, 7, 0), (1, 7, 2), (5, 7, 4), (6, 7, 4), (7, 7, 1), (0, 6, 3)]
            for (col, row, color) in stack {
                parts.append(fill(roundRect(76 + CGFloat(col) * 6, 72 + CGFloat(row) * 6, 5.5, 5.5, 1), rgb(colors[color])))
            }
            let piece = CALayer()
            piece.frame = full
            for (col, row) in [(2, 0), (3, 0), (4, 0), (3, 1)] {
                piece.addSublayer(fill(roundRect(76 + CGFloat(col) * 6, 72 + CGFloat(row) * 6, 5.5, 5.5, 1), rgb(0xFF5E8A)))
            }
            let fall = CAKeyframeAnimation(keyPath: "transform.translation.y")
            fall.values = [0, 6, 12, 18, 24, 30, 36, 36]
            fall.calculationMode = .discrete
            fall.duration = 3
            fall.repeatCount = .infinity
            piece.add(fall, forKey: "fall")
            parts.append(piece)
            return [prop(parts)]

        case .racing:
            // Дорога с бегущей разметкой, машинка Бита рулит, навстречу едет соперник.
            var parts: [CALayer] = [fill(polygon([CGPoint(x: 92, y: 68), CGPoint(x: 108, y: 68), CGPoint(x: 138, y: 132), CGPoint(x: 62, y: 132)]), rgb(0x2E3546))]
            parts.append(stroke(line(92, 68, 62, 132), rgb(0xFFFFFF, 0.5), 2))
            parts.append(stroke(line(108, 68, 138, 132), rgb(0xFFFFFF, 0.5), 2))
            let dashes = stroke(line(100, 68, 100, 132), rgb(0xFFFFFF, 0.8), 2)
            dashes.lineCap = .butt
            dashes.lineDashPattern = [6, 6]
            let run = CABasicAnimation(keyPath: "lineDashPhase")
            run.fromValue = 0
            run.toValue = -12
            run.duration = 0.3
            run.repeatCount = .infinity
            dashes.add(run, forKey: "run")
            parts.append(dashes)
            let rival = fill(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 8, height: 6), cornerWidth: 2, cornerHeight: 2, transform: nil), rgb(0xFFB547))
            rival.frame = CGRect(x: 100, y: 70, width: 8, height: 6)
            let come = CABasicAnimation(keyPath: "transform")
            come.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(0.5, 0.5, 1))
            come.toValue = NSValue(caTransform3D: CATransform3DScale(CATransform3DMakeTranslation(10, 58, 0), 1.8, 1.8, 1))
            come.duration = 1.8
            come.repeatCount = .infinity
            rival.add(come, forKey: "come")
            parts.append(rival)
            let car = CALayer()
            car.frame = full
            car.addSublayer(fill(roundRect(93, 112, 14, 11, 3), rgb(0xFF7A6B)))
            car.addSublayer(fill(roundRect(96, 114, 8, 4, 1.5), rgb(0x1B1F2A)))
            let steer = CABasicAnimation(keyPath: "transform.translation.x")
            steer.fromValue = -12
            steer.toValue = 12
            steer.duration = 0.9
            steer.autoreverses = true
            steer.repeatCount = .infinity
            steer.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            car.add(steer, forKey: "steer")
            parts.append(car)
            return [prop(parts)]

        case .boxing:
            // Боксирует на экране: собранный взгляд, перчатки бьют по очереди к центру.
            var parts: [CALayer] = [eye(82, 74, 9, 11), eye(109, 74, 9, 11),
                                    stroke(line(79, 70, 91, 73), c, 2.5), stroke(line(109, 73, 121, 70), c, 2.5)]
            for (x, side, delay) in [(60.0, 1.0, 0.0), (116.0, -1.0, 0.3)] {
                let glove = CALayer()
                glove.frame = CGRect(x: x, y: 96, width: 24, height: 26)
                let fist = fill(roundRect(0, 0, 24, 20, 10), rgb(0xFF7A6B))
                fist.strokeColor = rgb(0x1B1F2A)
                fist.lineWidth = 1.5
                glove.addSublayer(fist)
                glove.addSublayer(fill(ellipse(side > 0 ? 15 : 3, 6, 7, 9), rgb(0xE0655A)))
                glove.addSublayer(stroke(line(5, 5, 9, 3), rgb(0xFFFFFF, 0.5), 2))
                glove.addSublayer(fill(roundRect(4, 19, 16, 7, 3), c))
                let punch = CAKeyframeAnimation(keyPath: "transform")
                punch.values = [CATransform3DIdentity,
                                CATransform3DScale(CATransform3DMakeTranslation(CGFloat(10 * side), -6, 0), 1.35, 1.35, 1),
                                CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
                punch.keyTimes = [0, 0.3, 1]
                punch.duration = 0.6
                punch.repeatCount = .infinity
                punch.timeOffset = delay
                glove.add(punch, forKey: "punch")
                parts.append(glove)
            }
            return Array(parts[..<4]) + [prop(Array(parts[4...]))]

        case .workout:
            // Гантели: по одной в каждой ладошке у краёв экрана, поднимает по очереди.
            // Лицо посередине и свободно: глаза «> <», рот «о».
            let left = CGMutablePath()
            left.addLines(between: [CGPoint(x: 79, y: 86), CGPoint(x: 89, y: 92), CGPoint(x: 79, y: 98)])
            let right = CGMutablePath()
            right.addLines(between: [CGPoint(x: 121, y: 86), CGPoint(x: 111, y: 92), CGPoint(x: 121, y: 98)])
            var parts: [CALayer] = [stroke(left, c, 3.5), stroke(right, c, 3.5), stroke(ellipse(95, 108, 10, 9), c, 2.5)]
            var weights: [CALayer] = []
            for (x, delay) in [(68.0, 0.0), (132.0, 0.55)] {
                let dumbbell = CALayer()
                dumbbell.frame = full
                dumbbell.addSublayer(stroke(line(x, 100, x, 116), c, 2.5))           // гриф
                dumbbell.addSublayer(fill(roundRect(x - 7, 96, 14, 5, 2.5), c))     // диски
                dumbbell.addSublayer(fill(roundRect(x - 7, 115, 14, 5, 2.5), c))
                dumbbell.addSublayer(mitten(x - 6, 102))                            // ладошка держит гриф
                let curl = CAKeyframeAnimation(keyPath: "transform.translation.y")
                curl.values = [7, -10, 7]
                curl.keyTimes = [0, 0.45, 1]
                curl.duration = 1.1
                curl.repeatCount = .infinity
                curl.timeOffset = delay
                curl.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
                dumbbell.add(curl, forKey: "curl")
                weights.append(dumbbell)
            }
            parts.append(prop(weights))
            return parts

        case .dizzy:
            var parts: [CALayer] = []
            for cx in [82.0, 118.0] {
                parts.append(stroke(ellipse(cx - 8, 88, 16, 16), c, 3))
                parts.append(fill(ellipse(cx - 2.5, 93.5, 5, 5), c))
            }
            let mouth = CGMutablePath()
            mouth.move(to: CGPoint(x: 90, y: 119))
            mouth.addQuadCurve(to: CGPoint(x: 100, y: 119), control: CGPoint(x: 95, y: 114))
            mouth.addQuadCurve(to: CGPoint(x: 110, y: 119), control: CGPoint(x: 105, y: 124))
            parts.append(stroke(mouth, c, 3))
            return parts
        }
    }

    // MARK: - Таймер и часы на экране

    private func buildScreenText() {
        screenText.frame = Self.full
        screenText.opacity = 0
        // Рамка по краю экрана; прогресс идёт от середины верха по часовой стрелке.
        let r: CGFloat = 16
        let rect = CGRect(x: 59, y: 71, width: 82, height: 56)
        let frame = CGMutablePath()
        frame.move(to: CGPoint(x: rect.midX, y: rect.minY))
        frame.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: r)
        frame.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        frame.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        frame.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.midX, y: rect.minY), radius: r)
        frame.closeSubpath()
        for (l, alpha) in [(screenTrack, 0.18), (screenProgress, 1.0)] {
            l.frame = Self.full
            l.path = frame
            l.fillColor = nil
            l.lineWidth = 2.5
            l.lineCap = .round
            l.strokeColor = Self.rgb(0x5CF2E0, alpha)
            screenText.addSublayer(l)
        }
        for t in [screenBig, screenSmall] {
            t.alignmentMode = .center
            screenText.addSublayer(t)
        }
        screenBig.frame = CGRect(x: 56, y: 85, width: 88, height: 28)
        screenSmall.frame = CGRect(x: 56, y: 111, width: 88, height: 12)
    }

    /// Крупный текст на экране (таймер «24:59», часы «14:25»), подпись под ним и рамка-прогресс (nil — без рамки).
    func showScreenText(_ big: String, small: String?, progress: Double?, tint: UInt32 = 0x5CF2E0) {
        if let shown = screenShown, shown.big == big, shown.small == small, shown.progress == progress, shown.tint == tint { return }
        let wasHidden = screenShown == nil
        screenShown = (big, small, progress, tint)
        // Цифры меняются сразу (плавная смена оставляла след прежней цифры), рамка тает плавно.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size: CGFloat = big.count > 5 ? 17 : 22
        let bigFont = Self.rounded(NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold))
        screenBig.string = NSAttributedString(string: big, attributes: [.font: bigFont, .foregroundColor: NSColor(cgColor: Self.rgb(tint)) ?? .cyan])
        screenBig.frame = CGRect(x: 56, y: small == nil ? 89 : (size < 20 ? 89 : 85), width: 88, height: 28)
        screenSmall.string = small.map {
            NSAttributedString(string: $0, attributes: [.font: Self.rounded(NSFont.systemFont(ofSize: 8.5, weight: .medium)),
                                                       .foregroundColor: NSColor(cgColor: Self.rgb(tint, 0.6)) ?? .cyan])
        }
        screenTrack.isHidden = progress == nil
        screenProgress.isHidden = progress == nil
        screenProgress.strokeColor = Self.rgb(tint)
        screenTrack.strokeColor = Self.rgb(tint, 0.18)
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setDisableActions(wasHidden)
        CATransaction.setAnimationDuration(0.9)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        screenProgress.strokeEnd = CGFloat(progress ?? 0)
        CATransaction.commit()
        if wasHidden {
            screenText.removeAnimation(forKey: "hide")
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 0
            show.toValue = 1
            show.duration = 0.3
            show.beginTime = CACurrentMediaTime() + 0.15  // после того, как прежнее лицо растаяло
            show.fillMode = .backwards
            screenText.opacity = 1
            screenText.add(show, forKey: "show")
            updateContentsScale()
        }
    }

    func hideScreenText() {
        guard screenShown != nil else { return }
        screenShown = nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        screenText.opacity = 0
        CATransaction.commit()
    }

    // MARK: - Файл в руках

    private func buildHeld() {
        heldLayer.frame = Self.heldZone
        heldLayer.isHidden = true
        heldLayer.shadowColor = .black
        heldLayer.shadowOpacity = 0.3
        heldLayer.shadowRadius = 3
        heldLayer.shadowOffset = CGSize(width: 0, height: 2)
        heldIcon.frame = heldLayer.bounds.insetBy(dx: 3, dy: 3)
        heldIcon.contentsGravity = .resizeAspect
        heldLayer.addSublayer(heldIcon)
        heldBadge.frame = CGRect(x: 36, y: 0, width: 18, height: 18)
        heldBadge.path = CGPath(ellipseIn: heldBadge.bounds, transform: nil)
        heldBadge.fillColor = Self.rgb(0xFF7A6B)
        heldBadge.strokeColor = Self.rgb(0xFFFFFF)
        heldBadge.lineWidth = 1.5
        heldCount.frame = CGRect(x: 0, y: 2.5, width: 18, height: 14)
        heldCount.alignmentMode = .center
        heldBadge.addSublayer(heldCount)
        heldLayer.addSublayer(heldBadge)
        gesture.addSublayer(heldLayer)
    }

    /// Что Бит держит: значок файла (nil — ничего) и сколько их. Берёт пружинкой и чуть покачивает.
    func setHeld(_ icon: NSImage?, count: Int) {
        guard let icon else {
            guard heldShown else { return }
            heldShown = false
            let out = CABasicAnimation(keyPath: "transform.scale")
            out.fromValue = 1
            out.toValue = 0.2
            out.duration = 0.2
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.heldShown else { return }
                    self.heldLayer.isHidden = true
                }
            }
            heldLayer.add(out, forKey: "out")
            heldLayer.opacity = 0
            CATransaction.commit()
            return
        }
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        heldIcon.contents = icon.layerContents(forContentsScale: scale)
        heldBadge.isHidden = count <= 1
        heldCount.string = NSAttributedString(string: count > 99 ? "99+" : "\(count)", attributes: [
            .font: Self.rounded(NSFont.systemFont(ofSize: count > 9 ? 8 : 10, weight: .bold)), .foregroundColor: NSColor.white])
        heldCount.contentsScale = scale
        CATransaction.commit()
        guard !heldShown else { return }
        heldShown = true
        heldLayer.removeAllAnimations()
        heldLayer.isHidden = false
        heldLayer.opacity = 1
        heldLayer.setAffineTransform(CGAffineTransform(rotationAngle: -0.16))
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.2
        pop.toValue = 1
        pop.mass = 0.7
        pop.stiffness = 240
        pop.damping = 11
        pop.duration = pop.settlingDuration
        heldLayer.add(pop, forKey: "pop")
        let sway = CABasicAnimation(keyPath: "transform.rotation.z")
        sway.fromValue = -0.22
        sway.toValue = -0.1
        sway.duration = 1.6
        sway.autoreverses = true
        sway.repeatCount = .infinity
        sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        heldLayer.add(sway, forKey: "sway")
    }

    /// Файлы утаскивают: в руках пусто, пока перетаскивание не кончится.
    func setHeldLifted(_ lifted: Bool) {
        guard heldShown else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        heldLayer.opacity = lifted ? 0 : 1
        CATransaction.commit()
    }

    // MARK: - Нагрузка на экране

    private func buildStats() {
        statsLayer.frame = Self.full
        statsLayer.opacity = 0
        for i in 0..<3 {
            let y = 78 + CGFloat(i) * 15
            let label = CATextLayer()
            label.frame = CGRect(x: 63, y: y, width: 24, height: 11)
            label.alignmentMode = .left
            let track = CALayer()
            track.frame = CGRect(x: 88, y: y + 3.5, width: 26, height: 4)
            track.cornerRadius = 2
            track.backgroundColor = Self.rgb(0x5CF2E0, 0.18)
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0, y: 0.5)
            bar.frame = track.frame
            bar.cornerRadius = 2
            let value = CATextLayer()
            value.frame = CGRect(x: 114, y: y - 0.5, width: 24, height: 12)
            value.alignmentMode = .right
            for l in [label, track, bar, value] { statsLayer.addSublayer(l) }
            statsRows.append((label, track, bar, value))
        }
    }

    /// Три строки на экране: подпись, полоска и проценты. Больше 70 % — жёлтая, больше 90 % — красная.
    func showStats(_ rows: [(String, Double)]) {
        let wasHidden = !statsShown
        statsShown = true
        CATransaction.begin()
        CATransaction.setDisableActions(wasHidden)
        CATransaction.setAnimationDuration(0.5)
        let labelFont = Self.rounded(NSFont.systemFont(ofSize: 7.5, weight: .semibold))
        let valueFont = Self.rounded(NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold))
        for (row, item) in zip(statsRows, rows) {
            let fraction = min(max(item.1, 0), 1)
            let color: UInt32 = fraction >= 0.9 ? 0xFF6B6B : fraction >= 0.7 ? 0xFFB547 : 0x5CF2E0
            row.label.string = NSAttributedString(string: item.0, attributes: [.font: labelFont,
                                                                               .foregroundColor: NSColor(cgColor: Self.rgb(0x5CF2E0, 0.7)) ?? .cyan])
            row.value.string = NSAttributedString(string: "\(Int((fraction * 100).rounded()))%",
                                                  attributes: [.font: valueFont, .foregroundColor: NSColor(cgColor: Self.rgb(color)) ?? .cyan])
            row.bar.backgroundColor = Self.rgb(color)
            row.bar.bounds.size.width = max(2, row.track.frame.width * fraction)
        }
        CATransaction.commit()
        if wasHidden {
            screenIcon.opacity = 0  // значок в правом верхнем углу налез бы на верхнюю строку
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.3)
            statsLayer.opacity = 1
            CATransaction.commit()
            updateContentsScale()
        }
    }

    func hideStats() {
        guard statsShown else { return }
        statsShown = false
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        statsLayer.opacity = 0
        screenIcon.opacity = 1
        CATransaction.commit()
    }

    // MARK: - Кофе-режим

    /// Кружка у левого края экрана на уровне глаз (ниже — полоска «работает»), над ней вьётся пар.
    private func buildCoffee() {
        coffeeLayer.frame = Self.full
        coffeeLayer.isHidden = true
        let c = Self.faceColor
        coffeeLayer.addSublayer(Self.fill(Self.roundRect(58, 95, 10, 10, 2.5), c))
        let handle = CGMutablePath()
        handle.move(to: CGPoint(x: 68, y: 97.5))
        handle.addQuadCurve(to: CGPoint(x: 68, y: 102.5), control: CGPoint(x: 72.5, y: 100))
        coffeeLayer.addSublayer(Self.stroke(handle, c, 1.6))
        for (i, x) in [60.5, 65.0].enumerated() {
            let steam = CGMutablePath()
            steam.move(to: CGPoint(x: x, y: 92))
            steam.addQuadCurve(to: CGPoint(x: x, y: 87.5), control: CGPoint(x: x + 2.5, y: 89.5))
            steam.addQuadCurve(to: CGPoint(x: x, y: 83.5), control: CGPoint(x: x - 2.5, y: 85.5))
            let wisp = Self.stroke(steam, Self.rgb(0x5CF2E0, 0.7), 1.2)
            let rise = CAKeyframeAnimation(keyPath: "opacity")
            rise.values = [0, 1, 0]
            rise.keyTimes = [0, 0.4, 1]
            let up = CABasicAnimation(keyPath: "transform.translation.y")
            up.fromValue = 2
            up.toValue = -3
            let group = CAAnimationGroup()
            group.animations = [rise, up]
            group.duration = 1.8
            group.repeatCount = .infinity
            group.timeOffset = Double(i) * 0.9
            wisp.add(group, forKey: "steam")
            coffeeLayer.addSublayer(wisp)
        }
    }

    func setCoffee(_ on: Bool) {
        coffeeOn = on
        updateCoffee(model.state)
    }

    /// Кружку не показываем во сне и когда экран занят целиком (меню, таймер, часы, занятия, запись).
    private func updateCoffee(_ state: PetState) {
        let busy: Set<PetState> = [.sleep, .menu, .timer, .clock, .reading, .tetris, .racing, .boxing, .workout, .note]
        let hidden = !coffeeOn || busy.contains(state)
        guard coffeeLayer.isHidden != hidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        coffeeLayer.isHidden = hidden
        CATransaction.commit()
        if !hidden {
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 0
            show.toValue = 1
            show.duration = 0.3
            coffeeLayer.add(show, forKey: "show")
            updateContentsScale()
        }
    }

    // MARK: - Меню на экране

    /// Меню открыто: строчка на каждый пункт, выезжают в такт карточке меню.
    /// length — длина подписи (строчка длиннее), toggle — переключатель (справа «таблетка»).
    func showMenuMirror(_ rows: [(length: Int, toggle: Bool?)]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        menuMirror.removeAllAnimations()
        menuMirror.sublayers?.forEach { $0.removeFromSuperlayer() }
        menuMirror.opacity = 1
        mirrorLines = []
        mirrorPills = [:]
        let step = min(6, 34 / CGFloat(max(rows.count, 1)))
        let top = 94 + (34 - step * CGFloat(rows.count)) / 2
        let now = CACurrentMediaTime()
        for (i, row) in rows.enumerated() {
            let y = top + step * (CGFloat(i) + 0.5)
            let line = CALayer()
            line.anchorPoint = CGPoint(x: 0, y: 0.5)
            line.bounds = CGRect(x: 0, y: 0, width: min(38, 12 + CGFloat(row.length) * 1.6), height: 2.4)
            line.position = CGPoint(x: 78, y: y)
            line.cornerRadius = 1.2
            line.backgroundColor = Self.rgb(0x5CF2E0, 0.35)
            let grow = CABasicAnimation(keyPath: "transform.scale.x")
            grow.fromValue = 0
            grow.toValue = 1
            grow.duration = 0.22
            grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            grow.beginTime = now + QuickMenu.rowDelay(i)
            grow.fillMode = .backwards
            line.add(grow, forKey: "grow")
            menuMirror.addSublayer(line)
            mirrorLines.append(line)
            if let on = row.toggle {
                let pill = CALayer()
                pill.frame = CGRect(x: 119, y: y - 2.2, width: 9, height: 4.4)
                pill.cornerRadius = 2.2
                pill.borderColor = Self.rgb(0x5CF2E0, 0.5)
                pill.borderWidth = 0.6
                pill.backgroundColor = on ? Self.faceColor : nil
                let show = CABasicAnimation(keyPath: "opacity")
                show.fromValue = 0
                show.toValue = 1
                show.duration = 0.2
                show.beginTime = now + QuickMenu.rowDelay(i) + 0.1
                show.fillMode = .backwards
                pill.add(show, forKey: "show")
                menuMirror.addSublayer(pill)
                mirrorPills[i] = pill
            }
        }
        // Курсор-стрелочка у подсвеченной строчки.
        let chevron = CGMutablePath()
        chevron.move(to: CGPoint(x: -2, y: -2.5))
        chevron.addLine(to: CGPoint(x: 1.5, y: 0))
        chevron.addLine(to: CGPoint(x: -2, y: 2.5))
        mirrorCursor.path = chevron
        mirrorCursor.fillColor = nil
        mirrorCursor.strokeColor = Self.faceColor
        mirrorCursor.lineWidth = 1.6
        mirrorCursor.lineCap = .round
        mirrorCursor.lineJoin = .round
        mirrorCursor.opacity = 0
        mirrorCursor.position = CGPoint(x: 71, y: top)
        menuMirror.addSublayer(mirrorCursor)
        CATransaction.commit()
        updateContentsScale()
    }

    /// Курсор над пунктом меню — та же строчка на экране светится, к ней едет стрелочка.
    func highlightMenuMirror(_ index: Int?) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        for (i, line) in mirrorLines.enumerated() {
            let on = i == index
            line.backgroundColor = on ? Self.faceColor : Self.rgb(0x5CF2E0, 0.35)
            line.bounds.size.height = on ? 3.2 : 2.4
        }
        if let index, mirrorLines.indices.contains(index) {
            if mirrorCursor.opacity == 0 {
                CATransaction.setDisableActions(true)
                mirrorCursor.position = CGPoint(x: 71, y: mirrorLines[index].position.y)
                CATransaction.setDisableActions(false)
            }
            mirrorCursor.position = CGPoint(x: 71, y: mirrorLines[index].position.y)
            mirrorCursor.opacity = 1
        } else {
            mirrorCursor.opacity = 0
        }
        CATransaction.commit()
    }

    func setMenuMirrorToggle(_ index: Int, _ on: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        mirrorPills[index]?.backgroundColor = on ? Self.faceColor : nil
        CATransaction.commit()
    }

    /// Меню закрылось — строчки тают вместе с карточкой.
    func hideMenuMirror() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.menuMirror.opacity == 0 else { return }
            self.menuMirror.sublayers?.forEach { $0.removeFromSuperlayer() }
        }
        menuMirror.opacity = 0
        CATransaction.commit()
        mirrorLines = []
        mirrorPills = [:]
    }

    // MARK: - Помощники

    /// Глаз-«таблетка», моргает раз в 4,6 с.
    private static func eye(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.frame = CGRect(x: x, y: y, width: w, height: h)
        l.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: w / 2, cornerHeight: w / 2, transform: nil)
        l.fillColor = faceColor
        let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
        blink.values = [1, 1, 0.1, 1, 1]
        blink.keyTimes = [0, 0.91, 0.94, 0.97, 1]
        blink.duration = 4.6
        blink.repeatCount = .infinity
        l.add(blink, forKey: "blink")
        return l
    }

    /// Сонный глаз: веко мягко выгнуто вверх, низ круглый. Раз в 3,6 с веко опускается и держится — «клюёт носом».
    private static func sleepyEye(_ x: CGFloat, _ y: CGFloat) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.anchorPoint = CGPoint(x: 0.5, y: 1)  // веко опускается сверху вниз
        l.bounds = CGRect(x: 0, y: 0, width: 16, height: 10)
        l.position = CGPoint(x: x + 8, y: y + 10)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: 3))
        p.addQuadCurve(to: CGPoint(x: 16, y: 3), control: CGPoint(x: 8, y: -1))
        p.addQuadCurve(to: CGPoint(x: 0, y: 3), control: CGPoint(x: 8, y: 17))
        l.path = p
        l.fillColor = faceColor
        let nod = CAKeyframeAnimation(keyPath: "transform.scale.y")
        nod.values = [1, 1, 0.15, 0.15, 1]
        nod.keyTimes = [0, 0.5, 0.65, 0.85, 1]
        nod.duration = 3.6
        nod.repeatCount = .infinity
        l.add(nod, forKey: "nod")
        return l
    }

    private static func loop(_ keyPath: String, _ from: Any, _ to: Any, _ half: CFTimeInterval) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.duration = half
        a.beginTime = CACurrentMediaTime() + settle  // после того, как тело вернулось в покой
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.isRemovedOnCompletion = false
        return a
    }

    private static func rounded(_ font: NSFont) -> NSFont {
        NSFont(descriptor: font.fontDescriptor.withDesign(.rounded) ?? font.fontDescriptor, size: font.pointSize) ?? font
    }

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    private static func roundRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
    }

    private static func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x1, y: y1))
        p.addLine(to: CGPoint(x: x2, y: y2))
        return p
    }

    private static func ellipse(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: x, y: y, width: w, height: h), transform: nil)
    }

    /// Дуга «^» (control выше концов) или «закрытый глаз» (ниже) — квадратичная кривая, как в SVG.
    private static func arc(_ x1: CGFloat, _ y: CGFloat, _ x2: CGFloat, controlY: CGFloat) -> CGMutablePath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x1, y: y))
        p.addQuadCurve(to: CGPoint(x: x2, y: y), control: CGPoint(x: (x1 + x2) / 2, y: controlY))
        return p
    }

    private static func fill(_ path: CGPath, _ color: CGColor) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.frame = full
        l.path = path
        l.fillColor = color
        return l
    }

    private static func stroke(_ path: CGPath, _ color: CGColor, _ width: CGFloat) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.frame = full
        l.path = path
        l.fillColor = nil
        l.strokeColor = color
        l.lineWidth = width
        l.lineCap = .round
        l.lineJoin = .round
        return l
    }
}

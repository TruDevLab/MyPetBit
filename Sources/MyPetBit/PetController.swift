import AppKit
import EventKit

/// Окно без рамки поверх остальных; фокус не забирает.
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PetController: NSObject, NSMenuDelegate {
    static let size: CGFloat = 150

    let model = PetModel()
    private let panel: PetPanel
    private var view: BitLayerView!
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var ticks = 0

    /// Через сколько секунд простоя засыпать; 0 — не засыпать.
    private var sleepAfter: TimeInterval {
        didSet { defaults.set(sleepAfter, forKey: "sleepAfter") }
    }
    /// Состояние, выбранное в меню «Состояние (демо)»; nil — живёт сам.
    private var forcedState: PetState?
    /// Значок для проверки (-forcedBadge offline); в меню не выбирается.
    private var forcedBadge: PetBadge?

    private let monitor = SystemMonitor()
    private let events = EventWatcher()
    private let character = PetCharacter()
    /// Аксессуары для проверки (-forcedAccessories bow,mug); в меню не выбираются.
    private var forcedAccessories: Set<Accessory>?
    /// На что реагировать; ключи — из watchTitles.
    private var watched: Set<String> {
        didSet { defaults.set(Array(watched), forKey: "watched") }
    }
    private static let watchTitles = [
        ("battery", L("Батарея и зарядка")), ("cpu", L("Нагрузка CPU")), ("network", L("Сеть")), ("vpn", "VPN"),
        ("disk", L("Место на диске")), ("call", L("Звонок: камера и микрофон")), ("lock", L("Блокировка и пробуждение")),
        ("thermal", L("Перегрев")), ("memory", L("Нехватка памяти")), ("lowPower", L("Энергосбережение")),
        ("download", L("Большая загрузка по сети")), ("headphones", L("Наушники")), ("music", L("Музыка")),
        ("time", L("Время суток и выходные")), ("breaks", L("Долгая работа без перерыва")), ("clipboard", L("Копирование")),
        ("cursor", L("Рывки и встряхивание курсора")), ("windows", L("Окна рядом")),
        ("hobby", L("Сам себя развлекает")), ("talk", L("Фразы: приветствия, перерывы, новости")),
        ("claude", L("ИИ-агенты: Claude, Cursor, OpenCode, Ollama, Codex, Kimi")), ("commands", L("Долгие команды в терминале")),
        ("water", L("Напоминать попить воды — раз в час")), ("eyes", L("Правило 20-20-20 для глаз")),
        ("summary", L("Итог дня вечером")),
        ("screenshots", L("Скриншоты (системные и CleanShot)")),
        ("downloads", L("Загрузки файлов — доступ к папке")), ("meetings", L("Встречи из Календаря — доступ к календарю")),
        ("character", L("Характер: микродействия и привычки")),
        ("typing", L("Темп набора — Универсальный доступ"))
    ]
    /// Требуют разрешения macOS — выключены, пока пользователь не включит сам.
    private static let optIn: Set<String> = ["downloads", "typing", "meetings"]
    /// Без разрешений, но слишком часто для всех: выключено, пока не включат.
    private static let offByDefault: Set<String> = ["eyes"]

    private var reaction: (state: PetState, until: Date)?
    private var transient: (badge: PetBadge, until: Date)?
    private var wasAsleep = false
    /// VPN был поднят и пропал. Сбрасывается, когда VPN вернулся.
    private var vpnLost = false

    /// Отдача трекпада Force Touch. Мышь её не передаёт; системная настройка отдачи тоже учитывается.
    private var hapticsOn: Bool {
        didSet { defaults.set(hapticsOn, forKey: "haptics") }
    }

    // Перетаскивание и бросок.
    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero
    private var dragging = false
    private var lastDragDX: CGFloat = 0
    private var reversals: [Date] = []
    private var lastReversalHaptic = Date.distantPast
    private var snapped = false
    private var dragSamples: [(time: Date, point: NSPoint)] = []
    private var throwVelocity: CGVector?
    private var throwPeak: CGFloat = 0
    private var throwTimer: Timer?

    // Взгляд.
    private var lastMouse = NSPoint.zero
    private var mouseStillSince = Date()
    private var glance = CGPoint.zero
    private var nextGlance = Date()

    // Курсор: рывок к Биту и встряхивание.
    private var previousMouse = NSPoint.zero
    private var cursorReversals: [Date] = []
    private var lastCursorDX: CGFloat = 0
    private var lastCursorReaction = Date.distantPast

    // Поглаживание: курсор водят туда-сюда над Битом.
    private var cursorOverBit = false
    private var petting = false
    private var petReversals: [Date] = []
    private var lastPetDX: CGFloat = 0
    private var lastPetMouse = NSPoint.zero
    private var lastPetMove = Date.distantPast
    private var purrTick = 0
    /// Гладят спящего — сон держится, пока не нажали клавишу или курсор не ушёл.
    private var sleepHold = false
    private var lastHeartbeat = Date.distantPast

    // Время суток.
    private var lastEveningYawn = Date()

    // Окна: прошлые рамки, чтобы заметить окно, которое двигают на Бита.
    private var windowFrames: [Int: CGRect] = [:]

    override init() {
        let saved = UserDefaults.standard.object(forKey: "sleepAfter") as? Double
        sleepAfter = saved ?? 300
        // Для проверки: open MyPetBit.app --args -forcedState sleep (аргумент не сохраняется).
        forcedState = UserDefaults.standard.string(forKey: "forcedState").flatMap(PetState.init(rawValue:))
        forcedBadge = UserDefaults.standard.string(forKey: "forcedBadge").flatMap(PetBadge.init(rawValue:))
        let all = Set(Self.watchTitles.map(\.0))
        let savedWatch = UserDefaults.standard.stringArray(forKey: "watched").map(Set.init)
        // Новые реакции из обновлений включаются сами, кроме требующих разрешений.
        let known = UserDefaults.standard.stringArray(forKey: "watchKnown").map(Set.init) ?? []
        let fresh = all.subtracting(Self.optIn).subtracting(Self.offByDefault)
        watched = savedWatch.map { $0.union(fresh.subtracting(known)) } ?? fresh
        // didSet в init не срабатывает: без явной записи новые пункты пропали бы при следующем запуске.
        UserDefaults.standard.set(Array(watched), forKey: "watched")
        UserDefaults.standard.set(Array(all), forKey: "watchKnown")
        hapticsOn = UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true
        forcedAccessories = UserDefaults.standard.string(forKey: "forcedAccessories")
            .map { Set($0.split(separator: ",").compactMap { Accessory(rawValue: String($0)) }.prefix(1)) }

        panel = PetPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        // Без .fullScreenAuxiliary: в полноэкранных приложениях питомца не видно.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        super.init()

        let view = BitLayerView(model: model, size: Self.size)
        view.controller = self
        self.view = view
        panel.contentView = view
        panel.setFrameOrigin(restoredOrigin())
    }

    func show() {
        panel.orderFrontRegardless()
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        monitor.onChange = { [weak self] old, new in self?.systemChanged(from: old, to: new) }
        monitor.start()
        music.onChange = { [weak self] old, new in self?.musicChanged(from: old, to: new) }
        updates.onAvailable = { [weak self] state in
            MainActor.assumeIsolated { self?.announceUpdate(state) }
        }
        updates.onChange = { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSettings() }
        }
        if Bundle.main.bundlePath.hasSuffix(".app") { updates.start() }
        // Бита переложили или переименовали — подключённые хуки ведут в никуда: чиним сами и говорим об этом.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, Bundle.main.bundlePath.hasSuffix(".app") else { return }
                let fixed = self.integrations.repairBroken()
                guard !fixed.isEmpty else { return }
                self.speaker.say(Speech(text: L("Починил хуки"), detail: fixed.map(\.title).joined(separator: ", "), kind: .notice, seconds: 6))
            }
        }
        // Что держал до перезапуска — держит и сейчас, если файлы на месте.
        setHeld((defaults.stringArray(forKey: "heldFiles") ?? []).map { URL(fileURLWithPath: $0) }, save: false)
        events.onEvent = { [weak self] event in self?.handle(event) }
        character.onEvent = { [weak self] event in self?.handleCharacter(event) }
        events.start()

        speaker.anchor = { [unowned self] in self.panel.frame }
        speaker.isAway = { [unowned self] in self.idleSeconds() > 30 }
        speaker.onChange = { [unowned self] speech in
            self.view.setAntennaAlert(speech.map { $0.kind != .chat } ?? false)
        }
        speaker.onSpeak = { [unowned self] speech in
            self.react(.talk, for: min(2.6, 1 + Double(speech.text.count) * 0.04))
            self.updateState()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.speaker.follow() }
        }
        quickMenu.onHover = { [weak self] index in
            self?.view.highlightMenuMirror(index)
            if index != nil { self?.haptic(.alignment) }
        }
        quickMenu.onToggle = { [weak self] index, on in self?.view.setMenuMirrorToggle(index, on) }
        quickMenu.onClose = { [weak self] in
            guard let self else { return }
            self.menuOpen = false
            self.view.hideMenuMirror()
            self.speaker.resume()
            self.updateState()
        }
        commands.onFinished = { [weak self] job in self?.commandFinished(job) }
        meetings.onReminder = { [weak self] reminder in self?.remind(reminder) }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Notices.say, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo as? [String: String] ?? [:]
            MainActor.assumeIsolated { self?.heard(info) }
        }
        distributed.addObserver(forName: Notices.agent, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo as? [String: String] ?? [:]
            MainActor.assumeIsolated { self?.agentHook(info) }
        }
        ollama.onChange = { [weak self] busy, app, tty in
            var info = ["agent": "ollama", "kind": busy ? "start" : "stop", "session": "local"]
            info["app"] = app.map { String($0) }
            info["tty"] = tty
            self?.agentHook(info)
        }
        distributed.addObserver(forName: Notices.command, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo as? [String: String] ?? [:]
            MainActor.assumeIsolated { self?.commandHook(info) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.appActivated(pid) }
        }
        commands.minimum = commandMinimum
        configureEvents()

        // Первый запуск — знакомство (кроме проверочных запусков с -demoEvent и -snapshot).
        if !defaults.bool(forKey: "onboarded") && defaults.string(forKey: "demoEvent") == nil && defaults.string(forKey: "snapshot") == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                MainActor.assumeIsolated { self?.startOnboarding() }
            }
        }

        // Для проверки переходов: -demoEvent clipboard|screenshot|unlocked|didWake|downloadFinished|reading|tetris|…
        // через 3 секунды после запуска.
        // Для README: -snapshot <файл.png> [-snapshotDelay 4] — снимок своих окон без рабочего стола пользователя.
        if let path = defaults.string(forKey: "snapshot") {
            let delay = defaults.object(forKey: "snapshotDelay") == nil ? 4 : defaults.double(forKey: "snapshotDelay")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { Self.snapshot(to: path) }
            }
        }
        if let demo = defaults.string(forKey: "demoEvent") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { self?.runDemo(demo) }
            }
        }
    }

    /// Рисует видимые окна Бита (сам Бит, облачко, меню, антенна) на тёмном фоне в тон его экрану и пишет PNG.
    private static func snapshot(to path: String) {
        let windows = NSApp.windows.filter { ($0 is PetPanel || $0 is BubblePanel || $0 is TimerCardPanel || $0 is SettingsPanel) && $0.isVisible && $0.contentView?.layer != nil }
        guard let first = windows.first else { return }
        let pad: CGFloat = 28
        let scale: CGFloat = 2
        let union = windows.map(\.frame).reduce(first.frame) { $0.union($1) }.insetBy(dx: -pad, dy: -pad)
        let width = Int(union.width * scale), height = Int(union.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let colors = [CGColor(srgbRed: 0.16, green: 0.20, blue: 0.33, alpha: 1), CGColor(srgbRed: 0.07, green: 0.08, blue: 0.13, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: CGFloat(width) * 0.35, y: CGFloat(height) * 0.75), startRadius: 0,
                                   endCenter: CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2),
                                   endRadius: CGFloat(max(width, height)), options: [.drawsAfterEndLocation])
        }
        // Нижние окна — первыми: антенна за Битом, облачко и меню поверх.
        for window in windows.sorted(by: { $0.orderedIndex > $1.orderedIndex }) {
            guard let layer = window.contentView?.layer else { continue }
            ctx.saveGState()
            ctx.translateBy(x: (window.frame.minX - union.minX) * scale, y: (window.frame.minY - union.minY) * scale)
            ctx.scaleBy(x: scale, y: scale)
            // Окно SwiftUI (карточка таймера) рисуется в перевёрнутых координатах.
            if layer.isGeometryFlipped || window.contentView?.isFlipped == true {
                ctx.translateBy(x: 0, y: window.frame.height)
                ctx.scaleBy(x: 1, y: -1)
            }
            layer.render(in: ctx)
            ctx.restoreGState()
        }
        guard let image = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private func runDemo(_ name: String) {
        let events: [String: PetEvent] = ["clipboard": .clipboard, "screenshot": .screenshot, "unlocked": .unlocked,
                                          "didWake": .didWake, "downloadFinished": .downloadFinished]
        if let event = events[name] {
            handle(event, force: true)
        } else if name == "interrupt", let job = commands.running.first {
            // Переспрос в облачке, через 3 секунды — прервать, как если бы нажали кнопку.
            askInterrupt(job)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { self?.commands.interrupt(job.pid) }
            }
        } else if name == "antenna" {
            demoAntennaPull()
        } else if name == "onboarding" {
            startOnboarding()
        } else if name == "onboardingCard" {
            onboardingHome = panel.frame.origin
            showOnboardingCard()
            let page = defaults.integer(forKey: "onboardingPage")
            if page > 0 { onboarding?.model.go(page) }
            // -onboardingFinish YES: через 2 секунды — как «Начать!» (проверка перелёта домой)
            if defaults.bool(forKey: "onboardingFinish") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    MainActor.assumeIsolated { self?.finishOnboarding() }
                }
            }
        } else if name == "hide" {
            // Улетает, через 3 секунды прилетает (как «Показать Бита»).
            hideBit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { self?.showBit() }
            }
        } else if name == "settings" {
            // -settingsSection N — сразу нужный раздел (для снимков).
            showSettings(section: defaults.integer(forKey: "settingsSection"))
        } else if name == "hold" {
            // -holdPaths "a|b" — поймать файлы; -heldAction zip — через 2 с выполнить действие; -heldMenu YES — открыть меню.
            catchFiles((defaults.string(forKey: "holdPaths") ?? "").split(separator: "|").map { URL(fileURLWithPath: String($0)) })
            // -heldAction zip|unzip или convert:<вариант> (format-docx, videoHEVC, …); -convertMenu YES — карточка форматов.
            if let raw = defaults.string(forKey: "heldAction") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if let action = FileShelf.Action(rawValue: raw) {
                            self.runHeld(action)
                        } else if raw.hasPrefix("convert:"),
                                  let option = Converters.options(for: self.held, available: ConvertTools.available)
                                    .first(where: { $0.id == raw.dropFirst(8) }) {
                            self.runConvert(option)
                        }
                    }
                }
            }
            if defaults.bool(forKey: "convertMenu") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    MainActor.assumeIsolated { self?.showConvertMenu() }
                }
            }
            if defaults.bool(forKey: "heldMenu") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    MainActor.assumeIsolated { self?.showQuickMenu() }
                }
            }
        } else if name == "music" {
            // -musicDemo next|previous|toggle — команда плееру (меняет музыку!); без него — только значок на экране.
            if let raw = defaults.string(forKey: "musicDemo"), let command = ["next": MusicControl.Command.next,
                                                                            "previous": .previous, "toggle": .toggle][raw] {
                musicCommand(command)
            } else {
                musicFlash = ("▶▶", Date().addingTimeInterval(6))
                updateState()
            }
        } else if name == "updateCheck" {
            // Проверка обновлений сейчас; итог — строкой в настройки updateDump через 8 с.
            updates.check(manual: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.defaults.set("\(self.updates.state) adHoc=\(CodeSignatureCheck.selfIsAdHoc)", forKey: "updateDump")
                }
            }
        } else if name == "menuDump" {
            // Структура меню строки меню текстом — в настройки menuDump (проверка без щелчков).
            let menu = NSMenu()
            fill(menu)
            func dump(_ menu: NSMenu, _ depth: Int) -> [String] {
                menu.items.flatMap { it -> [String] in
                    let mark = it.state == .on ? " ✓" : ""
                    let line = it.isSeparatorItem ? "—" : (it.isSectionHeader ? "[\(it.title)]" : it.title + mark)
                    return [String(repeating: "    ", count: depth) + line] + (depth < 1 ? it.submenu.map { dump($0, depth + 1) } ?? [] : [])
                }
            }
            defaults.set(dump(menu, 0).joined(separator: "\n"), forKey: "menuDump")
        } else if name == "desktopTidy" {
            tidyDesktop()
        } else if name == "desktopDiagnose" {
            DesktopTidy.diagnose { [weak self] text in self?.defaults.set(text, forKey: "desktopDebug") }
        } else if name == "quiet" {
            setQuiet(true)
        } else if name == "menu" {
            showQuickMenu()
            view.highlightMenuMirror(1)  // как будто курсор над вторым пунктом
        } else if let line = Self.debugLines.first(where: { $0.0 == name }) {
            sayDebug(line.0)
        } else if let hobby = PetState(rawValue: name), Self.hobbies.contains(hobby) {
            startActivity(hobby, seconds: 6)
        }
    }

    /// askTyping — «Темп набора» только что включили руками: можно показать окно «Универсального доступа».
    private func configureEvents(askTyping: Bool = false) {
        events.configure(screenshots: watching("screenshots"), downloads: watching("downloads"), typing: watching("typing"),
                         askTyping: askTyping)
        if watching("commands") { commands.start() } else { commands.stop() }
        if watching("claude") { ollama.start() } else { ollama.stop() }
        if watching("meetings") { meetings.start() } else { meetings.stop() }
        if watching("music") { music.start() } else { music.stop() }
    }

    // MARK: - Положение

    private func defaultOrigin() -> NSPoint {
        let frame = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: frame.maxX - Self.size - 24, y: frame.minY + 8)
    }

    private func isOnScreen(_ origin: NSPoint) -> Bool {
        let rect = NSRect(origin: origin, size: NSSize(width: Self.size, height: Self.size))
        return NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
    }

    private func restoredOrigin() -> NSPoint {
        guard let x = defaults.object(forKey: "originX") as? Double,
              let y = defaults.object(forKey: "originY") as? Double else { return defaultOrigin() }
        // Монитор могли отключить: возвращаем в угол, если окно не попадает ни на один экран.
        return isOnScreen(NSPoint(x: x, y: y)) ? NSPoint(x: x, y: y) : defaultOrigin()
    }

    private func savePosition() {
        defaults.set(Double(panel.frame.minX), forKey: "originX")
        defaults.set(Double(panel.frame.minY), forKey: "originY")
    }

    /// Прозрачное поле слева и справа от силуэта.
    private static var side: CGFloat { size * 30 / 200 }

    /// Силуэт Бита в экранных координатах (без тени и прозрачных полей).
    private func silhouette() -> NSRect {
        let f = panel.frame
        return NSRect(x: f.minX + Self.side, y: f.minY + Self.size * 30 / 200,
                      width: Self.size - 2 * Self.side, height: Self.size * 150 / 200)
    }

    private func screenFrame(at point: NSPoint) -> NSRect {
        (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    }

    // MARK: - Мышь

    func mouseDown(_ event: NSEvent) {
        // Нажали на антенну — её тянут, а не Бита.
        if onAntenna(NSEvent.mouseLocation) {
            beginAntennaPull(at: NSEvent.mouseLocation.y)
            return
        }
        stopThrow()
        dragFromHeld = !held.isEmpty && BitLayerView.heldZone.contains(canvasPoint(NSEvent.mouseLocation))
        // Нажали и держат на месте 0,6 с — пауза или игра.
        longPressFired = false
        longPress?.invalidate()
        if music.track != nil {
            let t = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.dragging, self.antennaPull == nil else { return }
                    self.longPressFired = true
                    self.musicCommand(.toggle)
                }
            }
            RunLoop.main.add(t, forMode: .common)
            longPress = t
        }
        if activity != nil {
            activity = nil  // отвлекли — бросает занятие
            nextActivity = Date().addingTimeInterval(8 * 60)
        }
        lastInteraction = Date()
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = panel.frame.origin
        dragging = false
        reversals = []
        lastDragDX = 0
        dragSamples = []
    }

    func mouseDragged(_ event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        if let pull = antennaPull {
            moveAntennaPull(mouse.y - pull.startY)
            return
        }
        let dx = mouse.x - dragStartMouse.x
        let dy = mouse.y - dragStartMouse.y
        if !dragging && hypot(dx, dy) < 3 { return }
        longPress?.invalidate()  // потянули — это уже не долгое нажатие
        if longPressFired { return }
        if dragFromHeld && !dragging {
            // Тянут за файл — отдаёт файлы, сам остаётся на месте.
            dragFromHeld = false
            beginHeldDrag(event)
            return
        }
        if !dragging { haptic(.alignment) }  // подхватили
        dragging = true
        panel.setFrameOrigin(snappedOrigin(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy)))

        let now = Date()
        dragSamples.append((now, mouse))
        dragSamples.removeAll { $0.time < now.addingTimeInterval(-0.1) }

        // Тряска: частая смена направления по горизонтали, на каждую — щелчок трекпада.
        if abs(event.deltaX) > 2 {
            if lastDragDX != 0 && (event.deltaX > 0) != (lastDragDX > 0) {
                reversals.append(now)
                if now.timeIntervalSince(lastReversalHaptic) > 0.08 {
                    haptic(.alignment)
                    lastReversalHaptic = now
                }
            }
            lastDragDX = event.deltaX
        }
        reversals.removeAll { $0 < now.addingTimeInterval(-1.2) }
        updateState()
    }

    func mouseUp(_ event: NSEvent) {
        longPress?.invalidate()
        if longPressFired {
            longPressFired = false
            dragging = false
            return
        }
        if antennaPull != nil {
            endAntennaPull()
            return
        }
        if dragging {
            dragging = false
            snapped = false
            let shaken = reversals.count >= 4
            reversals = []
            // Скорость последних 0,1 с: быстро отпустили — бросок.
            if !shaken, let first = dragSamples.first, let last = dragSamples.last,
               last.time.timeIntervalSince(first.time) > 0.02 {
                let dt = last.time.timeIntervalSince(first.time)
                let v = CGVector(dx: (last.point.x - first.point.x) / dt, dy: (last.point.y - first.point.y) / dt)
                if hypot(v.dx, v.dy) > 900 {
                    startThrow(v)
                    return
                }
            }
            savePosition()
            if shaken {
                react(.dizzy, for: 2.5)
                hapticBurst(3)
            } else {
                haptic(.levelChange)  // поставили
            }
        } else if event.clickCount >= 2 {
            // «Дай пять»: двойной толчок.
            react(.happy, for: 1.4)
            showTransient(.highFive, for: 1.5)
            character.interact(.highFive)
            haptic(.levelChange)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.haptic(.levelChange) }
            }
        } else if model.state == .clock {
            statsUntil = Date().addingTimeInterval(5)  // щелчок по часам — нагрузка
            haptic(.generic)
        } else {
            react(.happy, for: 1.4)
            haptic(.generic)
            character.interact(.click)
            // Иногда отвечает на щелчок словами.
            if Date().timeIntervalSince(lastClickChat) > 20 && Bool.random() {
                lastClickChat = Date()
                chat(Self.clickLines.randomElement()!, ignoreCooldown: true)
            }
        }
        updateState()
    }

    /// Прилипание к низу и бокам экрана со щелчком трекпада. Бока — по силуэту, а не по краю окна.
    private func snappedOrigin(_ origin: NSPoint) -> NSPoint {
        let frame = screenFrame(at: NSEvent.mouseLocation)
        let zone: CGFloat = 12
        var o = origin
        var hit = false
        if abs(o.y - frame.minY) < zone { o.y = frame.minY; hit = true }
        if abs(o.x + Self.side - frame.minX) < zone { o.x = frame.minX - Self.side; hit = true }
        if abs(o.x + Self.size - Self.side - frame.maxX) < zone { o.x = frame.maxX - Self.size + Self.side; hit = true }
        if hit && !snapped { haptic(.alignment) }
        snapped = hit
        return o
    }

    // MARK: - Бросок: инерция, трение, отскок от краёв

    private func startThrow(_ velocity: CGVector) {
        throwVelocity = velocity
        throwPeak = hypot(velocity.dx, velocity.dy)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.throwStep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        throwTimer = timer
        updateState()
    }

    private func stopThrow() {
        throwTimer?.invalidate()
        throwTimer = nil
        throwVelocity = nil
    }

    private func throwStep() {
        guard var v = throwVelocity else { return stopThrow() }
        let frame = screenFrame(at: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        let minX = frame.minX - Self.side, maxX = frame.maxX - Self.size + Self.side
        let minY = frame.minY, maxY = frame.maxY - Self.size
        var o = panel.frame.origin
        o.x += v.dx / 60
        o.y += v.dy / 60
        var bounced = false
        if o.x < minX { o.x = minX; v.dx = -v.dx * 0.6; bounced = true }
        if o.x > maxX { o.x = maxX; v.dx = -v.dx * 0.6; bounced = true }
        if o.y < minY { o.y = minY; v.dy = -v.dy * 0.6; bounced = true }
        if o.y > maxY { o.y = maxY; v.dy = -v.dy * 0.6; bounced = true }
        if bounced && hypot(v.dx, v.dy) > 200 { haptic(.alignment) }  // удар о край
        v.dx *= 0.94
        v.dy *= 0.94
        panel.setFrameOrigin(o)

        if hypot(v.dx, v.dy) < 40 {
            stopThrow()
            savePosition()
            if throwPeak > 2500 {
                react(.dizzy, for: 2)
                hapticBurst(3)
            } else {
                haptic(.levelChange)
            }
            updateState()
        } else {
            throwVelocity = v
        }
    }

    // MARK: - Тактильный отклик

    private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard hapticsOn else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    private func hapticBurst(_ count: Int, pattern: NSHapticFeedbackManager.FeedbackPattern = .generic, interval: Double = 0.12) {
        for i in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(i)) { [weak self] in
                MainActor.assumeIsolated { self?.haptic(pattern) }
            }
        }
    }

    /// Поглаживание: три смены направления за 1,5 с над силуэтом. Бодрствующий мурчит отдачей трекпада,
    /// спящий не просыпается — отдача медленная, как сердцебиение.
    private func updatePetting(mouse: NSPoint, over: Bool) {
        let now = Date()
        let dx = mouse.x - lastPetMouse.x
        let moved = hypot(dx, mouse.y - lastPetMouse.y) > 0.5
        lastPetMouse = mouse
        guard over && !dragging && throwVelocity == nil else {
            petReversals = []
            if petting { stopPetting() }
            return
        }
        if moved {
            lastPetMove = now
            if abs(dx) > 1 {
                if lastPetDX != 0 && (dx > 0) != (lastPetDX > 0) { petReversals.append(now) }
                lastPetDX = dx
            }
        }
        petReversals.removeAll { $0 < now.addingTimeInterval(-1.5) }
        if !petting && petReversals.count >= 3 {
            petting = true
            if model.state == .sleep { sleepHold = true }
        }
        guard petting else { return }
        if now.timeIntervalSince(lastPetMove) > 0.6 {
            stopPetting()
            return
        }
        if sleepHold {
            if now.timeIntervalSince(lastHeartbeat) > 1.1 {
                lastHeartbeat = now
                hapticBurst(2, interval: 0.16)
            }
        } else {
            purrTick += 1
            if moved && purrTick % 2 == 0 { haptic(.alignment) }
        }
    }

    private func stopPetting() {
        petting = false
        lastInteraction = Date()
        petReversals = []
        character.interact(.pet)
        if !sleepHold { react(.happy, for: 1) }
    }

    // MARK: - Курсор

    /// Рывок курсора к Биту — вздрагивает; встряхивание курсора — показывает, где он.
    private func updateCursor(_ mouse: NSPoint, over: Bool) {
        let now = Date()
        let step = CGVector(dx: mouse.x - previousMouse.x, dy: mouse.y - previousMouse.y)
        previousMouse = mouse
        guard watching("cursor"), !dragging, throwVelocity == nil, !petting, !over,
              model.state != .sleep, now.timeIntervalSince(lastCursorReaction) > 3 else { return }

        let speed = hypot(step.dx, step.dy) * 20  // точек в секунду при 20 тиках
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let toBit = CGVector(dx: center.x - mouse.x, dy: center.y - mouse.y)
        let distance = hypot(toBit.dx, toBit.dy)
        let approach = (step.dx * toBit.dx + step.dy * toBit.dy) * 20
        if speed > 2000 && distance < 260 && approach > 0.8 * speed * distance {
            lastCursorReaction = now
            react(.surprised, for: 0.7)
            pendingFlinch = toBit.dx >= 0 ? 1 : -1
            return
        }

        if abs(step.dx) > 40 {  // больше 800 точек в секунду
            if lastCursorDX != 0 && (step.dx > 0) != (lastCursorDX > 0) { cursorReversals.append(now) }
            lastCursorDX = step.dx
        }
        cursorReversals.removeAll { $0 < now.addingTimeInterval(-1) }
        if cursorReversals.count >= 4 {
            cursorReversals = []
            lastCursorReaction = now
            react(.surprised, for: 1)
            showTransient(.locate, for: 2)
        }
    }

    /// Отпрянуть после смены состояния: смена состояния сбрасывает анимации тела.
    private var pendingFlinch: CGFloat?

    // Занятия: когда с Битом давно не играли, он развлекается сам.
    private var activity: (state: PetState, until: Date)?
    private var lastInteraction = Date()
    private var nextActivity = Date().addingTimeInterval(.random(in: 300...600))
    private var forcedOutcome: Bool?
    private static let hobbies: [PetState] = [.reading, .tetris, .racing, .boxing, .workout]
    private static let screenBusy: Set<PetState> = [.reading, .tetris, .racing, .boxing, .workout, .note, .menu, .timer, .clock]
    private var accessoriesInitialized = false

    // Реплики: облачко над Битом, долгие команды, встречи, ответы Claude.
    private let speaker = Speaker()
    private let commands = CommandWatcher()
    private let ollama = OllamaWatcher()
    private let meetings = MeetingWatcher()
    private var lastChat = Date.distantPast
    private var lastClickChat = Date.distantPast
    private var lockedAt: Date?
    private var greetedDay: Date?
    private var breakNags = 0
    private var lastBreakNag = Date.distantPast
    private var lastNightTalk = Date.distantPast
    private var agentStarted: [String: Date] = [:]
    private var agentAnswered: [String: Date] = [:]
    /// Claude ждёт пользователя: значок на экране, пока не открыли приложение или не написали в сессию.
    private struct AgentWait {
        let badge: PetBadge
        let app: pid_t?
        let since: Date
        let expires: Date
    }
    /// Журналы сессий: по времени их изменения видно, что Claude ещё работает или уже продолжил после разрешения.
    private var agentTranscripts: [String: String] = [:]
    /// Claude отвечает хотя бы в одной сессии (обновляется раз в секунду).
    private var agentWorking = false
    private var agentWaits: [String: AgentWait] = [:]
    private var agentTitles: [String: String] = [:]
    /// Оболочки с хуком zsh: о их командах сообщает хук (с кодом выхода), наблюдатель за процессами молчит.
    private var hookedShells: Set<pid_t> = []
    /// С какой длительности сообщать о командах.
    private var commandMinimum: TimeInterval {
        // double(forKey:) читает и число из настроек, и строку из аргумента запуска (-commandMinimum 15).
        get { defaults.object(forKey: "commandMinimum") == nil ? 30 : max(defaults.double(forKey: "commandMinimum"), 5) }
        set {
            defaults.set(newValue, forKey: "commandMinimum")
            commands.minimum = newValue
        }
    }
    /// Тихий час: фразы и уведомления молчат, встречи — нет.
    private var quietUntil: Date?
    private var isQuiet: Bool { (quietUntil ?? .distantPast) > Date() }

    // Таймер и помодоро: обратный отсчёт на экране Бита.
    private struct Countdown {
        enum Kind { case focus, rest, plain }
        let kind: Kind
        let start: Date
        let duration: TimeInterval
        var end: Date { start.addingTimeInterval(duration) }
    }
    private var countdown: Countdown?
    private var pomodoros = 0
    // Часы: курсор остановился над Битом; щелчок по часам — нагрузка CPU, ОЗУ и диска.
    private var clockHover = false
    private var clockUntil = Date.distantPast   // часы из «Отладки» и экран нагрузки при всплеске
    private var statsUntil = Date.distantPast
    private var spikes = LoadSpikes()
    private let coffee = CoffeeMode()
    /// Кофе включили руками; ещё он включается сам, пока идёт работа (autoCoffee).
    private var manualCoffee = false
    private var autoCoffeeOn = false
    /// Пока работает Claude или команда, экран не гаснет и на экране Бита кружка. Выключается в меню.
    private var autoCoffee: Bool {
        get { defaults.object(forKey: "autoCoffee") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoCoffee") }
    }
    /// Серверы и приложения, которые висят в терминале, — не работа (Бит не «работает» и кофе не включается).
    private var serversNotWork: Bool {
        get { defaults.bool(forKey: "serversNotWork") }
        set { defaults.set(newValue, forKey: "serversNotWork") }
    }
    // Антенну тянут вверх: длина — минуты таймера, отпустили — таймер пошёл.
    private let antenna = AntennaOverlay()
    private var antennaPull: (startY: CGFloat, minutes: Int)?
    // Напоминания: сколько секунд активной работы с последнего глотка воды и с последнего взгляда вдаль.
    private var waterActive: TimeInterval = 0
    private var eyesActive: TimeInterval = 0

    // Знакомство при первом запуске: Бит прилетает в центр, машет, потом рассказывает о себе рядом с карточкой.
    private var onboarding: OnboardingWindow?
    private var onboardingState: PetState?
    private var onboardingHome: NSPoint?
    private var onboardingCardShown = false

    // Быстрое меню по нажатию двумя пальцами; полное — в строке меню.
    private let quickMenu = QuickMenu()
    private var menuOpen = false
    private var settings: SettingsWindow?
    /// Автообновление из релизов GitHub (как в Trunook).
    private let updates = UpdateService()

    /// Хуки в агентах и терминале: путь — к этой копии Бита, шаблоны и хук zsh — в ресурсах приложения.
    private lazy var integrations: Integrations = {
        let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return Integrations(home: FileManager.default.homeDirectoryForCurrentUser, bin: Bundle.main.executablePath ?? "",
                            templates: resources.appendingPathComponent("integrations"),
                            zshScript: resources.appendingPathComponent("mypetbit.zsh").path)
    }()

    // Файлы в руках: перетащили на Бита — держит (файлы остаются на месте), утащили в папку — переезжают туда.
    private var held: [URL] = []
    private var heldPromises: [HeldFilePromise] = []
    private var dragFromHeld = false
    private var catchingHover = false
    private var movedBatch: [URL] = []
    /// Идущая конвертация и её доля (nil — без процента: внешняя программа, iWork).
    private var convertTask: ConvertTask?
    private var convertProgress: Double?

    // Музыка: свайп двумя пальцами — трек, долгое нажатие — пауза или игра (через помощника MyPetBitMedia).
    private let music = MusicControl()
    private var musicFlash: (glyph: String, until: Date)?
    /// После переключения трека Бит называет новый, когда плеер его сообщит.
    private var trackAnnounceUntil = Date.distantPast
    private var musicSeeded = false
    private var swipe = CGVector.zero
    private var swipeFired = false
    private var longPress: Timer?
    private var longPressFired = false

    // Карточка после запуска таймера: название и кофе на время таймера — по желанию.
    private let timerCard = TimerCard()
    private var timerName = ""
    private var timerCoffee = false

    // «Спрятать»: машет и улетает вверх, через выбранное время прилетает на своё место.
    private var hiddenUntil: Date?
    private var hideTimer: Timer?
    private var hideHome: NSPoint?
    private var flying = false
    /// На сколько прятать, минуты; 0 — пока не вернут.
    private var hideMinutes: Int {
        get { defaults.integer(forKey: "hideMinutes") }
        set { defaults.set(newValue, forKey: "hideMinutes") }
    }

    // Порядок на рабочем столе: расстановка значков, которую попросили запомнить.
    private var tidying = false

    // Отладка: подменённые на 10 секунд показания системы и примерка аксессуаров.
    private var debugUntil: [String: Date] = [:]
    private var debugAccessories: Set<Accessory> = []
    private var debugActions: [() -> Void] = []

    // MARK: - Окна

    /// Окно сдвинули на Бита — он отходит в сторону. Границы окон macOS отдаёт без разрешений, заголовки — нет, они не нужны.
    private func checkWindows() {
        guard watching("windows"), panel.isVisible, !dragging, throwVelocity == nil,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let bit = silhouette()
        var frames: [Int: CGRect] = [:]
        var pusher: CGRect?
        for window in list {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  window[kCGWindowOwnerPID as String] as? Int32 != me,
                  let number = window[kCGWindowNumber as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            // Координаты окон — от левого верхнего угла главного экрана.
            let rect = CGRect(x: cg.minX, y: mainHeight - cg.maxY, width: cg.width, height: cg.height)
            frames[number] = rect
            if pusher == nil, let old = windowFrames[number], old.size == rect.size, old.origin != rect.origin,
               rect.intersects(bit), !old.intersects(bit) {
                pusher = rect
            }
        }
        windowFrames = frames
        if let pusher { moveAside(from: pusher) }
    }

    private func moveAside(from window: CGRect) {
        let bit = silhouette()
        let screen = screenFrame(at: NSPoint(x: bit.midX, y: bit.midY))
        let gap: CGFloat = 8
        let leftX = window.minX - gap - bit.width - Self.side      // origin окна Бита слева от окна
        let rightX = window.maxX + gap - Self.side                 // справа от окна
        let leftOK = leftX + Self.side >= screen.minX
        let rightOK = rightX + Self.size - Self.side <= screen.maxX
        let current = panel.frame.minX
        let target: CGFloat
        switch (leftOK, rightOK) {
        case (true, true): target = abs(leftX - current) < abs(rightX - current) ? leftX : rightX
        case (true, false): target = leftX
        case (false, true): target = rightX
        default: return  // окно во всю ширину — некуда отходить
        }
        react(.surprised, for: 0.6)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            self.panel.animator().setFrameOrigin(NSPoint(x: target, y: self.panel.frame.minY))
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.savePosition() }
        })
    }

    // MARK: - Жизнь

    /// Показания системы с подменами из меню «Отладка».
    private var snapshot: SystemSnapshot {
        var s = monitor.snapshot
        for (key, until) in debugUntil where until > Date() { Self.applyDebug(key, to: &s) }
        return s
    }

    private var inCall: Bool { watching("call") && snapshot.inCall }

    private func react(_ state: PetState, for seconds: TimeInterval) {
        guard !inCall else { return }  // во время звонка Бит молчит
        reaction = (state, Date().addingTimeInterval(seconds))
    }

    private func showTransient(_ badge: PetBadge, for seconds: TimeInterval) {
        guard !inCall else { return }
        transient = (badge, Date().addingTimeInterval(seconds))
    }

    private func idleSeconds() -> TimeInterval {
        // ~0 — любое событие ввода (kCGAnyInputEventType).
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func keyIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }

    private func tick() {
        ticks += 1
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame

        // Клики сквозь прозрачные края: окно ловит мышь, только когда курсор над силуэтом.
        // Координаты силуэта — в системе 200x200, как в BitLayerView.
        let u = (mouse.x - frame.minX) / frame.width * 200
        let v = (frame.maxY - mouse.y) / frame.height * 200
        let hit = panel.isVisible && (((28...172).contains(u) && (20...170).contains(v)) || Self.antennaZone(u, v)
                                      || (!held.isEmpty && BitLayerView.heldZone.contains(CGPoint(x: u, y: v))))
        cursorOverBit = hit
        // Часы: курсор остановился над Битом на секунду; ушёл — часы гаснут.
        if !hit || dragging || petting || menuOpen {
            clockHover = false
        } else if !clockHover && Date().timeIntervalSince(mouseStillSince) >= 1 && model.state != .sleep {
            clockHover = true
        }
        if !dragging && antennaPull == nil && panel.ignoresMouseEvents == hit { panel.ignoresMouseEvents = !hit }

        updatePetting(mouse: mouse, over: hit)
        updateCursor(mouse, over: hit)
        if ticks % 10 == 0 { checkWindows() }  // 2 раза в секунду
        if ticks % 20 == 0 { checkTime() }     // раз в секунду
        updateState()
        if let direction = pendingFlinch {
            pendingFlinch = nil
            view.flinch(-direction)
        }
        updateLook(mouse: mouse, frame: frame)
    }

    private func updateState() {
        let now = Date()
        if let r = reaction, r.until < now { reaction = nil }
        if let t = transient, t.until < now { transient = nil }
        if sleepHold && !petting && (keyIdleSeconds() < 1 || !cursorOverBit) { sleepHold = false }

        // Тихий час — спит. Пока работает Claude или команда, от простоя не засыпает: работает вместе с ними.
        let asleep = forcedState == nil && !dragging
            && (isQuiet || sleepHold || (sleepAfter > 0 && idleSeconds() >= sleepAfter && !externalWork && !coffee.isOn))
        if wasAsleep && !asleep { react(.happy, for: 2) }  // проснулся — здоровается
        wasAsleep = asleep

        let state: PetState
        if dragging || throwVelocity != nil {
            state = .surprised
        } else if let onboardingState {
            state = onboardingState  // знакомство: Бит показывает то, о чём рассказывает
        } else if antennaPull != nil {
            state = .timer  // на экране — выбранные минуты
        } else if menuOpen {
            state = .menu
        } else if petting && !asleep {
            state = character.level >= 4 ? .love : .purr  // «Неразлучные» — глаза-сердечки
        } else if clockHover || clockUntil > now {
            state = .clock
        } else if let flash = musicFlash, flash.until > now {
            state = .timer  // на экране — значок команды и трек
        } else if convertProgress != nil {
            state = .timer  // на экране — сколько сконвертировано
        } else if let r = reaction {
            state = r.state
        } else if let forcedState {
            state = forcedState
        } else if countdown != nil {
            activity = nil
            state = .timer  // таймер сам завели — он важнее забот и сна
        } else if asleep {
            activity = nil
            state = .sleep
        } else {
            let system = systemState()
            if system != nil { activity = nil }  // заботы важнее игр
            state = system ?? activity?.state ?? .idle
        }
        model.set(state)
        updateScreen(state, now)

        let badge = forcedBadge ?? (inCall ? nil : transient?.badge ?? currentBadge())
        if model.badge != badge { model.badge = badge }

        let s = snapshot
        let lowPower = watching("lowPower") && s.lowPower
        if model.lowPower != lowPower { model.lowPower = lowPower }
        let context = OutfitContext(streakMinutes: character.streakMinutes,
                                    busy: s.isBusy || (watching("typing") && events.isTypingFast),
                                    music: watching("music") && s.isMusic,
                                    headphones: defaults.bool(forKey: "forcedHeadphones") || (watching("headphones") && s.headphones))
        // Одна вещь за раз: примерка из «Отладки» важнее всего.
        var accessories = debugAccessories.isEmpty ? (forcedAccessories ?? character.accessories(context: context)) : debugAccessories
        // Занят чем-то на экране — снимает то, что экран закрывает, потом наденет обратно.
        if Self.screenBusy.contains(state) { accessories.subtract([.pumpkin, .glasses]) }
        if model.accessories != accessories {
            // Надел что-то новое сам — доволен обновкой.
            if accessoriesInitialized && forcedAccessories == nil && !accessories.subtracting(model.accessories).isEmpty {
                react(.happy, for: 1)
            }
            model.accessories = accessories
            accessoriesInitialized = true
        }
        // Звонок: Бит становится полупрозрачным.
        let alpha: CGFloat = inCall ? 0.35 : 1
        if panel.alphaValue != alpha {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                self.panel.animator().alphaValue = alpha
            }
        }
    }

    // MARK: - Время суток и перерывы

    private var isNight: Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour >= 23 || hour < 5 || debugging("night")
    }

    /// 90 минут без перерыва в 5 минут, или привычное время перерыва давно прошло.
    private var isLongWork: Bool {
        character.streakMinutes >= 90 || debugging("longWork") || (watching("character") && character.isBreakOverdue())
    }

    private func checkTime() {
        let now = Date()
        let idle = idleSeconds()
        character.tick(idle: idle)
        updateAgentWork(now)
        // Кофе на время работы: экран не гаснет, пока работает Claude или идёт команда.
        let auto = autoCoffee && externalWork
        if auto != autoCoffeeOn {
            autoCoffeeOn = auto
            applyCoffee()
        }
        expireDebug(now)
        updateActivity(now, idle: idle)
        // Микродействие — только когда Бит бодрствует и свободен.
        if watching("character"), reaction == nil, forcedState == nil, model.state == .idle, !inCall,
           let action = character.microAction() {
            react(action.state, for: action.seconds)
        }
        // Перерыв: напоминает словами, потом ещё раз через полчаса.
        if watching("breaks") && isLongWork {
            if idle < 5 && now.timeIntervalSince(lastBreakNag) > 30 * 60 {
                let streak = character.streakMinutes
                let detail = streak >= 60 ? L("Без перерыва уже %@", "\(Self.duration(streak * 60))") : nil
                if chat(breakNags == 0 ? L("Пора сделать перерыв!") : L("Может, всё-таки перерыв? Я подожду"), detail: detail) {
                    breakNags += 1
                    lastBreakNag = now
                }
            }
        } else {
            breakNags = 0
            lastBreakNag = .distantPast
        }
        if let c = countdown, now >= c.end { finishCountdown(c) }
        checkReminders(now, idle: idle)
        guard watching("time"), idle < 2 else { return }
        if isNight && now.timeIntervalSince(lastNightTalk) > 6 * 3600 && chat(L("Уже поздно. Может, пора спать?")) {
            lastNightTalk = now
        }
        let hour = Calendar.current.component(.hour, from: now)
        if (20..<23).contains(hour), now.timeIntervalSince(lastEveningYawn) > 45 * 60 {
            lastEveningYawn = now
            react(.yawn, for: 2.5)
        }
    }

    private func handleCharacter(_ event: CharacterEvent) {
        switch event {
        case .newDay(let late):
            greet(late: late)
            // Первая активность за день: в выходной — радость, после позднего вечера — зевает, утром — потягивается.
            guard watching("time") else { break }
            let now = Date()
            if Calendar.current.isDateInWeekend(now) {
                react(.happy, for: 2)
                showTransient(.weekend, for: 4)
            } else if late || Calendar.current.component(.hour, from: now) < 12 {
                react(.yawn, for: 2.5)
            }
        case .breakOver(let minutes):
            if watching("character") {
                react(.happy, for: 2)
                showTransient(.wave, for: 2.5)
                chat(L("С возвращением! Продолжаем?"), detail: L("Перерыв — %@", "\(Self.duration(Double(minutes) * 60))"))
            }
        case .levelUp(let level):
            react(.happy, for: 2.5)
            showTransient(.levelUp, for: 4)
            if PetCharacter.levels.indices.contains(level) {
                chat(L("Мы стали ближе!"), detail: L("Новый уровень: «%@»", "\(PetCharacter.levels[level].title)"), ignoreCooldown: true)
            }
            hapticBurst(2, pattern: .levelChange, interval: 0.15)
        }
        updateState()
    }

    // MARK: - Реакции на систему

    private func watching(_ key: String) -> Bool { watched.contains(key) }

    private func handle(_ event: PetEvent, force: Bool = false) {
        let on: (String) -> Bool = { force || self.watching($0) }
        switch event {
        case .locked:
            lockedAt = Date()  // экран и так заблокирован — только запоминаем, когда ушли
        case .unlocked:
            if on("lock") {
                react(.happy, for: 2)
                showTransient(.wave, for: 3)
            }
            // Долго не было — здоровается. Первое за день приветствие скажет «Новый день».
            if let away = lockedAt.map({ Date().timeIntervalSince($0) }), away >= 20 * 60,
               greetedDay.map({ $0 == Calendar.current.startOfDay(for: Date()) }) ?? true {
                chat([L("С возвращением!"), L("О, привет снова!"), L("Я скучал!")].randomElement()!)
            }
            lockedAt = nil
        case .didWake:
            if on("lock") { react(.yawn, for: 2.5) }
        case .screensChanged:
            if !isOnScreen(panel.frame.origin) {
                panel.setFrameOrigin(defaultOrigin())
                savePosition()
            }
        case .clipboard:
            if on("clipboard") { react(.note, for: 3.2) }  // скопировали — записывает карандашом
        case .screenshot:
            if on("screenshots") && !inCall {
                view.flash()
                react(.surprised, for: 0.8)
                showTransient(.screenshot, for: 2.5)
            }
        case .downloadFinished:
            if on("downloads") {
                react(.happy, for: 2)
                showTransient(.delivered, for: 3)
                chat(L("Файл скачан!"))
            }
        }
        updateState()
    }

    // MARK: - Реплики

    private static let clickLines = [L("Привет!"), L("Я здесь!"), L("Работаем?"), L("Хорошего дня!"), L("Бип-боп!"), L("Мне нравится, когда ты заглядываешь")]

    /// Болтовня: не чаще раза в минуту, не во время звонка и не поверх другого облачка. true — сказал.
    @discardableResult
    private func chat(_ text: String, detail: String? = nil, ignoreCooldown: Bool = false, force: Bool = false) -> Bool {
        let now = Date()
        guard force || (watching("talk") && !isQuiet && !inCall && panel.isVisible && !speaker.isSpeaking
                        && (ignoreCooldown || now.timeIntervalSince(lastChat) >= 60)) else { return false }
        lastChat = now
        speaker.say(Speech(text: text, detail: detail, seconds: 4 + Double(text.count + (detail?.count ?? 0)) * 0.04))
        return true
    }

    /// Уведомление: ждёт в очереди, если Бит уже говорит. Кнопка возвращает в приложение, откуда пришла весть.
    private func notice(_ text: String, detail: String?, app: pid_t?, tty: String? = nil, force: Bool = false) {
        guard force || (panel.isVisible && !inCall && !isQuiet) else { return }
        var speech = Speech(text: text, detail: detail, kind: .notice, seconds: 10)
        if let app, let running = NSRunningApplication(processIdentifier: app), let name = running.localizedName {
            speech.button = L("Открыть %@", "\(name)")
            speech.action = { [weak self] in self?.reveal(running, tty: tty) }
        }
        speaker.say(speech)
    }

    /// Первое за день: «Доброе утро», «Добрый день», «Добрый вечер» — по часам; в выходной — о выходном.
    private func greet(late: Bool, force: Bool = false) {
        let now = Date()
        greetedDay = Calendar.current.startOfDay(for: now)
        let hour = Calendar.current.component(.hour, from: now)
        let text: String
        if Calendar.current.isDateInWeekend(now) && (5..<23).contains(hour) {
            text = [L("Выходной! Может, отдохнём?"), L("Ура, выходной!")].randomElement()!
        } else {
            switch hour {
            case 5..<12: text = late ? L("Доброе утро… Вчера мы засиделись") : [L("Доброе утро!"), L("Доброе утро! Начинаем?"), L("Утро! Я уже проснулся")].randomElement()!
            case 12..<17: text = [L("Добрый день!"), L("Привет! Хорошего дня")].randomElement()!
            case 17..<23: text = [L("Добрый вечер!"), L("Привет! Уже вечер")].randomElement()!
            default: text = L("Доброй ночи. Не спится?")
            }
        }
        chat(text, ignoreCooldown: true, force: force)
    }

    /// `MyPetBit --say "текст"` из любого скрипта.
    private func heard(_ info: [String: String]) {
        guard let text = info["text"], !text.isEmpty else { return }
        notice(String(text.prefix(120)), detail: info["detail"].map { String($0.prefix(160)) }, app: info["app"].flatMap { pid_t($0) })
    }

    /// Как зовут агентов в облачках.
    private static let agentNames = ["claude": "Claude", "cursor": "Cursor", "opencode": "OpenCode", "ollama": "Ollama",
                                     "codex": "Codex", "kimi": "Kimi"]
    /// Когда какой-то агент последний раз закончил ответ: Ollama, через которую отвечал OpenCode, не повторяет его облачко.
    private var lastAgentStop = Date.distantPast

    /// События агентов (хуки Claude Code, Cursor, Kimi, Codex, плагин OpenCode, нагрузка Ollama): начал отвечать —
    /// Бит «работает»; ответ дольше 20 секунд — облачко «… ответил»; ответил или просит разрешение — значок на экране,
    /// пока не открыли приложение или не написали в эту сессию.
    private func agentHook(_ info: [String: String]) {
        let agent = info["agent"] ?? "claude"
        let who = Self.agentNames[agent] ?? agent.capitalized
        let session = agent + ":" + (info["session"] ?? "default")
        let now = Date()
        let app = info["app"].flatMap { pid_t($0) }
        let tty = info["tty"]
        if let path = info["transcript"] {
            agentTranscripts[session] = path
            if agent == "claude", let title = Self.claudeTitle(transcript: path) { agentTitles[session] = title }
        }
        if let title = info["title"], !title.isEmpty {
            agentTitles[session] = title.count > 50 ? String(title.prefix(49)) + "…" : title
        }
        let name = agentTitles[session] ?? info["cwd"].map { ($0 as NSString).lastPathComponent }
        switch info["kind"] {
        case "start":
            agentStarted[session] = now
            agentWaits[session] = nil
        case "stop":
            let took = agentStarted.removeValue(forKey: session).map { now.timeIntervalSince($0) }
            guard watching("claude") else { break }
            // Cursor: ответ прервали — ничего не говорим.
            if info["status"] == "aborted" { break }
            if agent == "ollama" && now.timeIntervalSince(lastAgentStop) < 15 { break }
            lastAgentStop = now
            agentAnswered[session] = now
            wait(session, .claudeDone, app: app)
            if info["status"] == "error" {
                notice(L("%@ остановился с ошибкой", "\(who)"), detail: name, app: app, tty: tty)
                react(.sad, for: 2)
            } else if (took ?? .infinity) >= 20 {
                notice(L("%@ ответил", "\(who)"), detail: [name, took.map { Self.duration($0) }].compactMap { $0 }.joined(separator: " · "),
                       app: app, tty: tty)
            }
        case "ask", "wait":
            guard watching("claude") else { break }
            let asks = info["kind"] == "ask"
            // «Жду ввода» приходит через минуту после ответа — о нём уже сказали.
            if !asks, let answered = agentAnswered[session], now.timeIntervalSince(answered) < 5 * 60 { break }
            wait(session, asks ? .claudeAsks : .claudeDone, app: app)
            notice(asks ? L("%@ просит разрешение", "\(who)") : L("%@ ждёт ответа", "\(who)"), detail: name, app: app, tty: tty)
        default:
            break
        }
        updateState()
    }

    /// Значок «агент ждёт». Приложение уже перед глазами — значок ненадолго: ответ и так виден
    /// (в другой сессии того же приложения он мог и не быть виден, поэтому не сразу убираем).
    private func wait(_ session: String, _ badge: PetBadge, app: pid_t?) {
        let front = app != nil && NSWorkspace.shared.frontmostApplication?.processIdentifier == app && idleSeconds() < 10
        agentWaits[session] = AgentWait(badge: badge, app: app, since: Date(), expires: Date().addingTimeInterval(front ? 120 : 30 * 60))
    }

    /// Работает вместе с вами: Claude отвечает или в терминале идёт команда — до завершения.
    private var externalWork: Bool {
        (watching("claude") && agentWorking) || (watching("commands") && commands.isBusy(ignoringLongLived: serversNotWork))
    }

    /// Раз в секунду: идёт ли ответ Claude. Между запросом и концом ответа — идёт; прервали ответ (Stop не придёт)
    /// или журнал сессии 15 минут не меняется — значит, стоит. Журнал изменился после запроса разрешения — разрешили,
    /// ладошка с экрана уходит.
    private func updateAgentWork(_ now: Date) {
        func touched(_ session: String) -> Date? {
            agentTranscripts[session].flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
        }
        for (session, wait) in agentWaits where wait.badge == .claudeAsks {
            if let t = touched(session), t > wait.since.addingTimeInterval(3) { agentWaits[session] = nil }
        }
        agentStarted = agentStarted.filter { session, start in
            if session.hasPrefix("ollama:") { return true }  // о конце скажет сама нагрузка
            guard let t = touched(session) else { return now.timeIntervalSince(start) < 60 * 60 }
            return now.timeIntervalSince(max(start, t)) < 15 * 60
        }
        agentWorking = !agentStarted.isEmpty
    }

    /// Открыли приложение, где ждёт Claude, — значок больше не нужен.
    private func appActivated(_ pid: pid_t?) {
        guard let pid, agentWaits.values.contains(where: { $0.app == pid }) else { return }
        agentWaits = agentWaits.filter { $0.value.app != pid }
        updateState()
    }

    /// Название сессии Claude Code из журнала: последняя запись `custom-title` в хвосте файла.
    private static func claudeTitle(transcript path: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home + "/.claude/"), path.hasSuffix(".jsonl"),
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let mark = text.range(of: "\"type\":\"custom-title\"", options: .backwards) else { return nil }
        let lineStart = text[..<mark.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[mark.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        guard let json = try? JSONSerialization.jsonObject(with: Data(text[lineStart..<lineEnd].utf8)) as? [String: Any],
              let title = json["customTitle"] as? String, !title.isEmpty else { return nil }
        return title.count > 50 ? String(title.prefix(49)) + "…" : title
    }

    private func commandFinished(_ job: CommandWatcher.Finished) {
        // Оболочка с хуком zsh сообщит сама, с кодом выхода, — даём ей время и молчим.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.hookedShells.contains(job.shell) else { return }
                self.notice(L("Команда завершилась"), detail: "\(job.command) · \(Self.duration(job.duration))", app: job.app, tty: job.tty)
            }
        }
    }

    /// Хук zsh (`tools/mypetbit.zsh`): команда закончилась, известен код выхода.
    private func commandHook(_ info: [String: String]) {
        guard let shell = info["shell"].flatMap({ pid_t($0) }) else { return }
        hookedShells.insert(shell)
        guard watching("commands"), let status = info["status"].flatMap({ Int($0) }),
              let seconds = info["seconds"].flatMap({ Double($0) }), seconds >= commandMinimum else { return }
        // Остановили сами (⌃C, ⌃Z) — сообщать незачем.
        guard ![130, 146, 147, 148, 149].contains(status) else { return }
        let line = (info["command"] ?? "").split(separator: "\n").first.map(String.init) ?? ""
        guard let command = CommandWatcher.describe(line) else { return }  // vim, ssh, claude… — интерактивные
        let app = info["app"].flatMap { pid_t($0) }
        let took = Self.duration(seconds)
        if status == 0 {
            notice(L("Команда завершилась"), detail: "\(command) · \(took)", app: app, tty: info["tty"])
        } else {
            notice(L("Команда упала"), detail: L("%@ · код %@ · %@", "\(command)", "\(status)", "\(took)"), app: app, tty: info["tty"])
            react(.sad, for: 2.5)
            showTransient(.commandFailed, for: 8)
            updateState()
        }
    }

    /// Показать приложение; у Терминала и iTerm — ту самую вкладку (macOS один раз спросит разрешение на управление ими).
    private func reveal(_ app: NSRunningApplication, tty: String?) {
        app.activate()
        guard let tty, tty.hasPrefix("/dev/tty"), tty.dropFirst(5).allSatisfy({ $0.isLetter || $0.isNumber }) else { return }
        let script: String
        switch app.bundleIdentifier {
        case "com.apple.Terminal":
            script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected tab of w to t
                            set index of w to 1
                        end if
                    end repeat
                end repeat
                activate
            end tell
            """
        case "com.googlecode.iterm2":
            script = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                tell t to select
                                tell s to select
                            end if
                        end repeat
                    end repeat
                end repeat
                activate
            end tell
            """
        default:
            return
        }
        // Отдельным процессом: запрос разрешения не должен останавливать Бита.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    /// Встреча: за 5 минут и в начало. Кнопка «Подключиться» открывает ссылку из события.
    private func remind(_ reminder: MeetingWatcher.Reminder) {
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        let title = reminder.title.count > 60 ? String(reminder.title.prefix(59)) + "…" : reminder.title
        let text = reminder.minutes == 0 ? L("Встреча начинается!") : L("Через %@ %@ встреча", "\(reminder.minutes)", "\(Lang.minutes(reminder.minutes))")
        var speech = Speech(text: text, detail: "\(title) · \(time.string(from: reminder.start))–\(time.string(from: reminder.end))",
                            kind: .meeting, seconds: reminder.minutes == 0 ? 90 : 25)
        // «Скоро» нужно до начала, «начинается» — первые 10 минут: после сна Mac прошедшая встреча не всплывёт.
        speech.expires = reminder.minutes == 0 ? min(reminder.end, reminder.start.addingTimeInterval(10 * 60)) : reminder.start
        if let link = reminder.link {
            speech.button = L("Подключиться")
            speech.action = { NSWorkspace.shared.open(link) }
        }
        speaker.say(speech)
        haptic(.levelChange)
    }

    /// «45 с», «2 мин 14 с», «1 ч 35 мин».
    private static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return L("%@ с", "\(s)") }
        if s < 600 { return s % 60 == 0 ? L("%@ мин", "\(s / 60)") : L("%@ мин %@ с", "\(s / 60)", "\(s % 60)") }
        if s < 3600 { return L("%@ мин", "\(s / 60)") }
        return s / 60 % 60 == 0 ? L("%@ ч", "\(s / 3600)") : L("%@ ч %@ мин", "\(s / 3600)", "\(s / 60 % 60)")
    }


    // Отладка и -demoEvent: каждая реплика по одному пункту.
    private static let debugLines: [(String, String)] = [
        ("greeting", L("Приветствие по времени суток")), ("welcome", L("С возвращением")), ("break", L("Пора сделать перерыв")),
        ("night", L("Уже поздно")), ("click", L("Ответ на щелчок")), ("claude", L("Claude ответил")),
        ("claudeAsk", L("Claude просит разрешение")), ("command", L("Долгая команда завершилась")), ("commandFailed", L("Долгая команда упала")),
        ("meetingSoon", L("Встреча через 5 минут")), ("meetingNow", L("Встреча начинается")),
        ("timer", L("Таймер на 10 секунд")), ("pomodoro", L("Помодоро: 10 секунд фокуса")), ("clock", L("Часы на экране")),
        ("coffee", L("Кофе-режим вкл/выкл")), ("summary", L("Итог дня")), ("water", L("Попей воды")), ("eyes", "20-20-20"),
        ("stats", L("Нагрузка на экране")), ("loadCpu", L("Выросла нагрузка на процессор")), ("loadMemory", L("Память почти занята")),
        ("loadDisk", L("Место на диске быстро уходит"))
    ]

    private func sayDebug(_ key: String) {
        let terminal = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first?.processIdentifier
        let claude = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first?.processIdentifier
        let now = Date()
        switch key {
        case "greeting": greet(late: false, force: true)
        case "welcome": chat(L("С возвращением!"), force: true)
        case "break": chat(L("Пора сделать перерыв!"), detail: L("Без перерыва уже 1 ч 35 мин"), force: true)
        case "night": chat(L("Уже поздно. Может, пора спать?"), force: true)
        case "click": chat(Self.clickLines.randomElement()!, force: true)
        case "claude":
            wait("debug", .claudeDone, app: claude)
            notice(L("Claude ответил"), detail: L("Проект милого питомца · 2 мин 40 с"), app: claude, force: true)
        case "claudeAsk":
            wait("debug", .claudeAsks, app: claude)
            notice(L("Claude просит разрешение"), detail: L("Проект милого питомца"), app: claude, force: true)
        case "command": notice(L("Команда завершилась"), detail: L("swift build · 1 мин 12 с"), app: terminal, force: true)
        case "commandFailed":
            notice(L("Команда упала"), detail: L("swift build · код 1 · 1 мин 12 с"), app: terminal, force: true)
            react(.sad, for: 2.5)
            showTransient(.commandFailed, for: 8)
        case "timer": startCountdown(.plain, 10, offer: true)
        case "pomodoro": startCountdown(.focus, 10, offer: true)
        case "clock": clockUntil = now.addingTimeInterval(6)
        case "coffee": setCoffee(!manualCoffee)
        case "summary": showSummary(force: true)
        case "water": remindWater(force: true)
        case "eyes": remindEyes(force: true)
        case "stats":
            clockUntil = now.addingTimeInterval(6)
            statsUntil = clockUntil
        case "loadCpu": announceSpike(.init(kind: .cpu, now: 0.92, before: 0.12, minutes: 0))
        case "loadMemory": announceSpike(.init(kind: .memory, now: 0.91, before: 0.62, minutes: 0))
        case "loadDisk":
            let used = Double(snapshot.diskTotalBytes ?? 0) * (snapshot.diskUsed ?? 0)
            announceSpike(.init(kind: .disk, now: used, before: used - 8e9, minutes: 7))
        case "meetingSoon", "meetingNow":
            let soon = key == "meetingSoon"
            let start = now.addingTimeInterval(soon ? 300 : 0)
            remind(.init(title: L("Синк команды"), start: start, end: start.addingTimeInterval(1800),
                         minutes: soon ? 5 : 0, link: URL(string: "https://zoom.us/test")))
        default: break
        }
    }

    // MARK: - Таймер, часы, кофе, итог дня, напоминания

    /// Антенна в системе 200x200: стебель x = 100, y 34…52, лампочка — круг у (100, 30).
    private static func antennaZone(_ u: CGFloat, _ v: CGFloat) -> Bool {
        (86...114).contains(u) && (12...50).contains(v)
    }

    private func onAntenna(_ point: NSPoint) -> Bool {
        let f = panel.frame
        return Self.antennaZone((point.x - f.minX) / f.width * 200, (f.maxY - point.y) / f.height * 200)
    }

    private func beginAntennaPull(at y: CGFloat) {
        stopThrow()
        lastInteraction = Date()
        antennaPull = (y, 0)
        view.setAntennaPulled(true)
        antenna.begin(base: antennaBase(), scale: panel.frame.width / 200, below: panel)
        haptic(.generic)
        updateState()
    }

    /// Выше — больше минут, обратно — меньше; на каждую минуту — щелчок трекпада, на каждые пять — сильнее.
    private func moveAntennaPull(_ distance: CGFloat) {
        guard let pull = antennaPull else { return }
        let length = min(max(0, distance), AntennaOverlay.maxPull)
        let minutes = Int(length / AntennaOverlay.perMinute)
        if minutes != pull.minutes { haptic(minutes % 5 == 0 ? .levelChange : .alignment) }
        antennaPull = (pull.startY, minutes)
        antenna.update(pull: length, minutes: minutes)
        updateState()
    }

    /// Отпустили: антенна пружинкой на место, выбрали хоть минуту — таймер пошёл.
    private func endAntennaPull() {
        guard let pull = antennaPull else { return }
        antennaPull = nil
        antenna.end { [weak self] in self?.view.setAntennaPulled(false) }
        if pull.minutes > 0 {
            startCountdown(.plain, TimeInterval(pull.minutes * 60), offer: true)
            haptic(.levelChange)
        }
        updateState()
    }

    /// Для проверки без мыши: вытянуть на 20 минут за полторы секунды, подержать, отпустить.
    private func demoAntennaPull() {
        beginAntennaPull(at: 0)
        for step in 1...30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(step)) { [weak self] in
                MainActor.assumeIsolated { self?.moveAntennaPull(AntennaOverlay.perMinute * 20.5 * CGFloat(step) / 30) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated { self?.endAntennaPull() }
        }
    }

    /// Основание антенны на корпусе — в экранных координатах.
    private func antennaBase() -> NSPoint {
        let f = panel.frame
        return NSPoint(x: f.minX + f.width / 2, y: f.maxY - f.height * 52 / 200)
    }

    /// offer — таймер завели сами: рядом с Битом карточка с названием и кофе-режимом (по желанию).
    private func startCountdown(_ kind: Countdown.Kind, _ seconds: TimeInterval, offer: Bool = false) {
        if kind != .rest && countdown?.kind != .rest && kind != .focus { pomodoros = 0 }
        countdown = Countdown(kind: kind, start: Date(), duration: seconds)
        lastInteraction = Date()
        if offer {
            timerName = ""
            timerCoffee = false
            applyCoffee()
            offerTimerCard(kind, seconds)
        }
        updateState()
    }

    private func stopCountdown() {
        countdown = nil
        pomodoros = 0
        timerName = ""
        timerCoffee = false
        timerCard.close()
        applyCoffee()
        updateState()
    }

    private func offerTimerCard(_ kind: Countdown.Kind, _ seconds: TimeInterval) {
        guard panel.isVisible else { return }
        let model = timerCard.model
        model.onName = nil
        model.onCoffee = nil
        model.name = ""
        model.coffee = false
        model.onName = { [weak self] name in
            self?.timerName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.updateState()
        }
        model.onCoffee = { [weak self] on in
            guard let self else { return }
            self.timerCoffee = on
            self.applyCoffee()
            if on { self.react(.happy, for: 1) }
            self.updateState()
        }
        model.onDone = { [weak self] in self?.timerCard.close() }
        timerCard.show(title: kind == .focus ? L("Помодоро 25 мин") : L("Таймер на %@", "\(Self.duration(seconds))"), near: panel.frame)
    }

    /// Время вышло: облачко с кнопкой продолжения. Таймер завели сами — показываем и в тихий час.
    private func finishCountdown(_ c: Countdown) {
        countdown = nil
        timerCard.close()
        hapticBurst(3, pattern: .levelChange, interval: 0.15)
        // Название — впереди пояснения: «Отчёт · Помидор №1 готов…».
        let name = timerName
        let named: (String) -> String = { name.isEmpty ? $0 : "«\(name)» · " + $0 }
        var speech: Speech
        switch c.kind {
        case .focus:
            pomodoros += 1
            let rest: TimeInterval = pomodoros % 4 == 0 ? 15 * 60 : 5 * 60
            speech = Speech(text: L("Перерыв!"), detail: named(L("Помидор №%@ готов · отдых %@ мин", "\(pomodoros)", "\(Int(rest / 60))")), kind: .notice,
                            button: L("Пропустить отдых"), seconds: 15)
            speech.action = { [weak self] in self?.startCountdown(.focus, 25 * 60) }
            startCountdown(.rest, rest)
        case .rest:
            speech = Speech(text: L("Перерыв окончен"), detail: L("Продолжаем?"), kind: .notice, button: L("Ещё помидор"), seconds: 20)
            speech.action = { [weak self] in self?.startCountdown(.focus, 25 * 60) }
        case .plain:
            speech = Speech(text: L("Время вышло!"), detail: named(L("Таймер на %@", "\(Self.duration(c.duration))")), kind: .notice,
                            button: L("Ещё 5 минут"), seconds: 20)
            // Простой таймер кончился — название и кофе тоже; «Ещё 5 минут» возвращает их.
            let coffeeWas = timerCoffee
            timerName = ""
            timerCoffee = false
            speech.action = { [weak self] in
                guard let self else { return }
                self.timerName = name
                self.timerCoffee = coffeeWas
                self.startCountdown(.plain, 5 * 60)
                self.applyCoffee()
            }
        }
        applyCoffee()
        speaker.say(speech)
        // Отработал помидор — потягивается; остальное — радуется.
        react(c.kind == .focus ? .yawn : .happy, for: 2.5)
        if c.kind == .focus { showTransient(.stretch, for: 4) }
        updateState()
    }

    /// Таймер и часы на экране: цифры обновляются раз в секунду, рамка тает по мере отсчёта.
    private func updateScreen(_ state: PetState, _ now: Date) {
        switch state {
        case .timer:
            if let pull = antennaPull {
                let m = pull.minutes
                view.showScreenText(String(format: "%02d:00", m), small: m == 0 ? L("тяни антенну") : L("отпусти — старт"),
                                    progress: Double(m) / Double(AntennaOverlay.maxMinutes))
                return
            }
            if let flash = musicFlash, flash.until > now {
                let title = music.track?.title ?? ""
                view.showScreenText(flash.glyph, small: title.count > 16 ? String(title.prefix(15)) + "…" : title, progress: nil)
                return
            }
            if let done = convertProgress {
                view.showScreenText("\(Int((done * 100).rounded()))%", small: L("конвертирую"), progress: done)
                return
            }
            guard let c = countdown else { return }
            let left = max(0, c.end.timeIntervalSince(now))
            var label = c.kind == .focus ? L("фокус · %@", "\(pomodoros + 1)") : c.kind == .rest ? L("отдых") : L("таймер")
            if !timerName.isEmpty && c.kind != .rest {
                label = timerName.count > 13 ? String(timerName.prefix(12)) + "…" : timerName
            }
            view.showScreenText(Self.mmss(left), small: label, progress: c.duration > 0 ? left / c.duration : 0,
                                tint: c.kind == .rest ? 0x34C759 : 0x5CF2E0)
        case .clock:
            if now < statsUntil {
                view.hideScreenText()
                view.showStats(statsRows())
            } else {
                view.hideStats()
                // Двоеточие мигает раз в секунду.
                let colon = Int(now.timeIntervalSince1970) % 2 == 0 ? ":" : " "
                view.showScreenText(Self.format("HH", now) + colon + Self.format("mm", now),
                                    small: Self.format("EE, d MMM", now), progress: nil)
            }
        default:
            break
        }
    }

    private func setCoffee(_ on: Bool) {
        manualCoffee = on
        applyCoffee()
        if on { react(.happy, for: 1.2) }
        updateState()
    }

    private func applyCoffee() {
        coffee.set(manualCoffee || autoCoffeeOn || (timerCoffee && countdown != nil))
        view.setCoffee(coffee.isOn)
    }

    /// Прервать команду — сначала Бит переспрашивает в облачке: случайный щелчок не остановит долгую сборку.
    private func askInterrupt(_ job: CommandWatcher.Running) {
        var speech = Speech(text: L("Прервать команду?"), detail: L("%@ · идёт %@", "\(job.command)", "\(Self.duration(Date().timeIntervalSince(job.start)))"),
                            kind: .notice, button: L("Прервать (как ⌃C)"), seconds: 12)
        speech.action = { [weak self] in
            guard let self else { return }
            self.commands.interrupt(job.pid)
            self.react(.surprised, for: 1)
            self.speaker.say(Speech(text: L("Прервал"), detail: job.command, kind: .notice, seconds: 4))
        }
        speaker.say(speech)
    }

    /// Итог дня: вечером, когда за день наработали больше двух часов, — один раз; из меню — в любое время.
    private func showSummary(force: Bool = false) {
        guard let today = character.today else { return }
        guard force || (!isQuiet && !inCall && panel.isVisible) else { return }
        var detail = L("Работа %@ · перерывов %@", "\(Self.duration(today.activeSeconds))", "\(today.breaks)")
        if today.longestStreak >= 60 { detail += L("\nБез паузы — до %@", "\(Self.duration(today.longestStreak))") }
        speaker.say(Speech(text: today.activeSeconds >= 6 * 3600 ? L("Итог дня: потрудились!") : L("Итог дня"), detail: detail,
                           kind: .notice, seconds: 15))
    }

    /// Вода — раз в час активной работы, глаза — раз в 20 минут; перерыв сбрасывает счёт.
    private func checkReminders(_ now: Date, idle: TimeInterval) {
        if idle < 60 {
            waterActive += 1
            eyesActive += 1
        }
        if idle >= 5 * 60 { eyesActive = 0 }
        if idle >= 20 * 60 { waterActive = 0 }
        guard idle < 5 else { return }
        if watching("water") && waterActive >= 3600 {
            waterActive = remindWater() ? 0 : 3600 - 5 * 60  // не до того — через 5 минут
        }
        if watching("eyes") && eyesActive >= 20 * 60 {
            eyesActive = remindEyes() ? 0 : 20 * 60 - 60
        }
        let hour = Calendar.current.component(.hour, from: now)
        let day = PetCharacter.dayKey(now)
        if watching("summary"), (18..<23).contains(hour), (character.today?.activeSeconds ?? 0) >= 2 * 3600,
           defaults.string(forKey: "summaryDay") != day, !isQuiet, !inCall {
            defaults.set(day, forKey: "summaryDay")
            showSummary()
        }
    }

    @discardableResult
    private func remindWater(force: Bool = false) -> Bool {
        guard force || (!isQuiet && !inCall && panel.isVisible) else { return false }
        var speech = Speech(text: L("Попей воды"), detail: L("Час работы без глотка — самое время"), kind: .notice,
                            button: L("Отложить на 15 минут"), seconds: 12)
        speech.action = { [weak self] in self?.waterActive = 3600 - 15 * 60 }
        speaker.say(speech)
        return true
    }

    @discardableResult
    private func remindEyes(force: Bool = false) -> Bool {
        guard force || (!isQuiet && !inCall && panel.isVisible) else { return false }
        var speech = Speech(text: L("Посмотри вдаль"), detail: L("20 секунд на что-нибудь в 6 метрах — глазам отдых (20-20-20)"),
                            kind: .notice, button: L("Отложить на 5 минут"), seconds: 20)
        speech.action = { [weak self] in self?.eyesActive = 20 * 60 - 5 * 60 }
        speaker.say(speech)
        return true
    }

    private static func mmss(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }


    private static func format(_ pattern: String, _ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Lang.locale
        f.dateFormat = pattern
        return f.string(from: date).replacingOccurrences(of: ".", with: "")
    }

    // MARK: - Знакомство

    /// Бит вылетает снизу в центр экрана и машет; облачко «Привет! Я Бит» — по кнопке или через 5 секунд карточка.
    func startOnboarding() {
        guard onboarding == nil, onboardingState == nil else { return }
        quickMenu.close()
        speaker.hide()
        activity = nil
        onboardingHome = panel.frame.origin
        onboardingCardShown = false
        panel.orderFrontRegardless()
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let center = NSPoint(x: screen.midX - Self.size / 2, y: screen.midY - Self.size / 2 - 30)
        panel.setFrameOrigin(NSPoint(x: center.x, y: screen.minY - Self.size))
        onboardingState = .surprised  // летит
        updateState()
        flyBit(to: center, duration: 0.9) { [weak self] in
            guard let self else { return }
            self.onboardingState = .wave
            self.haptic(.levelChange)
            self.updateState()
            var hello = Speech(text: L("Привет! Я Бит"), detail: L("Давай познакомимся?"), kind: .meeting, button: L("Давай!"), seconds: 30)
            hello.action = { [weak self] in self?.showOnboardingCard() }
            self.speaker.say(hello)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                MainActor.assumeIsolated { self?.showOnboardingCard() }
            }
        }
    }

    /// Карточка знакомства по центру, Бит — у её левого нижнего угла: «рассказывает».
    private func showOnboardingCard() {
        guard !onboardingCardShown else { return }
        onboardingCardShown = true
        speaker.hide()
        let keys = ["meetings", "downloads", "typing", "talk", "water", "eyes", "summary", "music"]
        var values = Dictionary(uniqueKeysWithValues: keys.map { ($0, watching($0)) })
        values["autoCoffee"] = autoCoffee
        values["haptics"] = hapticsOn
        values["autoUpdate"] = updates.enabled
        let model = OnboardingModel(values: values, sleepMinutes: Int(sleepAfter / 60))
        model.onPage = { [weak self] page in self?.onboardingPage(page) }
        model.onToggle = { [weak self] key, on in self?.onboardingToggle(key, on) }
        model.onSleep = { [weak self] minutes in self?.sleepAfter = TimeInterval(minutes * 60) }
        model.onFinish = { [weak self] in self?.finishOnboarding() }
        model.permission = { [weak self] key in self?.permissionState(key) ?? .unknown }
        model.onIntegrate = { [weak self] in self?.connectAllIntegrations() }
        let window = OnboardingWindow(model: model)
        onboarding = window
        updateOnboardingIntegrations()
        window.show(on: (NSScreen.main ?? NSScreen.screens[0]).visibleFrame)
        let card = window.panel.frame
        flyBit(to: NSPoint(x: card.minX - Self.size + 22, y: card.minY - 12), duration: 0.6)
        onboardingPage(0)
    }

    /// На каждой странице Бит показывает, о чём она: гладят, работает с кофе, таймер, разговор, настройки.
    private func onboardingPage(_ page: Int) {
        let states: [PetState] = [.love, .work, .timer, .talk, .dance, .happy]
        onboardingState = states[min(page, states.count - 1)]
        view.setCoffee(page == 1 || coffee.isOn)
        updateState()
        if page == 2 { view.showScreenText("25:00", small: L("фокус · %@", "1"), progress: 1) }
        haptic(.alignment)
    }

    private func onboardingToggle(_ key: String, _ on: Bool) {
        switch key {
        case "autoCoffee":
            autoCoffee = on
        case "haptics":
            hapticsOn = on
        case "autoUpdate":
            updates.enabled = on
        default:
            if on { watched.insert(key) } else { watched.remove(key) }
            configureEvents(askTyping: key == "typing" && on)  // включили «Встречи», «Загрузки» или «Темп набора» — macOS спросит разрешение
        }
        updateState()
    }

    private func permissionState(_ key: String) -> OnboardingModel.Permission {
        switch key {
        case "meetings":
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .granted
            case .denied, .restricted, .writeOnly: return .denied
            default: return .unknown
            }
        case "typing":
            return AXIsProcessTrusted() ? .granted : .unknown
        case "downloads":
            return events.downloadsAccess.map { $0 ? .granted : .denied } ?? .unknown
        default:
            return .unknown
        }
    }

    /// Готово: карточка тает, Бит улетает на своё место и подсказывает про меню.
    private func finishOnboarding() {
        defaults.set(true, forKey: "onboarded")
        guard let window = onboarding else { return }
        window.close { [weak self] in
            guard let self else { return }
            self.onboarding = nil
            self.onboardingState = .happy
            self.view.setCoffee(self.coffee.isOn)
            self.updateState()
            let home = self.onboardingHome.flatMap { self.isOnScreen($0) ? $0 : nil } ?? self.defaultOrigin()
            self.flyBit(to: home, duration: 0.9) { [weak self] in
                guard let self else { return }
                self.onboardingState = nil
                self.savePosition()
                self.updateState()
                self.chat(L("Если что — нажми на меня двумя пальцами"), force: true)
            }
        }
    }

    /// Перелёт окна Бита с лёгким перелётом в конце; облачко летит следом.
    /// По умолчанию — с перелётом и пружинкой на месте.
    private func flyBit(to origin: NSPoint, duration: TimeInterval,
                        timing: CAMediaTimingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.2, 0.36, 1),
                        _ done: (@MainActor () -> Void)? = nil) {
        stopThrow()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = timing
            panel.animator().setFrame(NSRect(origin: origin, size: panel.frame.size), display: true)
        }, completionHandler: {
            MainActor.assumeIsolated { done?() }
        })
    }

    // MARK: - Быстрое меню

    /// Нажатие двумя пальцами на Бите: только самое нужное. Остальное — в окне «Настройки…».
    func showQuickMenu() {
        guard !quickMenu.isOpen, Date().timeIntervalSince(quickMenu.closedAt) > 0.3 else { return }
        stopThrow()
        lastInteraction = Date()
        held = held.filter { FileManager.default.fileExists(atPath: $0.path) }
        if held.isEmpty { setHeld([]) }
        let items = held.isEmpty ? quickItems() : heldItems()
        menuOpen = true
        speaker.suspend()
        view.showMenuMirror(items.map { ($0.title.count, $0.isOn) })
        haptic(.generic)
        let subtitle = character.summary.dropFirst().first ?? model.state.title
        let title = held.isEmpty ? L("Бит · %@", "\(PetCharacter.levels[character.level].title)")
            : L("Держу: %@", held.count == 1 ? held[0].lastPathComponent : L("файлов — %@", "\(held.count)"))
        quickMenu.show(title: title, subtitle: held.isEmpty ? subtitle : L("Утащи файл с меня в папку — перенесу"), items: items, near: panel.frame)
        updateState()
    }

    private func quickItems() -> [QuickItem] {
        var items = updateItems() + musicItems()
        items += [
            QuickItem(title: L("Поиграть"), symbol: "gamecontroller") { [unowned self] in
                self.lastInteraction = Date()
                self.startActivity()
            },
            QuickItem(title: countdown == nil ? L("Помодоро 25 мин") : L("Остановить таймер"), symbol: countdown == nil ? "timer" : "stop.circle") {
                [unowned self] in
                if self.countdown == nil { self.startCountdown(.focus, 25 * 60, offer: true) } else { self.stopCountdown() }
            },
            QuickItem(title: L("Убраться на столе"), symbol: "sparkles") { [unowned self] in self.tidyDesktop() },
        ]
        // Идущие команды терминала — прервать (с переспросом).
        for (i, job) in commands.running.prefix(3).enumerated() {
            let name = job.command.count > 26 ? String(job.command.prefix(25)) + "…" : job.command
            var it = QuickItem(title: L("Прервать: %@", "\(name)"), symbol: "stop.circle") { [unowned self] in self.askInterrupt(job) }
            it.separated = i == 0
            items.append(it)
        }
        var coffeeItem = QuickItem(title: L("Кофе-режим"), symbol: "cup.and.saucer", isOn: manualCoffee) { [unowned self] in
            self.setCoffee(!self.manualCoffee)
        }
        coffeeItem.separated = true
        items += [
            coffeeItem,
            QuickItem(title: L("Кофе на время работы"), symbol: "cup.and.heat.waves", isOn: autoCoffee) { [unowned self] in
                self.autoCoffee.toggle()
            },
            QuickItem(title: L("Серверы и приложения — не работа"), symbol: "server.rack", isOn: serversNotWork) { [unowned self] in
                self.serversNotWork.toggle()
                self.updateState()
            },
            QuickItem(title: L("Тихий час"), symbol: "moon.zzz", isOn: isQuiet) { [unowned self] in self.setQuiet(!self.isQuiet) }
        ]
        for accessory in character.seasonalWorn {
            items.append(QuickItem(title: L("Снять: %@", "\(accessory.title)"), symbol: "tshirt") { [unowned self] in
                self.character.toggleSeasonal(accessory)
                self.updateState()
            })
        }
        var corner = QuickItem(title: L("Вернуть в угол"), symbol: "arrow.down.right.square") { [unowned self] in self.resetPosition() }
        corner.separated = character.seasonalWorn.isEmpty
        items.append(corner)
        let hideTitle = hideMinutes > 0 ? L("Спрятать на %@", "\(Self.duration(TimeInterval(hideMinutes * 60)))") : L("Спрятать Бита")
        items.append(QuickItem(title: hideTitle, symbol: "eye.slash", separated: true) { [unowned self] in self.toggleVisible() })
        items.append(QuickItem(title: L("Настройки…"), symbol: "gearshape") { [unowned self] in self.showSettings() })
        return items
    }

    // MARK: - Музыка

    /// Пункты быстрого меню, пока плеер что-то держит: пауза или игра, следующий, предыдущий.
    private func musicItems() -> [QuickItem] {
        guard let track = music.track else { return [] }
        let name = [track.title, track.artist].compactMap { $0 }.joined(separator: " — ")
        let short = name.count > 28 ? String(name.prefix(27)) + "…" : name
        return [
            QuickItem(title: track.playing ? L("Пауза: %@", short) : L("Играть: %@", short),
                      symbol: track.playing ? "pause.fill" : "play.fill") { [unowned self] in self.musicCommand(.toggle) },
            QuickItem(title: L("Следующий трек"), symbol: "forward.fill") { [unowned self] in self.musicCommand(.next) },
            QuickItem(title: L("Предыдущий трек"), symbol: "backward.fill") { [unowned self] in self.musicCommand(.previous) },
        ]
    }

    private func musicCommand(_ command: MusicControl.Command) {
        guard let track = music.track else {
            if music.isAvailable {
                speaker.say(Speech(text: L("Музыка не играет"), detail: L("Включи плеер — дальше я сам"), kind: .notice, seconds: 3))
            }
            return
        }
        music.send(command)
        let glyph: String
        switch command {
        case .next: glyph = "▶▶"
        case .previous: glyph = "◀◀"
        default: glyph = track.playing ? "❚❚" : "▶"
        }
        musicFlash = (glyph, Date().addingTimeInterval(2.2))
        if command == .next || command == .previous { trackAnnounceUntil = Date().addingTimeInterval(4) }
        haptic(.levelChange)
        lastInteraction = Date()
        updateState()
    }

    /// Свайп двумя пальцами по трекпаду над Битом: влево — следующий трек, вправо — предыдущий. Инерция не считается.
    func scrolled(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        if event.phase == .began || event.phase == .mayBegin {
            swipe = .zero
            swipeFired = false
        }
        // В сторону пальцев: при «естественной» прокрутке знак по горизонтали совпадает с движением, иначе — обратный.
        let fingers = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        swipe.dx += fingers
        swipe.dy += abs(event.scrollingDeltaY)
        if !swipeFired, abs(swipe.dx) > 60, abs(swipe.dx) > swipe.dy * 1.5 {
            swipeFired = true
            if music.track != nil {
                musicCommand(swipe.dx < 0 ? .next : .previous)
            }
        }
        if event.phase == .ended || event.phase == .cancelled {
            swipe = .zero
        }
    }

    /// Сменился трек — сам или через Бита: облачко с названием и исполнителем, на экране — нота.
    /// Первый ответ помощника после запуска — не смена, о нём молчит; пауза и продолжение — тоже.
    private func musicChanged(from old: MusicControl.Track?, to new: MusicControl.Track?) {
        defer {
            musicSeeded = true
            updateState()
        }
        let mine = Date() < trackAnnounceUntil
        guard let new, let title = new.title, !title.isEmpty, musicSeeded || mine,
              title != old?.title || new.artist != old?.artist else { return }
        trackAnnounceUntil = .distantPast
        // Свой жест — всегда; сменилось само — если включена «Музыка», не тихий час и не звонок.
        guard mine || (watching("music") && !isQuiet && !inCall && panel.isVisible) else { return }
        var speech = Speech(text: title, detail: new.artist ?? new.app, kind: .notice, seconds: 4)
        speech.expires = Date().addingTimeInterval(30)  // отошли — про прошлые треки не рассказывает
        speaker.say(speech)
        if !mine { musicFlash = ("♪", Date().addingTimeInterval(3)) }
    }

    // MARK: - Файлы в руках

    /// Точка экрана в системе Бита 200x200 (y вниз).
    private func canvasPoint(_ p: NSPoint) -> CGPoint {
        let f = panel.frame
        return CGPoint(x: (p.x - f.minX) / f.width * 200, y: (f.maxY - p.y) / f.height * 200)
    }

    private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    func filesDragEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        // Свои файлы обратно на себя не ловит.
        guard (info.draggingSource as? BitLayerView) == nil, !droppedURLs(info).isEmpty else { return [] }
        if !catchingHover {
            catchingHover = true
            react(.surprised, for: 0.8)  // ой, мне?
            haptic(.alignment)
            updateState()
        }
        return .copy
    }

    func filesDragExited() {
        catchingHover = false
    }

    func filesDropped(_ info: NSDraggingInfo) -> Bool {
        catchingHover = false
        let urls = droppedURLs(info)
        guard !urls.isEmpty else { return false }
        catchFiles(urls)
        return true
    }

    private func catchFiles(_ urls: [URL]) {
        let fresh = urls.filter { url in FileManager.default.fileExists(atPath: url.path) && !held.contains(url) }
        guard !fresh.isEmpty else { return }
        setHeld(held + fresh)
        let phrase = [L("Держу!"), L("Поймал!"), L("Есть!"), L("Цап — держу!")].randomElement()!
        let detail = held.count == 1 ? held[0].lastPathComponent : L("В руках файлов: %@", "\(held.count)")
        speaker.say(Speech(text: phrase, detail: detail, kind: .notice, seconds: 4))
        react(.happy, for: 1.5)
        haptic(.levelChange)
        lastInteraction = Date()
        updateState()
    }

    /// Новый набор в руках: значок первого файла, число и запись в настройки.
    private func setHeld(_ urls: [URL], save: Bool = true) {
        held = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if save || held.count != urls.count { defaults.set(held.map(\.path), forKey: "heldFiles") }
        if let first = held.first {
            let icon = NSWorkspace.shared.icon(forFile: first.path)
            icon.size = NSSize(width: 128, height: 128)
            view.setHeld(icon, count: held.count)
        } else {
            view.setHeld(nil, count: 0)
        }
    }

    /// Меню, пока Бит держит файлы: куда положить, что сделать, отпустить.
    private func heldItems() -> [QuickItem] {
        let urls = held
        var items = [
            QuickItem(title: L("Положить на рабочий стол"), symbol: "menubar.dock.rectangle") { [unowned self] in
                self.putHeld(into: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0])
            },
            QuickItem(title: L("Положить в Загрузки"), symbol: "arrow.down.circle") { [unowned self] in
                self.putHeld(into: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
            },
            QuickItem(title: L("Положить в…"), symbol: "folder") { [unowned self] in self.chooseFolderForHeld() },
        ]
        if convertTask != nil {
            items.insert(QuickItem(title: L("Остановить конвертацию"), symbol: "stop.circle") { [unowned self] in
                self.convertTask?.cancel()
            }, at: 0)
        }
        if !Converters.options(for: urls, available: ConvertTools.available).isEmpty {
            var convert = QuickItem(title: L("Конвертировать в…"), symbol: "arrow.triangle.2.circlepath") { [unowned self] in
                // Карточка закрывается, следом раскрывается вторая — с форматами.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    MainActor.assumeIsolated { self?.showConvertMenu() }
                }
            }
            convert.separated = true
            items.append(convert)
        }
        let titles: [FileShelf.Action: (String, String)] = [
            .zip: (L("Сжать в ZIP"), "archivebox"), .unzip: (L("Распаковать"), "shippingbox.and.arrow.backward")
        ]
        for (i, action) in FileShelf.actions(for: urls).enumerated() {
            guard let (title, symbol) = titles[action] else { continue }
            var item = QuickItem(title: title, symbol: symbol) { [unowned self] in self.runHeld(action) }
            item.separated = i == 0 && items.last?.title != L("Конвертировать в…")
            items.append(item)
        }
        var open = QuickItem(title: L("Открыть"), symbol: "arrow.up.forward.app") {
            urls.forEach { NSWorkspace.shared.open($0) }
        }
        open.separated = true
        items += [
            open,
            QuickItem(title: L("Показать в Finder"), symbol: "magnifyingglass") { NSWorkspace.shared.activateFileViewerSelecting(urls) },
            QuickItem(title: L("Скопировать путь"), symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            },
            QuickItem(title: L("AirDrop"), symbol: "airplayaudio") {
                NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
            },
            QuickItem(title: L("В корзину…"), symbol: "trash") { [unowned self] in self.askTrashHeld() },
            QuickItem(title: L("Отпустить — пусть лежат, где лежали"), symbol: "hand.raised", separated: true) { [unowned self] in
                self.setHeld([])
                self.speaker.say(Speech(text: L("Отпустил"), detail: L("Файлы на своих местах"), kind: .notice, seconds: 3))
            },
        ]
        return items
    }

    /// Вторая карточка: во что можно превратить файлы и чем (справа — LibreOffice, Keynote, ffmpeg…; без подписи — сама macOS).
    private func showConvertMenu() {
        guard !held.isEmpty, !quickMenu.isOpen else { return }
        let options = Converters.options(for: held, available: ConvertTools.available)
        guard !options.isEmpty else { return }
        let items = options.map { option in
            QuickItem(title: option.title, symbol: option.symbol) { [unowned self] in self.runConvert(option) }
        }
        menuOpen = true
        speaker.suspend()
        view.showMenuMirror(items.map { ($0.title.count, $0.isOn) })
        haptic(.generic)
        let name = held.count == 1 ? held[0].lastPathComponent : L("файлов — %@", "\(held.count)")
        quickMenu.show(title: L("Во что превратить?"), subtitle: name, items: items, near: panel.frame)
        updateState()
    }

    /// Конвертация: на экране Бита — процент (если известен), результат ложится рядом с исходным и попадает в руки.
    private func runConvert(_ option: ConvertOption) {
        let urls = held
        guard !urls.isEmpty, convertTask == nil else { return }
        react(.work, for: 600)
        convertProgress = [.videoHEVC, .videoH264, .audioM4A].contains(option.job) && option.engine == .builtIn ? 0 : nil
        let who = option.engine == .builtIn ? "" : " · " + option.engine.title
        speaker.say(Speech(text: L("Колдую…"), detail: option.title.components(separatedBy: " · ")[0] + who, kind: .notice, seconds: 3))
        updateState()
        convertTask = Converters.run(option, on: urls, progress: { [weak self] value in
            self?.convertProgress = value
            self?.updateState()
        }, done: { [weak self] result in
            guard let self else { return }
            self.convertTask = nil
            self.convertProgress = nil
            self.reaction = nil
            switch result {
            case .success(let made):
                self.setHeld(made)
                self.react(.happy, for: 1.5)
                self.haptic(.levelChange)
                var speech = Speech(text: L("Готово — держу результат"),
                                    detail: made.count == 1 ? made[0].lastPathComponent : L("Файлов: %@", "\(made.count)"),
                                    kind: .notice, button: L("Показать"), seconds: 6)
                speech.action = { NSWorkspace.shared.activateFileViewerSelecting(made) }
                self.speaker.say(speech)
            case .failure(let error):
                self.react(.sad, for: 1.5)
                self.speaker.say(Speech(text: L("Не получилось"), detail: String(error.message.prefix(160)), kind: .notice, seconds: 8))
            }
            self.updateState()
        })
    }

    /// Положить всё, что держит, в папку: файлы переезжают туда.
    private func putHeld(into folder: URL) {
        var moved: [URL] = []
        var failed: [String] = []
        for url in held {
            do { moved.append(try FileShelf.move(url, into: folder)) } catch { failed.append(url.lastPathComponent) }
        }
        setHeld(held.filter { url in FileManager.default.fileExists(atPath: url.path) && failed.contains(url.lastPathComponent) })
        announcePut(moved, into: folder, failed: failed)
    }

    private func announcePut(_ moved: [URL], into folder: URL, failed: [String] = []) {
        if !moved.isEmpty {
            let detail = moved.count == 1 ? L("«%@» → %@", moved[0].lastPathComponent, FileManager.default.displayName(atPath: folder.path))
                : L("Файлов: %@ → %@", "\(moved.count)", FileManager.default.displayName(atPath: folder.path))
            var speech = Speech(text: L("Положил!"), detail: detail, kind: .notice, button: L("Показать"), seconds: 6)
            speech.action = { NSWorkspace.shared.activateFileViewerSelecting(moved) }
            speaker.say(speech)
            react(.happy, for: 1.4)
            haptic(.levelChange)
        }
        if !failed.isEmpty {
            speaker.say(Speech(text: L("Не получилось перенести"), detail: failed.joined(separator: ", "), kind: .notice, seconds: 8))
        }
        updateState()
    }

    private func chooseFolderForHeld() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("Положить сюда")
        panel.message = L("Куда положить файлы?")
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            MainActor.assumeIsolated { self?.putHeld(into: folder) }
        }
    }

    /// Архив, распаковка, конвертация: результат ложится рядом с исходным, и Бит берёт его в руки.
    private func runHeld(_ action: FileShelf.Action) {
        let urls = held
        guard !urls.isEmpty else { return }
        react(.work, for: 60)
        speaker.say(Speech(text: L("Колдую…"), kind: .notice, seconds: 2))
        updateState()
        FileShelf.run(action, on: urls) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let made):
                self.setHeld(made)
                self.react(.happy, for: 1.5)
                self.haptic(.levelChange)
                var speech = Speech(text: L("Готово — держу результат"),
                                    detail: made.count == 1 ? made[0].lastPathComponent : L("Файлов: %@", "\(made.count)"),
                                    kind: .notice, button: L("Показать"), seconds: 6)
                speech.action = { NSWorkspace.shared.activateFileViewerSelecting(made) }
                self.speaker.say(speech)
            case .failure(let error):
                self.react(.sad, for: 1.5)
                self.speaker.say(Speech(text: L("Не получилось"), detail: String(error.message.prefix(140)), kind: .notice, seconds: 8))
            }
            self.updateState()
        }
    }

    /// В корзину — только после переспроса в облачке; из корзины файлы можно вернуть.
    private func askTrashHeld() {
        let urls = held
        var speech = Speech(text: L("Выбросить в корзину?"),
                            detail: urls.count == 1 ? urls[0].lastPathComponent : L("Файлов: %@", "\(urls.count)"),
                            kind: .notice, button: L("В корзину"), seconds: 10)
        speech.action = { [weak self] in
            NSWorkspace.shared.recycle(urls) { _, error in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.setHeld(self.held.filter { !urls.contains($0) })
                    self.speaker.say(Speech(text: error == nil ? L("Выбросил") : L("Не получилось"),
                                            detail: error?.localizedDescription ?? L("Вернуть можно из Корзины"), kind: .notice, seconds: 5))
                }
            }
        }
        speaker.say(speech)
    }

    /// Тянут за файл: Finder скажет, в какую папку бросили, и Бит перенесёт туда каждый файл.
    private func beginHeldDrag(_ event: NSEvent) {
        let point = view.convert(event.locationInWindow, from: nil)
        heldPromises = held.map { url in
            let promise = HeldFilePromise(original: url)
            promise.onMoved = { [weak self] original, moved in self?.heldMoved(original, to: moved) }
            return promise
        }
        let items = heldPromises.enumerated().map { index, promise -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: promise.provider())
            let icon = NSWorkspace.shared.icon(forFile: promise.original.path)
            let size: CGFloat = 56
            let shift = CGFloat(min(index, 4)) * 6
            item.setDraggingFrame(NSRect(x: point.x - size / 2 + shift, y: point.y - size / 2 - shift, width: size, height: size), contents: icon)
            return item
        }
        view.setHeldLifted(true)
        haptic(.alignment)
        view.beginDraggingSession(with: items, event: event, source: self)
    }

    /// Файл переехал (или не смог): убрать из рук, сказать «Положил!» один раз на всю пачку.
    private func heldMoved(_ original: URL, to moved: URL?) {
        if let moved {
            movedBatch.append(moved)
            setHeld(held.filter { $0 != original })
        } else {
            speaker.say(Speech(text: L("Не получилось перенести"), detail: original.lastPathComponent, kind: .notice, seconds: 6))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.movedBatch.isEmpty else { return }
                let batch = self.movedBatch
                self.movedBatch = []
                self.announcePut(batch, into: batch[0].deletingLastPathComponent())
            }
        }
    }

    /// Тихий час на 60 минут: облачко убирается, фразы и уведомления не показываются, встречи — да.
    private func setQuiet(_ on: Bool) {
        quietUntil = on ? Date().addingTimeInterval(3600) : nil
        if on {
            speaker.hide()
            activity = nil
        }
        updateState()
    }

    private static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    // MARK: - Занятия

    /// Давно не играли, Бит бодрствует и свободен — берётся за книгу, игру или спорт. Закончил — итог.
    private func updateActivity(_ now: Date, idle: TimeInterval) {
        if let current = activity {
            if now >= current.until { finishActivity() }
            return
        }
        guard watching("hobby"), now >= nextActivity, now.timeIntervalSince(lastInteraction) >= 6 * 60,
              reaction == nil, forcedState == nil, !inCall, model.state == .idle else { return }
        startActivity()
    }

    private func startActivity(_ kind: PetState? = nil, seconds: TimeInterval? = nil) {
        // Устал — читает, иначе что угодно.
        let chosen = kind ?? (character.state.energy < 0.4 ? .reading : Self.hobbies.randomElement() ?? .reading)
        let range: ClosedRange<Double> = chosen == .reading ? 60...90 : chosen == .workout ? 20...30 : 30...60
        activity = (chosen, Date().addingTimeInterval(seconds ?? .random(in: range)))
        reaction = nil
        updateState()
    }

    private func finishActivity() {
        guard let finished = activity else { return }
        activity = nil
        nextActivity = Date().addingTimeInterval(.random(in: 480...900))
        switch finished.state {
        case .tetris, .racing, .boxing:
            let win = forcedOutcome ?? (Double.random(in: 0...1) < 0.55 + 0.05 * Double(character.level))
            character.hobbyResult(win: win)
            if win {
                react(.happy, for: 2.5)
                showTransient(.trophy, for: 3)
                chat([L("Я выиграл!"), L("Победа!"), L("Есть! Выиграл!")].randomElement()!)
            } else {
                react(.sad, for: 2.5)
                showTransient(.lost, for: 3)
                chat([L("Эх, проиграл…"), L("Не повезло. В другой раз!")].randomElement()!)
            }
        case .reading:
            react(.happy, for: 1.5)
            showTransient(.bookDone, for: 2.5)
            chat(L("Дочитал главу!"))
        case .workout:
            react(.happy, for: 1.5)
            showTransient(.workoutDone, for: 2.5)
            chat(L("Фух! Хорошая тренировка"))
        default:
            break
        }
        forcedOutcome = nil
        updateState()
    }

    // MARK: - Отладка

    private static let debugConditions: [(String, String)] = [
        ("offline", L("Нет сети")), ("vpnOff", L("VPN отключился")), ("batteryLow", L("Батарея садится")),
        ("charging", L("Подключили зарядку")), ("batteryFull", L("Батарея заряжена")), ("cpu", L("Нагрузка CPU")),
        ("disk", L("Мало места на диске")), ("call", L("Звонок")), ("hot", L("Перегрев")), ("memory", L("Нехватка памяти")),
        ("lowPower", L("Энергосбережение")), ("download", L("Большая загрузка по сети")), ("headphones", L("Наушники")),
        ("music", L("Играет музыка")), ("night", L("Ночь")), ("longWork", L("Долгая работа без перерыва"))
    ]

    private static func applyDebug(_ key: String, to s: inout SystemSnapshot) {
        switch key {
        case "offline": s.online = false
        case "batteryLow": s.batteryLevel = 15; s.onAC = false; s.charging = false
        case "charging": s.batteryLevel = s.batteryLevel ?? 80; s.onAC = true; s.charging = true
        case "batteryFull": s.batteryLevel = 100; s.onAC = true; s.charging = false
        case "cpu": s.cpuLoad = 0.95
        case "disk": s.diskTotalBytes = s.diskTotalBytes ?? 500_000_000_000; s.diskFreeBytes = 2_000_000_000
        case "call": s.micOn = true
        case "hot": s.thermalHot = true
        case "memory": s.memoryPressure = 2
        case "lowPower": s.lowPower = true
        case "download": s.rxRate = 12_000_000
        case "headphones": s.headphones = true
        case "music": s.soundPlaying = true
        default: break  // vpnOff, night, longWork — флаги контроллера
        }
    }

    private func debugging(_ key: String) -> Bool { (debugUntil[key] ?? .distantPast) > Date() }

    /// Подменить показание на 10 секунд — с теми же разовыми реакциями, что у настоящего события.
    private func simulate(_ key: String) {
        var old = snapshot
        if key == "charging" { old.onAC = false }
        if key == "batteryFull" { old.batteryLevel = 99 }
        if key == "vpnOff" { old.vpnInterface = "ppp0" }
        debugUntil[key] = Date().addingTimeInterval(10)
        systemChanged(from: old, to: snapshot)
    }

    private func expireDebug(_ now: Date) {
        for (key, until) in debugUntil where until <= now {
            var old = snapshot
            Self.applyDebug(key, to: &old)
            debugUntil[key] = nil
            if key == "vpnOff" { vpnLost = false }
            systemChanged(from: old, to: snapshot)
        }
    }

    private func debugMenu() -> NSMenu {
        debugActions = []
        let menu = NSMenu()
        func add(_ menu: NSMenu, _ title: String, _ action: @escaping () -> Void) {
            let it = item(title, #selector(runDebug(_:)))
            it.tag = debugActions.count
            debugActions.append(action)
            menu.addItem(it)
        }

        let system = NSMenu()
        for (key, title) in Self.debugConditions { add(system, title) { [unowned self] in self.simulate(key) } }
        menu.addItem(submenu(L("Система — на 10 секунд"), system))

        let events = NSMenu()
        add(events, L("Разблокировали экран")) { [unowned self] in self.handle(.unlocked, force: true) }
        add(events, L("Mac проснулся")) { [unowned self] in self.handle(.didWake, force: true) }
        add(events, L("Копирование")) { [unowned self] in self.handle(.clipboard, force: true) }
        add(events, L("Скриншот")) { [unowned self] in self.handle(.screenshot, force: true) }
        add(events, L("Загрузка файла завершилась")) { [unowned self] in self.handle(.downloadFinished, force: true) }
        add(events, L("Рывок курсора к Биту")) { [unowned self] in
            self.react(.surprised, for: 0.7)
            self.pendingFlinch = 1
        }
        add(events, L("Встряхнули курсор")) { [unowned self] in
            self.react(.surprised, for: 1)
            self.showTransient(.locate, for: 2)
        }
        add(events, L("Окно сдвинули на Бита")) { [unowned self] in
            let bit = self.silhouette()
            self.moveAside(from: CGRect(x: bit.maxX - 30, y: bit.minY - 50, width: 400, height: bit.height + 100))
        }
        add(events, L("Дай пять")) { [unowned self] in
            self.react(.happy, for: 1.4)
            self.showTransient(.highFive, for: 1.5)
        }
        events.addItem(.separator())
        add(events, L("Новый день")) { [unowned self] in self.handleCharacter(.newDay(late: false)) }
        add(events, L("Новый день после позднего вечера")) { [unowned self] in
            self.character.startSleepyCompany()
            self.handleCharacter(.newDay(late: true))
        }
        add(events, L("Вернулся с перерыва")) { [unowned self] in self.handleCharacter(.breakOver(minutes: 10)) }
        add(events, L("Новый уровень привязанности")) { [unowned self] in self.handleCharacter(.levelUp(self.character.level)) }
        add(events, L("Микродействие")) { [unowned self] in
            if let action = self.character.microAction(force: true) { self.react(action.state, for: action.seconds) }
        }
        menu.addItem(submenu(L("События"), events))

        let lines = NSMenu()
        for (key, title) in Self.debugLines { add(lines, title) { [unowned self] in self.sayDebug(key) } }
        menu.addItem(submenu(L("Реплики"), lines))

        let hobbies = NSMenu()
        for kind in Self.hobbies {
            if [PetState.tetris, .racing, .boxing].contains(kind) {
                for (suffix, win) in [(L("выиграет"), true), (L("проиграет"), false)] {
                    add(hobbies, "\(kind.title) — \(suffix)") { [unowned self] in
                        self.forcedOutcome = win
                        self.startActivity(kind, seconds: 8)
                    }
                }
            } else {
                add(hobbies, kind.title) { [unowned self] in self.startActivity(kind, seconds: 8) }
            }
        }
        menu.addItem(submenu(L("Занятия — на 8 секунд"), hobbies))

        let wardrobe = NSMenu()
        for accessory in Accessory.allCases {
            add(wardrobe, (debugAccessories.contains(accessory) ? "✓ " : "") + accessory.title) { [unowned self] in
                self.debugAccessories = self.debugAccessories.contains(accessory) ? [] : [accessory]
            }
        }
        menu.addItem(submenu(L("Примерить аксессуар"), wardrobe))

        menu.addItem(.separator())
        add(menu, L("Сбросить отладку")) { [unowned self] in
            for key in self.debugUntil.keys { self.debugUntil[key] = .distantPast }
            self.debugAccessories = []
            self.forcedOutcome = nil
            self.activity = nil
        }
        return menu
    }

    @objc private func runDebug(_ sender: NSMenuItem) {
        guard debugActions.indices.contains(sender.tag) else { return }
        debugActions[sender.tag]()
        updateState()
    }

    /// Резкий рост нагрузки: облачко с текущим значением и самым тяжёлым процессом, на экране — CPU, ОЗУ и диск.
    /// Переключатели — те же, что у значков: «Нагрузка CPU», «Нехватка памяти», «Место на диске».
    private func checkSpikes(_ s: SystemSnapshot) {
        let used = s.diskTotalBytes.flatMap { total in s.diskFreeBytes.map { Double(total - $0) } }
        let found = spikes.add(cpu: s.cpuLoad, memory: s.memoryUsed, diskUsedBytes: used, diskTotalBytes: s.diskTotalBytes.map(Double.init))
        guard let spike = found.first(where: { watching($0.kind.rawValue) }), !isQuiet, !inCall, panel.isVisible else { return }
        announceSpike(spike)
    }

    private func announceSpike(_ spike: LoadSpikes.Spike) {
        let percent = { (x: Double) in "\(Int((x * 100).rounded()))" }
        let bytes = { (x: Double) in ByteCountFormatter.string(fromByteCount: Int64(x), countStyle: .file) }
        let say = { [weak self] (text: String, detail: String) in
            guard let self else { return }
            self.speaker.say(Speech(text: text, detail: detail, kind: .notice, seconds: 10))
            self.haptic(.levelChange)
            // На экране — все три показателя, пока облачко висит.
            self.clockUntil = Date().addingTimeInterval(8)
            self.statsUntil = self.clockUntil
            self.updateState()
        }
        switch spike.kind {
        case .cpu:
            TopProcess.find(memory: false) { top in
                var detail = L("CPU %@ %%", percent(spike.now))
                if let top { detail += " · " + L("больше всех: %@ (%@ %%)", top.name, "\(Int(top.value.rounded()))") }
                say(L("Выросла нагрузка на процессор"), detail)
            }
        case .memory:
            TopProcess.find(memory: true) { top in
                var detail = L("ОЗУ занято %@ %%", percent(spike.now))
                if let top { detail += " · " + L("больше всех: %@ (%@)", top.name, bytes(top.value)) }
                say(L("Память почти занята"), detail)
            }
        case .disk:
            say(L("Место на диске быстро уходит"),
                L("−%@ за %@ мин · занято %@ %%", bytes(spike.now - spike.before), "\(spike.minutes)", percent(snapshot.diskUsed ?? 0)))
        }
    }

    private func statsRows() -> [(String, Double)] {
        let s = snapshot
        return [("CPU", s.cpuLoad), (L("ОЗУ"), s.memoryUsed), (L("ДИСК"), s.diskUsed ?? 0)]
    }

    /// Разовые реакции на перемены.
    private func systemChanged(from old: SystemSnapshot, to new: SystemSnapshot) {
        checkSpikes(new)
        if UserDefaults.standard.bool(forKey: "printSystem") {
            print(new.summary.joined(separator: " | "))
            fflush(stdout)
        }
        if watching("call") && !old.inCall && new.inCall {
            reaction = nil
            transient = nil
        }
        if watching("network") && old.online != new.online {
            react(new.online ? .happy : .sad, for: new.online ? 1.5 : 3)
            chat(new.online ? L("Интернет вернулся!") : L("Пропал интернет"), ignoreCooldown: true)
        }
        if old.vpnInterface != nil && new.vpnInterface == nil {
            vpnLost = true
            if watching("vpn") {
                react(.sad, for: 3)
                chat(L("VPN отключился"), ignoreCooldown: true)
            }
        } else if new.vpnInterface != nil && vpnLost {
            vpnLost = false
            if watching("vpn") { react(.happy, for: 1.5) }
        }
        if watching("battery") && new.batteryLevel != nil {
            if !old.onAC && new.onAC {
                react(.happy, for: 2)
                showTransient(.charging, for: 4)
            }
            if new.onAC && new.batteryLevel == 100 && old.batteryLevel != 100 {
                showTransient(.batteryFull, for: 8)
                chat(L("Батарея заряжена — можно отключить зарядку"))
            }
            if new.isBatteryLow && !old.isBatteryLow, let level = new.batteryLevel {
                chat(L("Батарея садится — подключи зарядку"), detail: L("Осталось %@%%", "\(level)"), ignoreCooldown: true)
            }
        }
        if watching("headphones") && !old.headphones && new.headphones { react(.happy, for: 1.5) }
        if watching("music") && !old.isMusic && new.isMusic { react(.happy, for: 1) }
        updateState()
    }

    /// Долгое состояние, пока причина не ушла. Сон при простое пользователя важнее.
    private func systemState() -> PetState? {
        let s = snapshot
        if inCall { return .shush }
        if watching("network") && !s.online { return .sad }
        if watching("thermal") && s.thermalHot { return .hot }
        if watching("memory") && s.memoryPressure >= 1 { return .dizzy }
        if externalWork { return .work }
        if watching("battery") && s.isBatteryLow { return .drowsy }
        if watching("character") && (character.isSleepyCompany || character.isTired) { return .drowsy }
        if watching("time") && isNight { return .drowsy }
        if watching("breaks") && isLongWork { return .drowsy }
        if watching("cpu") && s.isBusy { return .work }
        if watching("typing") && events.isTypingFast { return .work }
        if watching("music") && s.isMusic { return .dance }
        return nil
    }

    /// Самое важное, о чём стоит напомнить значком.
    private func currentBadge() -> PetBadge? {
        let s = snapshot
        if watching("network") && !s.online { return .offline }
        if watching("vpn") && vpnLost { return .vpnOff }
        if watching("thermal") && s.thermalHot { return .hot }
        if watching("memory") && s.memoryPressure >= 1 { return .memory }
        if watching("battery") && s.isBatteryLow { return .batteryLow }
        if watching("disk") && s.isDiskLow { return .diskFull }
        if watching("claude") {
            let now = Date()
            agentWaits = agentWaits.filter { $0.value.expires > now }
            if agentWaits.values.contains(where: { $0.badge == .claudeAsks }) { return .claudeAsks }
            if !agentWaits.isEmpty { return .claudeDone }
        }
        if watching("breaks") && isLongWork { return .stretch }
        if watching("time") && isNight { return .night }
        if watching("download") && s.isDownloading { return .downloading }
        if watching("music") && s.isMusic { return .music }
        return nil
    }

    private func updateLook(mouse: NSPoint, frame: NSRect) {
        let now = Date()
        var target = CGPoint.zero
        if model.state != .sleep {
            if mouse != lastMouse {
                lastMouse = mouse
                mouseStillSince = now
            }
            if now.timeIntervalSince(mouseStillSince) > 8 {
                // Курсор давно стоит — Бит сам поглядывает по сторонам.
                if now >= nextGlance {
                    glance = CGPoint(x: .random(in: -1...1), y: .random(in: -0.6...0.6))
                    nextGlance = now.addingTimeInterval(.random(in: 2...5))
                }
                target = glance
            } else {
                // Центр глаз — y = 98 в системе 200x200.
                let eyeX = frame.midX
                let eyeY = frame.maxY - frame.height * 98 / 200
                let dx = mouse.x - eyeX
                let dy = eyeY - mouse.y
                let dist = max(hypot(dx, dy), 1)
                let k = min(dist / 250, 1)
                target = CGPoint(x: dx / dist * k, y: dy / dist * k)
            }
        }
        let look = model.look
        let next = CGPoint(x: look.x + (target.x - look.x) * 0.25, y: look.y + (target.y - look.y) * 0.25)
        if abs(next.x - look.x) > 0.003 || abs(next.y - look.y) > 0.003 { model.look = next }
    }

    // MARK: - Меню (строка меню и правый клик)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        fill(menu)
    }

    /// Меню в строке меню — только то, чем пользуются каждый день. Всё остальное — в окне «Настройки…».
    private func fill(_ menu: NSMenu) {
        if let badge = model.badge {
            let it = NSMenuItem(title: "⚠︎ " + badge.title, action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
            menu.addItem(.separator())
        }
        let hideTitle: String
        if panel.isVisible {
            hideTitle = hideMinutes > 0 ? L("Спрятать на %@", "\(Self.duration(TimeInterval(hideMinutes * 60)))") : L("Спрятать Бита")
        } else if let hiddenUntil {
            hideTitle = L("Показать Бита (вернётся в %@)", "\(Self.clock(hiddenUntil))")
        } else {
            hideTitle = L("Показать Бита")
        }
        menu.addItem(item(hideTitle, #selector(toggleVisible)))
        menu.addItem(.separator())

        let timerMenu = NSMenu()
        if let c = countdown {
            let left = NSMenuItem(title: L("Осталось %@", "\(Self.mmss(max(0, c.end.timeIntervalSinceNow)))"), action: nil, keyEquivalent: "")
            left.isEnabled = false
            timerMenu.addItem(left)
            timerMenu.addItem(item(L("Остановить"), #selector(stopTimerItem)))
            timerMenu.addItem(.separator())
        }
        timerMenu.addItem(item(L("Помодоро: 25 минут работы, 5 отдыха"), #selector(startPomodoroItem)))
        for minutes in [5, 10, 15, 30, 45, 60] {
            let it = item("\(minutes) \(Lang.minutes(minutes))", #selector(startTimerItem(_:)))
            it.tag = minutes
            timerMenu.addItem(it)
        }
        menu.addItem(submenu(countdown == nil ? L("Таймер") : L("Таймер — идёт"), timerMenu))
        let quietItem = item(isQuiet ? L("Тихий час — до %@", "\(Self.clock(quietUntil!))") : L("Тихий час"), #selector(toggleQuietItem))
        quietItem.state = isQuiet ? .on : .off
        menu.addItem(quietItem)
        let coffeeItem = item(manualCoffee ? L("Кофе-режим — с %@", "\(Self.clock(coffee.since ?? Date()))") : L("Кофе-режим: Mac не засыпает"),
                              #selector(toggleCoffeeItem))
        coffeeItem.state = manualCoffee ? .on : .off
        menu.addItem(coffeeItem)
        let running = commands.running
        if !running.isEmpty {
            let jobsMenu = NSMenu()
            for job in running {
                let kind = job.longLived ? L(" (сервер или приложение)") : ""
                let it = item(L("Прервать: %@ · %@%@", "\(job.command)", "\(Self.duration(Date().timeIntervalSince(job.start)))", "\(kind)"),
                              #selector(interruptItem(_:)))
                it.tag = Int(job.pid)
                jobsMenu.addItem(it)
            }
            menu.addItem(submenu(L("Команды в терминале — %@", "\(running.count)"), jobsMenu))
        }
        menu.addItem(item(L("Убраться на столе"), #selector(tidyItem)))

        menu.addItem(.separator())
        if let title = updateMenuTitle {
            menu.addItem(item(title, #selector(updateItem)))
        }
        let settingsItem = item(L("Настройки…"), #selector(settingsItem))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Выйти"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: - Окно настроек

    /// Ключи переключателей окна сверх «реакций» (watched).
    private static let settingKeys: [String: String] = [
        "autoCoffee": L("Кофе на время работы Claude и команд"), "serversNotWork": L("Серверы и приложения в терминале — не работа"),
        "haptics": L("Тактильный отклик"), "autoDress": L("Одевается сам")
    ]

    func showSettings(section: Int? = nil) {
        quickMenu.close()
        let window: SettingsWindow
        if let settings {
            window = settings
        } else {
            let model = SettingsModel()
            model.titles = Dictionary(Self.watchTitles, uniquingKeysWith: { a, _ in a }).merging(Self.settingKeys) { a, _ in a }
            // В окне подписи короче, чем в старом меню: полные не влезали в две строки.
            model.titles["claude"] = L("ИИ-агенты: Claude, Cursor и другие")
            model.titles["serversNotWork"] = L("Серверы в терминале — не работа")
            model.titles["character"] = L("Микродействия и привычки")
            model.onToggle = { [weak self] key, on in self?.settingsToggle(key, on) }
            model.onSleep = { [weak self] minutes in self?.sleepAfter = TimeInterval(minutes * 60) }
            model.onHide = { [weak self] minutes in self?.hideMinutes = minutes }
            model.onCommand = { [weak self] seconds in self?.commandMinimum = TimeInterval(seconds) }
            model.onAccessory = { [weak self] raw in
                guard let self, let accessory = Accessory(rawValue: raw) else { return }
                self.character.toggle(accessory)
                self.lastInteraction = Date()
                self.react(.happy, for: 1.2)  // обновка!
                self.syncSettings()
                self.updateState()
            }
            model.onSeasonal = { [weak self] raw in
                guard let self, let accessory = Accessory(rawValue: raw) else { return }
                self.character.toggleSeasonal(accessory)
                self.syncSettings()
                self.updateState()
            }
            model.onAction = { [weak self] action in self?.settingsAction(action) }
            model.permission = { [weak self] key in self?.permissionState(key) ?? .unknown }
            model.refresh = { [weak self] in self?.syncSettings() }
            window = SettingsWindow(model: model)
            settings = window
        }
        if let section { window.model.section = section }
        syncSettings()
        window.show()
        react(.happy, for: 1)
        updateState()
    }

    /// Окно показывает текущие значения: их могли поменять быстрым меню или сам Бит (характер, показания Mac).
    private func syncSettings() {
        guard let model = settings?.model, settings?.isOpen == true || model.values.isEmpty else { return }
        var values = Dictionary(uniqueKeysWithValues: Self.watchTitles.map { ($0.0, watching($0.0)) })
        values["autoCoffee"] = autoCoffee
        values["serversNotWork"] = serversNotWork
        values["haptics"] = hapticsOn
        values["autoDress"] = character.state.autoDress
        if model.values != values { model.values = values }
        model.sleepMinutes = Int(sleepAfter / 60)
        model.hideMinutes = hideMinutes
        model.commandSeconds = Int(commandMinimum)
        model.statusLines = snapshot.summary
        model.characterLines = character.summary
        model.desktopCount = desktopLayout.count
        let found = ConvertTools.available
        model.converters = ConvertEngine.allCases.map {
            SettingsModel.Choice(id: $0.rawValue, title: $0.title, detail: $0.adds, enabled: true, on: found.contains($0))
        }
        model.integrations = Integration.allCases.map(integrationRow)
        model.values["autoUpdate"] = updates.enabled
        model.updateText = L("Версия %@", AppVersion.current?.text ?? "?") + (updates.state.text.isEmpty ? "" : " · " + updates.state.text)
        switch updates.state {
        case .ready: model.updateButton = L("Обновить")
        case .manual: model.updateButton = L("Скачать")
        case .checking, .downloading, .installing: model.updateButton = nil
        default: model.updateButton = L("Проверить")
        }
        model.installHints = Dictionary(uniqueKeysWithValues: ConvertEngine.allCases.compactMap { e in e.install.map { (e.rawValue, $0) } })
        model.accessories = Accessory.allCases.compactMap { accessory in
            guard let unlock = accessory.unlockLevel else { return nil }
            let open = character.isUnlocked(accessory)
            return SettingsModel.Choice(id: accessory.rawValue, title: accessory.title,
                                        detail: open ? nil : L("с уровня «%@»", "\(PetCharacter.levels[unlock].title)"),
                                        enabled: open, on: character.state.chosen.contains(accessory))
        }
        model.seasonal = [Accessory.pumpkin, .santa, .party].map { accessory in
            let season = (accessory.season ?? "") + (character.inSeason(accessory) ? L(" — сейчас сезон") : "")
            return SettingsModel.Choice(id: accessory.rawValue, title: accessory.title, detail: season, enabled: true,
                                        on: !character.state.seasonalOff.contains(accessory))
        }
    }

    // MARK: - Обновления

    /// Новая версия скачана и проверена — облачко с кнопкой; копия подписана локально — ссылка на релиз.
    private func announceUpdate(_ state: UpdateState) {
        var speech: Speech
        switch state {
        case let .ready(release, _):
            speech = Speech(text: L("Вышла MyPetBit %@", release.version.text), detail: L("Скачал и проверил — обновлюсь за пару секунд"),
                            kind: .notice, button: L("Обновить"), seconds: 20)
        case let .manual(release):
            speech = Speech(text: L("Вышла MyPetBit %@", release.version.text), detail: L("Эту копию обновить сам не могу — скачай образ"),
                            kind: .notice, button: L("Скачать"), seconds: 20)
        default:
            return
        }
        speech.action = { [weak self] in self?.runUpdate() }
        speaker.say(speech)
        react(.happy, for: 1.5)
    }

    private func runUpdate() {
        switch updates.state {
        case .ready:
            speaker.say(Speech(text: L("Обновляюсь…"), detail: L("Сейчас вернусь"), kind: .notice, seconds: 3))
            updates.install()
        case let .manual(release):
            NSWorkspace.shared.open(release.pageURL ?? UpdateService.releasesPage)
        default:
            updates.check(manual: true)
        }
    }

    private var updateMenuTitle: String? {
        switch updates.state {
        case let .ready(release, _): return L("Обновить до %@", release.version.text)
        case let .manual(release): return L("Скачать MyPetBit %@…", release.version.text)
        default: return nil
        }
    }

    private func updateItems() -> [QuickItem] {
        guard let title = updateMenuTitle else { return [] }
        return [QuickItem(title: title, symbol: "arrow.down.circle") { [unowned self] in self.runUpdate() }]
    }

    // MARK: - Интеграции

    private func integrationRow(_ integration: Integration) -> SettingsModel.IntegrationRow {
        let state = Bundle.main.bundlePath.hasSuffix(".app") ? integrations.state(integration) : .missing
        let (status, tone, action, key): (String, Int, String?, String?)
        switch state {
        case .missing: (status, tone, action, key) = (L("не установлен"), 0, nil, nil)
        case .off: (status, tone, action, key) = (L("не подключён"), 0, L("Подключить"), "connect")
        case .on: (status, tone, action, key) = (L("подключён"), 1, L("Отключить"), "disconnect")
        case .other: (status, tone, action, key) = (L("к другой копии Бита"), 2, L("Подключить сюда"), "connect")
        case .broken: (status, tone, action, key) = (L("путь устарел"), 2, L("Починить"), "connect")
        case .blocked: (status, tone, action, key) = (L("notify занят"), 2, nil, nil)
        }
        return SettingsModel.IntegrationRow(id: integration.rawValue, title: integration.title, file: "~/" + integration.file,
                                            status: status, tone: tone, action: action, actionKey: key)
    }

    private func integrationAction(_ action: String, _ integration: Integration) {
        do {
            if action == "disconnect" {
                try integrations.disconnect(integration)
                speaker.say(Speech(text: L("Отключил %@", integration.title), detail: L("Мои хуки убраны, остальное не тронуто"), kind: .notice, seconds: 4))
            } else {
                try integrations.connect(integration)
                speaker.say(Speech(text: L("Подключил %@", integration.title), detail: L("Подхватится при следующем запуске"), kind: .notice, seconds: 4))
                react(.happy, for: 1.2)
            }
        } catch {
            speaker.say(Speech(text: L("Не получилось"), detail: error.localizedDescription, kind: .notice, seconds: 8))
        }
        syncSettings()
    }

    /// Всё установленное и ещё не подключённое (или подключённое к другой копии, со сломанным путём).
    @discardableResult
    private func connectAllIntegrations() -> [Integration] {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return [] }
        var done: [Integration] = []
        var failed: [String] = []
        for integration in Integration.allCases where [.off, .other, .broken].contains(integrations.state(integration)) {
            do {
                try integrations.connect(integration)
                done.append(integration)
            } catch {
                failed.append("\(integration.title): \(error.localizedDescription)")
            }
        }
        if !done.isEmpty {
            speaker.say(Speech(text: L("Подключился"), detail: done.map(\.title).joined(separator: ", "), kind: .notice, seconds: 6))
            react(.happy, for: 1.5)
        } else if failed.isEmpty {
            speaker.say(Speech(text: L("Всё уже подключено"), kind: .notice, seconds: 3))
        }
        if !failed.isEmpty {
            speaker.say(Speech(text: L("Не получилось"), detail: failed.joined(separator: "; "), kind: .notice, seconds: 8))
        }
        syncSettings()
        updateOnboardingIntegrations()
        return done
    }

    private func updateOnboardingIntegrations() {
        guard let model = onboarding?.model else { return }
        let inBundle = Bundle.main.bundlePath.hasSuffix(".app")
        let states = Integration.allCases.map { ($0, inBundle ? integrations.state($0) : .missing) }
        let found = states.filter { $0.1 != .missing }.map(\.0.title)
        model.integrationsFound = found.isEmpty ? L("Агентов не нашёл — подключу позже в настройках")
            : L("Нашёл: %@", found.joined(separator: ", "))
        model.integrationsDone = !found.isEmpty && !states.contains { [.off, .other, .broken].contains($0.1) }
    }

    private func settingsToggle(_ key: String, _ on: Bool) {
        switch key {
        case "autoCoffee":
            autoCoffee = on
        case "serversNotWork":
            serversNotWork = on
        case "autoUpdate":
            updates.enabled = on
            if on { updates.check(manual: false) }
        case "haptics":
            hapticsOn = on
            if on { haptic(.levelChange) }  // включили — сразу чувствуется
        case "autoDress":
            if character.state.autoDress != on { character.toggleAutoDress() }
        default:
            if on { watched.insert(key) } else { watched.remove(key) }
            // «Встречи», «Загрузки», «Темп набора» спросят разрешение macOS; агенты и команды — запустить или остановить слежение.
            if Self.optIn.contains(key) || key == "commands" || key == "claude" { configureEvents(askTyping: key == "typing" && on) }
        }
        updateState()
    }

    private func settingsAction(_ action: String) {
        switch action {
        case "close": settings?.close()
        case "tidy": tidyDesktop()
        case "remember": rememberDesktop()
        case "forget": forgetDesktop()
        case "corner": resetPosition()
        case "summary": showSummary(force: true)
        case "onboarding":
            settings?.close()
            startOnboarding()
        case "states":
            let menu = NSMenu()
            let auto = item(L("Сам по себе"), #selector(pickState(_:)))
            auto.tag = -1
            auto.state = forcedState == nil ? .on : .off
            menu.addItem(auto)
            menu.addItem(.separator())
            for (index, state) in PetState.allCases.enumerated() {
                let it = item(state.title, #selector(pickState(_:)))
                it.tag = index
                it.state = forcedState == state ? .on : .off
                menu.addItem(it)
            }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        case "debug":
            debugMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        case "rescan":
            ConvertTools.refresh()
        case "update":
            runUpdate()
        case "integrations:all":
            connectAllIntegrations()
        case let raw where raw.hasPrefix("integration:"):
            let parts = raw.split(separator: ":").map(String.init)
            if parts.count == 3, let integration = Integration(rawValue: parts[2]) { integrationAction(parts[1], integration) }
        case let copy where copy.hasPrefix("copy:"):
            if let engine = ConvertEngine(rawValue: String(copy.dropFirst(5))), let command = engine.install {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                speaker.say(Speech(text: L("Скопировал команду"), detail: command + L(" — вставь в Терминал"), kind: .notice, seconds: 6))
            }
        default:
            break
        }
        syncSettings()
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        return it
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = menu
        return it
    }

    @objc private func toggleVisible() {
        if panel.isVisible { hideBit() } else { showBit() }
    }

    /// Машет и улетает за верхний край экрана; через выбранное время (или по «Показать») прилетает на своё место.
    private func hideBit() {
        guard panel.isVisible, !flying else { return }
        quickMenu.close()
        timerCard.close()
        speaker.hide()
        stopThrow()
        flying = true
        let home = panel.frame.origin
        hideHome = home
        hideTimer?.invalidate()
        hideTimer = nil
        hiddenUntil = nil
        if hideMinutes > 0 {
            let until = Date().addingTimeInterval(TimeInterval(hideMinutes * 60))
            hiddenUntil = until
            let t = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.showBit() }
            }
            RunLoop.main.add(t, forMode: .common)
            hideTimer = t
        }
        react(.wave, for: 1.2)
        updateState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Чуть приседает и взлетает.
                self.flyBit(to: NSPoint(x: home.x, y: self.skyY(above: home)), duration: 0.6,
                            timing: CAMediaTimingFunction(controlPoints: 0.55, -0.3, 0.85, 0.55)) {
                    self.panel.orderOut(nil)
                    self.panel.setFrameOrigin(home)
                    self.flying = false
                }
            }
        }
    }

    private func showBit() {
        hideTimer?.invalidate()
        hideTimer = nil
        hiddenUntil = nil
        if flying {
            // Ещё улетает — вернётся сразу, как скроется.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                MainActor.assumeIsolated { self?.showBit() }
            }
            return
        }
        guard !panel.isVisible else { return }
        let home = hideHome.flatMap { isOnScreen($0) ? $0 : nil } ?? restoredOrigin()
        flying = true
        panel.setFrameOrigin(NSPoint(x: home.x, y: skyY(above: home)))
        panel.orderFrontRegardless()
        react(.surprised, for: 1)
        updateState()
        flyBit(to: home, duration: 0.85) { [weak self] in
            guard let self else { return }
            self.flying = false
            self.react(.happy, for: 1.6)
            self.haptic(.levelChange)
            self.updateState()
        }
    }

    /// Высота над верхним краем экрана, где стоит Бит, — оттуда он прилетает и туда улетает.
    private func skyY(above origin: NSPoint) -> CGFloat {
        let center = NSPoint(x: origin.x + Self.size / 2, y: origin.y + Self.size / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]
        return screen.frame.maxY + 12
    }

    // MARK: - Порядок на рабочем столе

    /// Запомненная расстановка: имя значка → место в координатах Finder.
    private var desktopLayout: [String: CGPoint] {
        get {
            let raw = defaults.dictionary(forKey: "desktopLayout") as? [String: [Double]] ?? [:]
            return raw.compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        }
        set { defaults.set(newValue.mapValues { [Double($0.x), Double($0.y)] }, forKey: "desktopLayout") }
    }

    /// Навести порядок: запомненные значки — на свои места, остальные — по сетке от правого верхнего угла.
    private func tidyDesktop() {
        guard !tidying else { return }
        tidying = true
        react(.work, for: 30)
        updateState()
        speaker.say(Speech(text: L("Навожу порядок…"), kind: .notice, seconds: 3))
        DesktopTidy.read { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let failure):
                self.tidyFailed(failure)
            case .success(let icons):
                // Главный экран (с строкой меню) — первый; Finder считает от его левого верхнего угла, ось y вниз.
                let main = NSScreen.screens[0]
                let area = CGSize(width: main.visibleFrame.maxX - main.frame.minX, height: main.frame.maxY - main.visibleFrame.minY)
                let top = main.frame.maxY - main.visibleFrame.maxY + 6
                let remembered = self.desktopLayout
                let grid = DesktopTidy.finderGrid
                let places = DesktopTidy.layout(icons, remembered: remembered, screen: area, cell: grid.cell, icon: grid.icon, top: top,
                                                avoid: DesktopTidy.widgetFrames())
                let current = Dictionary(icons.map { ($0.name, $0.position) }, uniquingKeysWith: { a, _ in a })
                let moves = places.filter { name, p in current[name].map { hypot($0.x - p.x, $0.y - p.y) > 2 } ?? false }
                guard !moves.isEmpty else {
                    self.tidyDone(icons.isEmpty ? L("На столе пусто — убирать нечего") : L("Тут и так порядок"), moved: nil, offerRemember: false)
                    return
                }
                DesktopTidy.apply(moves) { [weak self] result in
                    switch result {
                    case .failure(let failure): self?.tidyFailed(failure)
                    case .success(let n): self?.tidyDone(L("Готово, порядок!"), moved: n, offerRemember: remembered.isEmpty)
                    }
                }
            }
        }
    }

    private func tidyDone(_ text: String, moved: Int?, offerRemember: Bool) {
        tidying = false
        react(.happy, for: 2)
        var speech = Speech(text: text, detail: moved.map { L("Переставил значков: %@", "\($0)") }, kind: .notice, seconds: 8)
        if offerRemember {
            speech.button = L("Запомнить так")
            speech.action = { [weak self] in self?.rememberDesktop() }
        }
        speaker.say(speech)
        updateState()
    }

    /// Запомнить, где сейчас стоят значки: дальше «Навести порядок» расставит их так же.
    private func rememberDesktop() {
        DesktopTidy.read { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let failure):
                self.tidyFailed(failure)
            case .success(let icons):
                self.desktopLayout = Dictionary(icons.map { ($0.name, $0.position) }, uniquingKeysWith: { a, _ in a })
                self.react(.happy, for: 1.5)
                self.speaker.say(Speech(text: L("Запомнил!"), detail: L("Значков: %@ — дальше расставлю так же", "\(icons.count)"),
                                        kind: .notice, seconds: 6))
                self.updateState()
            }
        }
    }

    private func tidyFailed(_ failure: DesktopTidy.Failure) {
        tidying = false
        react(.sad, for: 1.5)
        var speech: Speech
        switch failure {
        case .notAllowed:
            speech = Speech(text: L("Нужно разрешение"), detail: L("Разреши Биту управлять Finder: Конфиденциальность и безопасность → Автоматизация"),
                            kind: .notice, button: L("Открыть настройки"), seconds: 15)
            speech.action = {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
            }
        case .stacks:
            speech = Speech(text: L("На столе включены стопки"), detail: L("Выключи их (Вид → Использовать стопки) — и я расставлю значки"),
                            kind: .notice, seconds: 10)
        case .other(let message):
            speech = Speech(text: L("Не получилось навести порядок"), detail: String(message.prefix(120)), kind: .notice, seconds: 8)
        }
        speaker.say(speech)
        updateState()
    }

    private func resetPosition() {
        stopThrow()
        panel.setFrameOrigin(defaultOrigin())
        savePosition()
        react(.happy, for: 1.4)
    }

    @objc private func toggleQuietItem() { setQuiet(!isQuiet) }
    @objc private func toggleCoffeeItem() { setCoffee(!manualCoffee) }
    @objc private func settingsItem() { showSettings() }
    @objc private func updateItem() { runUpdate() }
    @objc private func interruptItem(_ sender: NSMenuItem) {
        if let job = commands.running.first(where: { $0.pid == pid_t(sender.tag) }) { askInterrupt(job) }
    }
    @objc private func stopTimerItem() { stopCountdown() }
    @objc private func startPomodoroItem() { startCountdown(.focus, 25 * 60, offer: true) }
    @objc private func startTimerItem(_ sender: NSMenuItem) { startCountdown(.plain, TimeInterval(sender.tag * 60), offer: true) }
    @objc private func tidyItem() { tidyDesktop() }
    private func forgetDesktop() {
        desktopLayout = [:]
        speaker.say(Speech(text: L("Забыл расстановку"), detail: L("Буду расставлять по сетке, как Finder"), kind: .notice, seconds: 5))
    }

    @objc private func pickState(_ sender: NSMenuItem) {
        forcedState = sender.tag < 0 ? nil : PetState.allCases[sender.tag]
        reaction = nil
        updateState()
    }
}

extension PetController: NSDraggingSource {
    /// Файлы из рук Бита — только в другие приложения (Finder); на самого Бита обратно не бросить.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        view.setHeldLifted(false)
        if operation == [] && !held.isEmpty {
            react(.surprised, for: 0.6)  // не взяли — файлы снова в руках
        }
    }
}

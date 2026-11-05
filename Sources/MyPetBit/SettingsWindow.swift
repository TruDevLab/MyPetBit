import AppKit
import SwiftUI

/// Состояние окна настроек. Значения заполняет контроллер (`syncSettings`), изменения уходят обратными вызовами.
/// Своё `ObservableObject`, а не `@State`: под Command Line Tools макросов SwiftUI нет.
@MainActor
final class SettingsModel: ObservableObject {
    struct Choice: Identifiable {
        let id: String
        let title: String
        let detail: String?
        let enabled: Bool
        let on: Bool
    }

    @Published var section = 0
    @Published var values: [String: Bool] = [:]
    @Published var titles: [String: String] = [:]
    @Published var sleepMinutes = 5
    @Published var hideMinutes = 0
    @Published var commandSeconds = 30
    @Published var statusLines: [String] = []
    @Published var characterLines: [String] = []
    @Published var accessories: [Choice] = []
    @Published var seasonal: [Choice] = []
    @Published var desktopCount = 0
    /// Конвертеры: id — ConvertEngine, on — найден, detail — что добавляет, title — название.
    @Published var converters: [Choice] = []
    /// Интеграции: статус и кнопка у каждого агента и у zsh.
    struct IntegrationRow: Identifiable {
        let id: String
        let title: String
        let file: String
        let status: String
        /// 0 — серый, 1 — бирюзовый (подключено), 2 — жёлтый (нужно внимание).
        let tone: Int
        let action: String?
        let actionKey: String?
    }
    @Published var integrations: [IntegrationRow] = []
    /// Обновления: «Версия 1.0.0 · Версия последняя» и кнопка (nil — идёт работа).
    @Published var updateText = ""
    @Published var updateButton: String?
    @Published var installHints: [String: String] = [:]
    /// Раз в секунду: показания Mac и разрешения могли измениться.
    @Published var tick = 0
    @Published var appeared = false

    var onToggle: ((String, Bool) -> Void)?
    var onSleep: ((Int) -> Void)?
    var onHide: ((Int) -> Void)?
    var onCommand: ((Int) -> Void)?
    var onAccessory: ((String) -> Void)?
    var onSeasonal: ((String) -> Void)?
    /// Кнопки: tidy, remember, forget, corner, summary, onboarding, states, debug, close.
    var onAction: ((String) -> Void)?
    var permission: ((String) -> OnboardingModel.Permission)?
    var refresh: (() -> Void)?

    func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { self.values[key] ?? false },
                set: { on in
                    self.values[key] = on
                    self.onToggle?(key, on)
                })
    }

    func select(_ index: Int) {
        guard index != section else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { section = index }
    }
}

final class SettingsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Окно настроек в стиле знакомства: тёмная карточка, слева разделы. Двигается за любое пустое место.
@MainActor
final class SettingsWindow {
    static let size = NSSize(width: 780, height: 560)
    let panel: SettingsPanel
    let model: SettingsModel
    var isOpen: Bool { panel.isVisible }

    init(model: SettingsModel) {
        self.model = model
        panel = SettingsPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .normal
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.contentView = NSHostingView(rootView: SettingsView(model: model))
    }

    func show() {
        if !panel.isVisible {
            let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            panel.setFrameOrigin(NSPoint(x: screen.midX - Self.size.width / 2, y: screen.midY - Self.size.height / 2))
            panel.alphaValue = 0
            model.appeared = false
        }
        // У приложения без Dock makeKeyAndOrderFront, пока активно другое, окно не показывает — выводим явно.
        panel.orderFrontRegardless()
        NSApp.activate()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 1
        }, completionHandler: {
            MainActor.assumeIsolated { self.panel.alphaValue = 1 }
        })
    }

    func close() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { self.panel.orderOut(nil) }
        })
    }
}

// MARK: - Вид

private struct Section {
    let symbol: String
    let title: String
    let subtitle: String
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let sections = [
        Section(symbol: "face.smiling", title: L("Бит"), subtitle: L("Как я себя веду")),
        Section(symbol: "antenna.radiowaves.left.and.right", title: L("Реакции"), subtitle: L("Что я замечаю в твоём Mac")),
        Section(symbol: "hammer", title: L("Работа"), subtitle: L("ИИ-агенты, команды, кофе")),
        Section(symbol: "link", title: L("Интеграции"), subtitle: L("Хуки в ИИ-агентах и терминале")),
        Section(symbol: "figure.walk", title: L("Ритм"), subtitle: L("Перерывы, вода, глаза, итог дня")),
        Section(symbol: "lock.shield", title: L("Разрешения"), subtitle: L("Что спросит macOS")),
        Section(symbol: "square.grid.3x3", title: L("Рабочий стол"), subtitle: L("Порядок на столе")),
        Section(symbol: "arrow.triangle.2.circlepath", title: L("Конвертеры"), subtitle: L("Чем я превращаю файлы")),
        Section(symbol: "heart", title: L("Характер"), subtitle: L("Дружба, настроение, аксессуары")),
        Section(symbol: "gauge.with.dots.needle.33percent", title: L("Mac сейчас"), subtitle: L("Что я вижу прямо сейчас")),
        Section(symbol: "wrench.and.screwdriver", title: L("Разработчикам"), subtitle: L("Демо и отладка"))
    ]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Palette.glow.opacity(0.18)).frame(width: 1)
            ScrollView {
                content
                    .padding(26)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .id(model.section)
                    .transition(.opacity.combined(with: .offset(x: 12)))
            }
            .scrollIndicators(.never)
        }
        .frame(width: SettingsWindow.size.width, height: SettingsWindow.size.height)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Palette.ink)
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Palette.glow.opacity(0.45), lineWidth: 1))
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button {
                model.onAction?("close")
            } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.dim)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("w", modifiers: .command)
            .padding(14)
        }
        .scaleEffect(model.appeared ? 1 : 0.94)
        .opacity(model.appeared ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { model.appeared = true } }
        .onChange(of: model.appeared) {
            if !model.appeared { withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { model.appeared = true } }
        }
        .onReceive(timer) { _ in
            model.tick += 1
            model.refresh?()
        }
        .onExitCommand { model.onAction?("close") }
        .font(.system(size: 13, design: .rounded))
        .foregroundStyle(Palette.text)
        .tint(Palette.glow)
        .focusEffectDisabled()
    }

    // MARK: Разделы слева

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape.fill").font(.system(size: 16)).foregroundStyle(Palette.glow)
                Text(L("Настройки")).font(.system(size: 20, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                let on = index == model.section
                HStack(spacing: 10) {
                    Image(systemName: section.symbol).font(.system(size: 13, weight: .medium)).frame(width: 20)
                        .foregroundStyle(on ? Palette.glow : Palette.dim)
                    Text(section.title).font(.system(size: 13, weight: on ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(on ? Palette.text : Palette.text.opacity(0.8))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Palette.glow.opacity(0.14) : Color.clear))
                .contentShape(Rectangle())
                .onTapGesture { model.select(index) }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .frame(width: 210)
        .background(Color.black.opacity(0.12))
    }

    // MARK: Содержимое

    @ViewBuilder
    private var content: some View {
        let section = sections[model.section]
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(section.title).font(.system(size: 24, weight: .bold, design: .rounded))
                Text(section.subtitle).foregroundStyle(Palette.glow.opacity(0.85))
            }
            switch model.section {
            case 0: bit
            case 1: reactions
            case 2: work
            case 3: integrations
            case 4: rhythm
            case 5: permissions
            case 6: desktop
            case 7: converters
            case 8: character
            case 9: mac
            default: developer
            }
        }
    }

    private var bit: some View {
        VStack(alignment: .leading, spacing: 12) {
            chips("moon.zzz", L("Засыпать при простое"),
                  [(1, L("1 мин")), (5, L("5 мин")), (15, L("15 мин")), (0, L("никогда"))], model.sleepMinutes) { value in
                model.sleepMinutes = value
                model.onSleep?(value)
            }
            chips("eye.slash", L("Прятать на"),
                  [(10, L("10 мин")), (30, L("30 мин")), (60, L("1 ч")), (120, L("2 ч")), (0, L("пока не верну"))], model.hideMinutes) { value in
                model.hideMinutes = value
                model.onHide?(value)
            }
            grid([("talk", "text.bubble"), ("hobby", "gamecontroller"), ("character", "sparkles"), ("haptics", "hand.tap"),
                  ("cursor", "cursorarrow.motionlines"), ("windows", "macwindow.on.rectangle")])
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.glow).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Проверять обновления на GitHub")).font(.system(size: 12.5, weight: .medium, design: .rounded))
                    Text(model.updateText).font(.system(size: 11, design: .rounded)).foregroundStyle(Palette.dim)
                }
                Spacer(minLength: 4)
                if let button = model.updateButton {
                    Button(button) { model.onAction?("update") }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.glow)
                }
                Toggle("", isOn: model.binding("autoUpdate")).toggleStyle(BitToggle()).labelsHidden()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
            note(L("Музыка: зажми меня на полсекунды — пауза или игра; смахни двумя пальцами влево — следующий трек, вправо — предыдущий. Работает с Музыкой, Spotify, Яндекс Музыкой и браузером."))
            HStack(spacing: 10) {
                Button(L("Вернуть в угол")) { model.onAction?("corner") }.buttonStyle(BitButton(primary: false))
                Button(L("Знакомство…")) { model.onAction?("onboarding") }.buttonStyle(BitButton(primary: false))
            }
            .padding(.top, 4)
        }
    }

    private var reactions: some View {
        grid([("battery", "battery.75percent"), ("cpu", "cpu"), ("network", "wifi"), ("vpn", "lock.shield"),
              ("disk", "internaldrive"), ("call", "video"), ("lock", "lock"), ("thermal", "thermometer.medium"),
              ("memory", "memorychip"), ("lowPower", "leaf"), ("download", "arrow.down.circle"), ("headphones", "headphones"),
              ("music", "music.note"), ("clipboard", "doc.on.clipboard"), ("screenshots", "camera.viewfinder"), ("time", "clock")])
    }

    private var work: some View {
        VStack(alignment: .leading, spacing: 12) {
            grid([("claude", "sparkles"), ("commands", "terminal")])
            chips("timer", L("Сообщать о командах дольше"),
                  [(15, L("15 с")), (30, L("30 с")), (60, L("1 мин")), (120, L("2 мин")), (300, L("5 мин"))], model.commandSeconds) { value in
                model.commandSeconds = value
                model.onCommand?(value)
            }
            grid([("autoCoffee", "cup.and.saucer"), ("serversNotWork", "server.rack")])
            note(L("Кофе-режим не даёт экрану гаснуть, пока Claude или команда работают. Серверы и приложения, запущенные в терминале, можно не считать работой — тогда Бит не будет «работать», пока они висят."))
        }
    }

    private var rhythm: some View {
        VStack(alignment: .leading, spacing: 12) {
            grid([("breaks", "figure.walk"), ("water", "drop"), ("eyes", "eye"), ("summary", "chart.bar")])
            Button(L("Показать итог дня")) { model.onAction?("summary") }.buttonStyle(BitButton(primary: false))
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 8) {
            permissionRow("meetings", "calendar", L("Встречи из Календаря"), L("Чтобы напоминать о встречах и подключать по ссылке."),
                          settings: "Privacy_Calendars")
            permissionRow("downloads", "arrow.down.circle", L("Загрузки"), L("Чтобы радоваться скачанным файлам."),
                          settings: "Privacy_FilesAndFolders")
            permissionRow("typing", "keyboard", L("Темп набора"), L("Универсальный доступ: считаю только скорость, не клавиши."),
                          settings: "Privacy_Accessibility")
            note(L("Управлять Терминалом, iTerm и Finder macOS разрешит, когда понадобится: при кнопке «Открыть» в облачке и при уборке стола."))
                .padding(.top, 4)
        }
    }

    private var desktop: some View {
        VStack(alignment: .leading, spacing: 12) {
            note(L("Попроси — расставлю файлы и папки по сетке справа, обходя виджеты. Расставь сам и нажми «Запомнить» — дальше буду возвращать значки на твои места, а новые ставить в свободные клетки."))
            row("square.grid.3x3", model.desktopCount > 0 ? L("Запомнено значков: %@", "\(model.desktopCount)") : L("Расстановка не запомнена — расставляю по сетке"))
            HStack(spacing: 10) {
                Button(L("Навести порядок")) { model.onAction?("tidy") }.buttonStyle(BitButton(primary: true))
                Button(L("Запомнить, как стоят значки")) { model.onAction?("remember") }.buttonStyle(BitButton(primary: false))
                if model.desktopCount > 0 {
                    Button(L("Забыть")) { model.onAction?("forget") }.buttonStyle(BitButton(primary: false))
                }
            }
        }
    }

    private var integrations: some View {
        VStack(alignment: .leading, spacing: 8) {
            note(L("Подключу себя к агентам и терминалу: буду «работать», пока они отвечают, и скажу, когда закончили. Трогаю только свои записи, перед первой правкой файла кладу рядом копию .bak-mypetbit. Переложишь меня — сам починю пути."))
            Button(L("Подключить всё найденное")) { model.onAction?("integrations:all") }
                .buttonStyle(BitButton(primary: true))
                .padding(.bottom, 4)
            ForEach(model.integrations) { item in
                HStack(spacing: 12) {
                    icon(item.id == "zsh" ? "terminal" : "sparkles")
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(item.title).font(.system(size: 13, weight: .semibold, design: .rounded))
                            badge(item.status, item.tone == 1 ? Palette.glow : item.tone == 2 ? Palette.warn : Palette.dim)
                        }
                        Text(item.file).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Palette.dim)
                    }
                    Spacer(minLength: 8)
                    if let action = item.action, let key = item.actionKey {
                        Button(action) { model.onAction?("integration:\(key):\(item.id)") }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(key == "disconnect" ? Palette.dim : Palette.glow)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
            }
            note(L("Изменения подхватятся в новых окнах терминала и при следующем запуске агента."))
                .padding(.top, 4)
        }
    }

    private var converters: some View {
        VStack(alignment: .leading, spacing: 8) {
            note(L("Дай мне файл и нажми двумя пальцами → «Конвертировать в…». Беру лучший из того, что есть на Mac: LibreOffice и pandoc точнее, iWork — с вёрсткой, macOS — всегда под рукой. Внутрь меня ничего не ставится."))
            ForEach(model.converters) { item in
                HStack(spacing: 12) {
                    icon(item.on ? "checkmark.circle" : "circle.dashed")
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(item.title).font(.system(size: 13, weight: .semibold, design: .rounded))
                            badge(item.on ? L("есть") : L("не найден"), item.on ? Palette.glow : Palette.dim)
                        }
                        Text(item.detail ?? "").font(.system(size: 11.5, design: .rounded)).foregroundStyle(Palette.dim)
                    }
                    Spacer(minLength: 8)
                    if !item.on, let hint = model.installHints[item.id] {
                        if hint.hasPrefix("brew") {
                            Button(L("Скопировать команду")) { model.onAction?("copy:" + item.id) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(Palette.glow)
                                .help(hint)
                        } else {
                            Text(hint).font(.system(size: 11.5, design: .rounded)).foregroundStyle(Palette.dim)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
            }
            HStack(spacing: 10) {
                Button(L("Проверить снова")) { model.onAction?("rescan") }.buttonStyle(BitButton(primary: false))
                note(L("Keynote, Pages и Numbers в первый раз macOS попросит разрешить мне управлять ими."))
            }
            .padding(.top, 4)
        }
    }

    private var character: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(model.characterLines, id: \.self) { Text($0).foregroundStyle(Palette.dim) }
            }
            grid([("autoDress", "tshirt")])
            label(L("Носить всегда — одна вещь; иначе выбирает сам"))
            FlowChips(items: model.accessories) { model.onAccessory?($0) }
            label(L("Сезонные — надеваются сами в свой сезон"))
            FlowChips(items: model.seasonal) { model.onSeasonal?($0) }
        }
    }

    private var mac: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.statusLines, id: \.self) { line in
                Text(line)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
            }
        }
    }

    private var developer: some View {
        VStack(alignment: .leading, spacing: 12) {
            note(L("Показать любое состояние и проверить реакции без настоящих событий. Флаги запуска — в DEVELOPMENT.md."))
            HStack(spacing: 10) {
                Button(L("Состояние (демо)…")) { model.onAction?("states") }.buttonStyle(BitButton(primary: false))
                Button(L("Отладка…")) { model.onAction?("debug") }.buttonStyle(BitButton(primary: false))
            }
        }
    }

    // MARK: Детали

    private func grid(_ items: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 8) {
            ForEach(items, id: \.0) { key, symbol in
                HStack(spacing: 10) {
                    Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.glow).frame(width: 18)
                    Text(model.titles[key] ?? key).font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Toggle("", isOn: model.binding(key)).toggleStyle(BitToggle()).labelsHidden()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
            }
        }
    }

    private func chips(_ symbol: String, _ title: String, _ options: [(Int, String)], _ selected: Int,
                       _ pick: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.glow).frame(width: 18)
            Text(title).font(.system(size: 13, weight: .medium, design: .rounded)).lineLimit(2)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                ForEach(options, id: \.0) { value, text in
                    let on = selected == value
                    Text(text)
                        .font(.system(size: 12, weight: on ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(on ? Color(red: 0x10 / 255, green: 0x14 / 255, blue: 0x1C / 255) : Palette.text)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(on ? Palette.glow : Color.white.opacity(0.06)))
                        .contentShape(Capsule())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { pick(value) } }
                }
            }
            .layoutPriority(1)  // таблетки не сжимаются — переносится подпись слева
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    private func permissionRow(_ key: String, _ symbol: String, _ title: String, _ text: String, settings: String) -> some View {
        let _ = model.tick
        let on = model.values[key] ?? false
        let state = on ? (model.permission?(key) ?? .unknown) : .unknown
        return HStack(spacing: 12) {
            icon(symbol)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
                    if on {
                        switch state {
                        case .granted: badge(L("разрешено"), Palette.glow)
                        case .denied: badge(L("запрещено"), Palette.warn)
                        case .unknown: badge(L("ждёт ответа macOS"), Palette.dim)
                        }
                    }
                }
                Text(text).font(.system(size: 11.5, design: .rounded)).foregroundStyle(Palette.dim)
            }
            Spacer(minLength: 8)
            if state == .denied {
                Button(L("Настройки")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settings)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.warn)
            }
            Toggle("", isOn: model.binding(key)).toggleStyle(BitToggle()).labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            icon(symbol)
            Text(text).font(.system(size: 13, weight: .medium, design: .rounded))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Palette.glow)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.glow.opacity(0.12)))
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12, design: .rounded)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Palette.dim).padding(.top, 4)
    }
}

/// Аксессуары таблетками в несколько строк: включённый — бирюзовый, закрытый — тусклый с подсказкой, с какого уровня.
private struct FlowChips: View {
    let items: [SettingsModel.Choice]
    let pick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 12.5, weight: item.on ? .semibold : .medium, design: .rounded))
                    if let detail = item.detail {
                        Text(detail).font(.system(size: 10.5, design: .rounded)).opacity(0.75)
                    }
                }
                .foregroundStyle(item.on ? Color(red: 0x10 / 255, green: 0x14 / 255, blue: 0x1C / 255) : Palette.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(item.on ? Palette.glow : Color.white.opacity(0.06)))
                .opacity(item.enabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onTapGesture { if item.enabled { pick(item.id) } }
            }
        }
    }
}

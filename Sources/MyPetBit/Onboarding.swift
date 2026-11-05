import AppKit
import EventKit
import SwiftUI

/// Состояние знакомства: страница, переключатели настроек и обратные вызовы контроллера.
@MainActor
final class OnboardingModel: ObservableObject {
    enum Permission { case granted, denied, unknown }

    @Published var page = 0
    @Published var values: [String: Bool]
    @Published var sleepMinutes: Int
    /// Раз в секунду: статус разрешений мог смениться в системном окне.
    @Published var tick = 0
    // Состояние анимаций — здесь, а не в @State: в Command Line Tools @State недоступен (макрос из Xcode),
    // как и в Trunook.
    @Published var appeared = false
    @Published var revealed = false
    let pages = 6

    var onPage: ((Int) -> Void)?
    var onToggle: ((String, Bool) -> Void)?
    var onSleep: ((Int) -> Void)?
    var onFinish: (() -> Void)?
    var permission: ((String) -> Permission)?
    /// ИИ-агенты и терминал: что нашлось и подключили ли уже.
    @Published var integrationsFound = ""
    @Published var integrationsDone = false
    var onIntegrate: (() -> Void)?

    init(values: [String: Bool], sleepMinutes: Int) {
        self.values = values
        self.sleepMinutes = sleepMinutes
    }

    func go(_ page: Int) {
        let target = min(max(page, 0), pages - 1)
        guard target != self.page else { return }
        revealed = false
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { self.page = target }
        DispatchQueue.main.async { self.revealed = true }  // пункты новой страницы выезжают по очереди
        onPage?(target)
    }

    func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { self.values[key] ?? false },
                set: { on in
                    self.values[key] = on
                    self.onToggle?(key, on)
                })
    }
}

/// Окно знакомства: тёмная карточка в цвет экрана Бита. Принимает фокус — в ней кнопки и переключатели.
final class OnboardingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OnboardingWindow {
    static let size = NSSize(width: 600, height: 570)
    let panel: OnboardingPanel
    let model: OnboardingModel

    init(model: OnboardingModel) {
        self.model = model
        panel = OnboardingPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless],
                                backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false  // панель по умолчанию прячется, когда активным становится другое приложение
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: OnboardingView(model: model))
    }

    /// По центру экрана, чуть правее: слева от карточки стоит Бит и «рассказывает».
    func show(on screen: NSRect) {
        let origin = NSPoint(x: screen.midX - Self.size.width / 2 + 70, y: screen.midY - Self.size.height / 2)
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        // У приложения без Dock, пока активно другое, makeKeyAndOrderFront окно не показывает — выводим явно.
        panel.orderFrontRegardless()
        NSApp.activate()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 1
        }, completionHandler: {
            MainActor.assumeIsolated { self.panel.alphaValue = 1 }
        })
    }

    func close(_ done: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                self.panel.orderOut(nil)
                done()
            }
        })
    }
}

// MARK: - Вид

enum Palette {
    static let ink = Color(red: 0x1B / 255, green: 0x1F / 255, blue: 0x2A / 255)
    static let glow = Color(red: 0x5C / 255, green: 0xF2 / 255, blue: 0xE0 / 255)
    static let text = Color(red: 0xE8 / 255, green: 0xFB / 255, blue: 0xF8 / 255)
    static let dim = Color(red: 0x9F / 255, green: 0xB3 / 255, blue: 0xB8 / 255)
    static let warn = Color(red: 0xFF / 255, green: 0xB5 / 255, blue: 0x47 / 255)
}

private struct Feature {
    let symbol: String
    let title: String
    let text: String
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                ForEach(0..<model.pages, id: \.self) { index in
                    if index == model.page {
                        page(index)
                            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                    removal: .move(edge: .leading).combined(with: .opacity)))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            footer
        }
        .padding(26)
        .frame(width: OnboardingWindow.size.width, height: OnboardingWindow.size.height)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Palette.ink)
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Palette.glow.opacity(0.45), lineWidth: 1))
        )
        .scaleEffect(model.appeared ? 1 : 0.85, anchor: .bottomLeading)
        .opacity(model.appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) { model.appeared = true }
            model.revealed = true
        }
        .onReceive(timer) { _ in model.tick += 1 }
        .font(.system(size: 13, design: .rounded))
        .foregroundStyle(Palette.text)
        .tint(Palette.glow)
        .focusEffectDisabled()  // без синей рамки фокуса на кнопках
    }

    // MARK: Страницы

    @ViewBuilder
    private func page(_ index: Int) -> some View {
        switch index {
        case 0:
            features(L("Привет! Я Бит"), L("Маленький робот, который живёт на твоём столе. Вот что я умею:"), [
                Feature(symbol: "eyes", title: L("Слежу за курсором"), text: L("Куда ты — туда и мои глаза.")),
                Feature(symbol: "moon.zzz", title: L("Сплю, пока тебя нет"), text: L("И радуюсь, когда ты вернёшься.")),
                Feature(symbol: "gamecontroller", title: L("Не скучаю"), text: L("Читаю, играю в тетрис, боксирую — и болею за себя.")),
                Feature(symbol: "heart", title: L("Люблю, когда гладят"), text: L("Поводи курсором туда-сюда — помурчу трекпадом."))
            ])
        case 1:
            features(L("Я чувствую твой Mac"), L("…и работаю вместе с тобой."), [
                Feature(symbol: "battery.75percent", title: L("Батарея, сеть, перегрев"), text: L("Покажу значком на экране, если что-то не так.")),
                Feature(symbol: "video", title: L("Звонок"), text: L("Становлюсь прозрачным и молчу.")),
                Feature(symbol: "sparkles", title: L("ИИ-агенты"), text: L("Claude, Cursor, OpenCode, Ollama: работаю, пока они отвечают, и скажу, когда готово.")),
                Feature(symbol: "terminal", title: L("Долгие команды"), text: L("Скажу, когда закончилась — и если упала. Могу прервать.")),
                Feature(symbol: "cup.and.saucer", title: L("Кофе"), text: L("Пока идёт работа, экран не гаснет."))
            ])
        case 2:
            features(L("Помогаю держать ритм"), L("Мягко, без занудства."), [
                Feature(symbol: "timer", title: L("Помодоро и таймер"), text: L("Потяни мою антенну вверх — сколько вытянешь, столько минут.")),
                Feature(symbol: "calendar", title: L("Встречи"), text: L("Напомню за 5 минут и подключу по ссылке.")),
                Feature(symbol: "figure.walk", title: L("Перерывы, вода, глаза"), text: L("Напомню — и подожду.")),
                Feature(symbol: "chart.bar", title: L("Итог дня"), text: L("Вечером расскажу, как мы поработали."))
            ])
        case 3:
            features(L("Как со мной общаться"), L("Я понимаю мышь и трекпад."), [
                Feature(symbol: "hand.tap", title: L("Щелчок"), text: L("Радуюсь. Двойной — дай пять!")),
                Feature(symbol: "contextualmenu.and.cursorarrow", title: L("Двумя пальцами"), text: L("Открою своё меню.")),
                Feature(symbol: "hand.draw", title: L("Перетащи"), text: L("Переставлю, куда скажешь. Брось — полечу!")),
                Feature(symbol: "clock", title: L("Наведи и подержи"), text: L("Покажу время. Щёлкни — нагрузку CPU, памяти и диска.")),
                Feature(symbol: "menubar.rectangle", title: L("Строка меню"), text: L("Таймер, кофе и окно «Настройки…»."))
            ])
        case 4:
            features(L("Ещё я умею"), L("Маленький, но полезный."), [
                Feature(symbol: "doc.on.doc", title: L("Носить файлы"), text: L("Перетащи файл на меня — поймаю. Утащи с меня в папку — перенесу.")),
                Feature(symbol: "arrow.triangle.2.circlepath", title: L("Конвертировать"), text: L("Нажми на меня с файлом двумя пальцами: docx, PDF, PNG, сжать видео и не только.")),
                Feature(symbol: "music.note", title: L("Музыка"), text: L("Зажми меня — пауза. Смахни двумя пальцами — следующий трек.")),
                Feature(symbol: "square.grid.3x3", title: L("Порядок на столе"), text: L("Расставлю значки, а запомню твою расстановку — верну как было.")),
                Feature(symbol: "gauge.with.dots.needle.67percent", title: L("Нагрузка"), text: L("Скажу, если Mac вдруг загрузился, и кто виноват."))
            ])
        default:
            setup
        }
    }

    private func features(_ title: String, _ subtitle: String, _ items: [Feature]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            header(title, subtitle)
            VStack(alignment: .leading, spacing: 13) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .top, spacing: 14) {
                        icon(item.symbol)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 14, weight: .semibold, design: .rounded))
                            Text(item.text).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .opacity(model.revealed ? 1 : 0)
                    .offset(x: model.revealed ? 0 : 14)
                    .animation(.easeOut(duration: 0.28).delay(0.12 + 0.06 * Double(i)), value: model.revealed)
                }
            }
        }
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 24, weight: .bold, design: .rounded))
            Text(subtitle).foregroundStyle(Palette.glow.opacity(0.85))
        }
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Palette.glow)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.glow.opacity(0.12)))
    }

    // MARK: Разрешения и настройки

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(L("Разрешения и настройки"), L("Всё можно поменять потом в «Настройках…»."))
            Text(L("Спросит macOS")).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Palette.dim)
            VStack(spacing: 8) {
                permissionRow("meetings", "calendar", L("Встречи из Календаря"), L("Чтобы напоминать о встречах и подключать по ссылке."),
                              settings: "Privacy_Calendars")
                permissionRow("downloads", "arrow.down.circle", L("Загрузки"), L("Чтобы радоваться скачанным файлам."),
                              settings: "Privacy_FilesAndFolders")
                permissionRow("typing", "keyboard", L("Темп набора"), L("Универсальный доступ: считаю только скорость, не клавиши."),
                              settings: "Privacy_Accessibility")
                integrationsRow
            }
            Text(L("Начальные настройки")).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Palette.dim)
                .padding(.top, 4)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 8) {
                setting("talk", "text.bubble", L("Фразы"))
                setting("water", "drop", L("Напоминать про воду"))
                setting("eyes", "eye", L("Правило 20-20-20"))
                setting("summary", "chart.bar", L("Итог дня"))
                setting("autoCoffee", "cup.and.saucer", L("Кофе на время работы"))
                setting("haptics", "hand.tap", L("Тактильный отклик"))
                setting("autoUpdate", "arrow.down.circle", L("Проверять обновления"))
                setting("music", "music.note", L("Музыка"))
            }
            HStack {
                icon("moon.zzz")
                Text(L("Засыпать при простое")).font(.system(size: 13, weight: .medium, design: .rounded))
                Spacer()
                HStack(spacing: 4) {
                    ForEach([(1, L("1 мин")), (5, L("5 мин")), (15, L("15 мин")), (0, L("никогда"))], id: \.0) { minutes, title in
                        let on = model.sleepMinutes == minutes
                        Text(title)
                            .font(.system(size: 12, weight: on ? .semibold : .medium, design: .rounded))
                            .foregroundStyle(on ? Color(red: 0x10 / 255, green: 0x14 / 255, blue: 0x1C / 255) : Palette.text)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(on ? Palette.glow : Color.white.opacity(0.06)))
                            .contentShape(Capsule())
                            .onTapGesture {
                                withAnimation(.easeOut(duration: 0.15)) { model.sleepMinutes = minutes }
                                model.onSleep?(minutes)
                            }
                    }
                }
            }
        }
    }

    private func permissionRow(_ key: String, _ symbol: String, _ title: String, _ note: String, settings: String) -> some View {
        let _ = model.tick
        let state = (model.values[key] ?? false) ? (model.permission?(key) ?? .unknown) : .unknown
        return HStack(spacing: 12) {
            icon(symbol)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
                    if model.values[key] ?? false {
                        switch state {
                        case .granted: badge(L("разрешено"), Palette.glow)
                        case .denied: badge(L("запрещено"), Palette.warn)
                        case .unknown: badge(L("ждёт ответа macOS"), Palette.dim)
                        }
                    }
                }
                Text(note).font(.system(size: 11.5, design: .rounded)).foregroundStyle(Palette.dim)
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

    /// Хуки в агентах и терминале — одной кнопкой; подробно — в «Настройки → Интеграции».
    private var integrationsRow: some View {
        HStack(spacing: 12) {
            icon("link")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(L("ИИ-агенты и терминал")).font(.system(size: 13, weight: .semibold, design: .rounded))
                    if model.integrationsDone { badge(L("подключено"), Palette.glow) }
                }
                Text(model.integrationsFound).font(.system(size: 11.5, design: .rounded)).foregroundStyle(Palette.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !model.integrationsDone {
                Button(L("Подключить")) { model.onIntegrate?() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.glow)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private func setting(_ key: String, _ symbol: String, _ title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.glow).frame(width: 18)
            Text(title).font(.system(size: 13, weight: .medium, design: .rounded)).lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            Toggle("", isOn: model.binding(key)).toggleStyle(BitToggle()).labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    // MARK: Низ: точки страниц и кнопки

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<model.pages, id: \.self) { i in
                    Capsule()
                        .fill(i == model.page ? Palette.glow : Palette.glow.opacity(0.25))
                        .frame(width: i == model.page ? 18 : 7, height: 7)
                        .onTapGesture { model.go(i) }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.page)
            Spacer()
            if model.page < model.pages - 1 {
                Button(L("Пропустить")) { model.onFinish?() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.dim)
            }
            if model.page > 0 {
                Button(L("Назад")) { model.go(model.page - 1) }
                    .buttonStyle(BitButton(primary: false))
            }
            Button(model.page == model.pages - 1 ? L("Начать!") : L("Далее")) {
                if model.page == model.pages - 1 { model.onFinish?() } else { model.go(model.page + 1) }
            }
            .buttonStyle(BitButton(primary: true))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 14)
    }
}

/// Переключатель как в быстром меню Бита: бирюзовая таблетка с бегунком. Не бледнеет, когда окно не в фокусе.
struct BitToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Capsule()
            .fill(configuration.isOn ? Palette.glow : Color(red: 0x2E / 255, green: 0x35 / 255, blue: 0x46 / 255))
            .frame(width: 32, height: 18)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle().fill(Palette.text).frame(width: 14, height: 14).padding(2)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            }
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { configuration.isOn.toggle() }
            }
    }
}

/// Кнопки в стиле облачка Бита: главная — бирюзовая, остальные — контуром.
struct BitButton: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(primary ? Color(red: 0x10 / 255, green: 0x14 / 255, blue: 0x1C / 255) : Palette.glow)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(primary ? Palette.glow.opacity(configuration.isPressed ? 0.75 : 1) : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Palette.glow.opacity(primary ? 0 : 0.5), lineWidth: 1))
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

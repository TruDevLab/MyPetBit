import Foundation

/// Аксессуар Бита. Надет всегда только один.
enum Accessory: String, CaseIterable, Codable {
    case headphones, glasses, bow, scarf, flower, mug, cactus, santa, party, pumpkin

    var title: String {
        switch self {
        case .headphones: return L("Наушники")
        case .glasses: return L("Очки")
        case .bow: return L("Бабочка")
        case .scarf: return L("Шарф")
        case .flower: return L("Цветок на антенне")
        case .mug: return L("Кружка")
        case .cactus: return L("Кактус")
        case .santa: return L("Колпак Санты")
        case .party: return L("Праздничный колпачок")
        case .pumpkin: return L("Шапка-тыква")
        }
    }

    /// Для сезонных — когда надеваются сами.
    var season: String? {
        switch self {
        case .pumpkin: return L("Хэллоуин, 24.10–1.11")
        case .santa: return L("Новый год, 1.12–10.01")
        case .party: return L("годовщина знакомства")
        default: return nil
        }
    }

    /// Уровень привязанности (с нуля), с которого открывается; nil — только по сезону.
    var unlockLevel: Int? {
        switch self {
        case .headphones, .glasses: return 0
        case .bow: return 1
        case .scarf, .mug: return 2
        case .flower, .cactus: return 3
        case .santa, .party, .pumpkin: return nil
        }
    }
}

/// Итоги одного дня. День начинается в 4:00, чтобы работа после полуночи шла в «вчера».
struct DayLog: Codable {
    var first: Date
    var last: Date
    var activeSeconds: Double = 0
    var breaks = 0
    var affection: Double = 0  // сколько привязанности набрано за день (не больше дневного предела)
    var longestStreak: Double = 0  // самый долгий отрезок работы без перерыва, секунды

    init(first: Date, last: Date) {
        self.first = first
        self.last = last
    }

    /// Читает и старые сохранения, где каких-то полей ещё не было.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        first = try c.decode(Date.self, forKey: .first)
        last = try c.decode(Date.self, forKey: .last)
        activeSeconds = try c.decodeIfPresent(Double.self, forKey: .activeSeconds) ?? 0
        breaks = try c.decodeIfPresent(Int.self, forKey: .breaks) ?? 0
        affection = try c.decodeIfPresent(Double.self, forKey: .affection) ?? 0
        longestStreak = try c.decodeIfPresent(Double.self, forKey: .longestStreak) ?? 0
    }
}

/// Всё, что Бит помнит между запусками. Хранится в UserDefaults ключом "character" (JSON).
struct CharacterState: Codable {
    var affection: Double = 0
    var mood: Double = 0.6       // 0...1, само возвращается к 0.6
    var energy: Double = 1       // 0...1, тратится за 3 часа работы, восстанавливается за 20 минут отдыха
    var firstMet = Date()
    var days: [String: DayLog] = [:]
    var breakStarts: [Date] = []  // начала перерывов за 14 дней — для распорядка
    var chosen: [Accessory] = []   // закреплённая пользователем вещь (одна); иначе Бит выбирает сам
    var seasonal = true
    var autoDress = true
    var seasonalOff: [Accessory] = []  // сезонные, которые пользователь снял

    init() {}

    /// Читает и старые сохранения: отсутствующие поля получают значения по умолчанию.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CharacterState()
        affection = try c.decodeIfPresent(Double.self, forKey: .affection) ?? d.affection
        mood = try c.decodeIfPresent(Double.self, forKey: .mood) ?? d.mood
        energy = try c.decodeIfPresent(Double.self, forKey: .energy) ?? d.energy
        firstMet = try c.decodeIfPresent(Date.self, forKey: .firstMet) ?? d.firstMet
        days = try c.decodeIfPresent([String: DayLog].self, forKey: .days) ?? d.days
        breakStarts = try c.decodeIfPresent([Date].self, forKey: .breakStarts) ?? d.breakStarts
        // Удалённые из гардероба вещи (шапка, кепка) просто пропускаются.
        chosen = (try c.decodeIfPresent([String].self, forKey: .chosen))?.compactMap(Accessory.init(rawValue:)) ?? d.chosen
        seasonal = try c.decodeIfPresent(Bool.self, forKey: .seasonal) ?? d.seasonal
        autoDress = try c.decodeIfPresent(Bool.self, forKey: .autoDress) ?? d.autoDress
        seasonalOff = (try c.decodeIfPresent([String].self, forKey: .seasonalOff))?.compactMap(Accessory.init(rawValue:)) ?? d.seasonalOff
    }
}

/// Что вокруг происходит — от этого зависит, что Бит наденет сам.
struct OutfitContext {
    var streakMinutes: Double
    var busy: Bool
    var music: Bool
    var headphones: Bool  // подключены настоящие наушники
}

enum CharacterEvent {
    case newDay(late: Bool)        // первая активность за день; late — вчера работали после 23:00
    case breakOver(minutes: Int)   // вернулись с перерыва
    case levelUp(Int)
}

enum Interaction { case click, pet, highFive }

/// Характер: привязанность, настроение, энергия, распорядок перерывов, память о прошлых днях, аксессуары.
/// Не тамагочи: привязанность только растёт, Бит ничего не требует.
@MainActor
final class PetCharacter {
    static let levels: [(threshold: Double, title: String)] = [
        (0, L("Знакомство")), (20, L("Приятели")), (60, L("Друзья")), (150, L("Лучшие друзья")), (300, L("Неразлучные"))
    ]
    private static let dailyAffectionLimit: Double = 15

    var onEvent: ((CharacterEvent) -> Void)?
    private(set) var state: CharacterState

    private let defaults = UserDefaults.standard
    private var lastSave = Date()
    private var streakStart: Date?
    private var breakStart: Date?
    private var sleepyUntil: Date?
    private var nextMicro = Date().addingTimeInterval(180)

    init() {
        if let data = UserDefaults.standard.data(forKey: "character"),
           let saved = try? JSONDecoder().decode(CharacterState.self, from: data) {
            state = saved
        } else {
            state = CharacterState()
        }
    }

    // MARK: - Показатели

    var level: Int { Self.levels.lastIndex { state.affection >= $0.threshold } ?? 0 }

    /// Минут работы без перерыва в 5 минут.
    var streakMinutes: Double { streakStart.map { Date().timeIntervalSince($0) / 60 } ?? 0 }

    /// Утром после позднего вечера — полчаса сонный за компанию.
    var isSleepyCompany: Bool { sleepyUntil.map { $0 > Date() } ?? false }

    var isTired: Bool { state.energy < 0.25 }

    var daysTogether: Int {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: state.firstMet),
                                           to: calendar.startOfDay(for: Date())).day ?? 0
        return days + 1
    }

    func isUnlocked(_ accessory: Accessory) -> Bool {
        accessory.unlockLevel.map { level >= $0 } ?? false
    }

    // MARK: - Время

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date.addingTimeInterval(-4 * 3600)) }

    private static func minuteOfDay(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private static func clock(_ minutes: Int) -> String { String(format: "%d:%02d", minutes / 60, minutes % 60) }

    // MARK: - Раз в секунду

    func tick(idle: TimeInterval) {
        let now = Date()
        let key = Self.dayKey(now)
        let active = idle < 60

        // Перерыв: 5 минут простоя после хотя бы 25 минут работы.
        if idle >= 300 {
            if breakStart == nil, let start = streakStart, now.timeIntervalSince(start) - idle >= 25 * 60 {
                let begin = now.addingTimeInterval(-idle)
                breakStart = begin
                state.breakStarts.append(begin)
                state.breakStarts.removeAll { $0 < now.addingTimeInterval(-14 * 86400) }
                state.days[key]?.breaks += 1
            }
            streakStart = nil
        } else if streakStart == nil {
            streakStart = now.addingTimeInterval(-idle)
        }
        if idle < 2, let begin = breakStart {
            breakStart = nil
            let minutes = Int(now.timeIntervalSince(begin) / 60)
            if minutes < 6 * 60 {  // ночь — не перерыв
                state.mood = min(1, state.mood + 0.05)
                gainAffection(2)
                onEvent?(.breakOver(minutes: minutes))
            }
        }

        // Новый день: первая активность после 4:00.
        if idle < 2 && state.days[key] == nil {
            let previous = state.days.filter { $0.key < key }.max { $0.key < $1.key }?.value
            let lastHour = previous.map { Calendar.current.component(.hour, from: $0.last) } ?? 12
            let late = previous != nil && (lastHour >= 23 || lastHour < 4)
            state.days[key] = DayLog(first: now, last: now)
            for old in state.days.keys.sorted().dropLast(30) { state.days[old] = nil }
            state.energy = late ? 0.6 : 1
            if late { sleepyUntil = now.addingTimeInterval(30 * 60) }
            gainAffection(1)
            onEvent?(.newDay(late: late))
        }

        if active {
            state.days[key]?.activeSeconds += 1
            state.days[key]?.last = now
            if let start = streakStart, let longest = state.days[key]?.longestStreak {
                state.days[key]?.longestStreak = max(longest, now.timeIntervalSince(start))
            }
            state.energy = max(0, state.energy - 1 / (3 * 3600))
        } else {
            state.energy = min(1, state.energy + 1 / (20 * 60))
        }
        state.mood += (0.6 - state.mood) / 7200

        if now.timeIntervalSince(lastSave) > 30 { save() }
    }

    func interact(_ kind: Interaction) {
        switch kind {
        case .click:
            state.mood = min(1, state.mood + 0.02)
            gainAffection(0.2)
        case .pet:
            state.mood = min(1, state.mood + 0.1)
            gainAffection(2)
        case .highFive:
            state.mood = min(1, state.mood + 0.05)
            gainAffection(1)
        }
    }

    private func gainAffection(_ amount: Double) {
        let key = Self.dayKey(Date())
        if state.days[key] == nil { state.days[key] = DayLog(first: Date(), last: Date()) }
        let allowed = max(0, Self.dailyAffectionLimit - (state.days[key]?.affection ?? 0))
        let gain = min(amount, allowed)
        guard gain > 0 else { return }
        let before = level
        state.affection += gain
        state.days[key]?.affection += gain
        if level > before { onEvent?(.levelUp(level)) }
        save()
    }

    private func save() {
        lastSave = Date()
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: "character") }
    }

    // MARK: - Поведение

    /// Случайное микродействие раз в несколько минут; чем выше уровень и настроение, тем чаще.
    func microAction(force: Bool = false) -> (state: PetState, seconds: TimeInterval)? {
        let now = Date()
        guard force || now >= nextMicro else { return nil }
        let base = 300 * (1 - 0.12 * Double(level)) * (state.mood > 0.75 ? 0.8 : 1)
        nextMicro = now.addingTimeInterval(.random(in: base * 0.6...base * 1.4))
        if state.energy < 0.35 { return (.yawn, 2.5) }
        if state.mood > 0.75 { return Bool.random() ? (.dance, 2) : (.happy, 1.2) }
        if state.mood < 0.4 { return (.sad, 1.2) }
        return Bool.random() ? (.happy, 1) : nil
    }

    /// Итог игры или боя: победа поднимает настроение, проигрыш немного огорчает.
    func hobbyResult(win: Bool) {
        state.mood = min(1, max(0, state.mood + (win ? 0.08 : -0.05)))
        if win { gainAffection(0.5) }
    }

    /// Для отладки: «вчера работали допоздна» — полчаса сонный за компанию.
    func startSleepyCompany() {
        sleepyUntil = Date().addingTimeInterval(30 * 60)
    }

    /// Привычное время перерыва: получасовые отрезки, в которые перерыв был хотя бы в 3 разных дня из 14.
    var usualBreaks: [Int] {
        var daysPerBin: [Int: Set<String>] = [:]
        for start in state.breakStarts {
            daysPerBin[Self.minuteOfDay(start) / 30 * 30, default: []].insert(Self.dayKey(start))
        }
        return daysPerBin.filter { $0.value.count >= 3 }.keys.sorted()
    }

    /// Привычное время перерыва прошло больше 15 минут назад, сегодня с тех пор перерыва не было, работаете не меньше 45 минут.
    func isBreakOverdue() -> Bool {
        guard streakMinutes >= 45 else { return false }
        let now = Date()
        let minute = Self.minuteOfDay(now)
        let today = Self.dayKey(now)
        for bin in usualBreaks where minute >= bin + 45 && minute <= bin + 150 {
            let tookBreak = state.breakStarts.contains { Self.dayKey($0) == today && Self.minuteOfDay($0) >= bin }
            if !tookBreak { return true }
        }
        return false
    }

    /// Что надето — всегда одна вещь (или ничего). Важнее всего настоящие наушники, затем сезонное,
    /// затем закреплённое пользователем, затем то, что Бит выбрал сам.
    func accessories(context: OutfitContext, on date: Date = Date()) -> Set<Accessory> {
        if context.headphones { return [.headphones] }
        if let seasonal = seasonalWorn.first { return [seasonal] }
        if let pinned = state.chosen.last, isUnlocked(pinned) { return [pinned] }
        if state.autoDress, let own = autoPick(context, date) { return [own] }
        return []
    }

    /// Бит выбирает сам — по делам, времени и настроению. Выбор «на сегодня» постоянен в течение дня.
    private func autoPick(_ context: OutfitContext, _ date: Date) -> Accessory? {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let month = calendar.component(.month, from: date)
        let seed = Self.dayKey(date).unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) } & 0xFFFF
        if context.music { return .headphones }                                 // играет звук
        if context.streakMinutes >= 30 || context.busy { return .glasses }      // долго работает
        if (8..<11).contains(hour) || (15..<17).contains(hour), isUnlocked(.mug) { return .mug }  // кофе
        if [11, 12, 1, 2].contains(month), isUnlocked(.scarf) { return .scarf } // холодно
        if state.mood > 0.7, isUnlocked(.flower) { return .flower }             // хорошее настроение
        if seed % 2 == 0, isUnlocked(.bow) { return .bow }
        if seed % 3 == 0, isUnlocked(.cactus) { return .cactus }
        return nil
    }

    /// Сезон аксессуара сейчас (неважно, снят ли он).
    func inSeason(_ accessory: Accessory, on date: Date = Date()) -> Bool {
        let c = Calendar.current.dateComponents([.month, .day], from: date)
        let (month, day) = (c.month ?? 0, c.day ?? 0)
        switch accessory {
        case .pumpkin: return (month == 10 && day >= 24) || (month == 11 && day == 1)
        case .santa: return month == 12 || (month == 1 && day <= 10)
        case .party:
            let met = Calendar.current.dateComponents([.month, .day], from: state.firstMet)
            return daysTogether > 1 && met.month == month && met.day == day
        default: return false
        }
    }

    /// Сезонные, которые надеты прямо сейчас.
    var seasonalWorn: [Accessory] {
        guard state.seasonal else { return [] }
        return [Accessory.pumpkin, .santa, .party].filter { inSeason($0) && !state.seasonalOff.contains($0) }
    }

    /// Закрепить вещь (одну) или снять закрепление.
    func toggle(_ accessory: Accessory) {
        state.chosen = state.chosen == [accessory] ? [] : [accessory]
        save()
    }

    func toggleAutoDress() {
        state.autoDress.toggle()
        save()
    }

    func toggleSeasonal(_ accessory: Accessory) {
        if let index = state.seasonalOff.firstIndex(of: accessory) {
            state.seasonalOff.remove(at: index)
        } else {
            state.seasonalOff.append(accessory)
        }
        state.seasonal = true
        save()
    }

    // MARK: - Для меню

    /// Сегодняшний день (с 4:00): для итога дня.
    var today: DayLog? { state.days[Self.dayKey(Date())] }

    var summary: [String] {
        let next = Self.levels.indices.contains(level + 1) ? Self.levels[level + 1].threshold : nil
        var lines = [L("Уровень %@ из %@ — %@", "\(level + 1)", "\(Self.levels.count)", "\(Self.levels[level].title)")
                     + (next.map { String(format: L(", ♥ %.0f из %.0f"), state.affection, $0) } ?? String(format: ", ♥ %.0f", state.affection))]
        let mood = state.mood > 0.75 ? L("отличное") : state.mood > 0.5 ? L("хорошее") : state.mood > 0.35 ? L("спокойное") : L("грустное")
        lines.append(L("Настроение: %@, энергия: %@ %%", "\(mood)", "\(Int((state.energy * 100).rounded()))"))
        lines.append(L("Дней вместе: %@", "\(daysTogether)"))
        let todayKey = Self.dayKey(Date())
        if let today = state.days[todayKey] {
            lines.append(L("Сегодня: работа %@, перерывов %@", "\(Self.duration(today.activeSeconds))", "\(today.breaks)"))
        }
        if let previous = state.days.filter({ $0.key < todayKey }).max(by: { $0.key < $1.key }) {
            let label = previous.key == Self.dayKey(Date().addingTimeInterval(-86400)) ? L("Вчера") : L("Прошлый раз")
            let d = previous.value
            lines.append("\(label): \(Self.clock(Self.minuteOfDay(d.first)))–\(Self.clock(Self.minuteOfDay(d.last))), "
                         + L("работа %@, перерывов %@", "\(Self.duration(d.activeSeconds))", "\(d.breaks)"))
        }
        let usual = usualBreaks
        if !usual.isEmpty {
            lines.append(L("Обычно перерыв: около ") + usual.map { Self.clock($0) }.joined(separator: ", "))
        }
        return lines
    }

    private static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? L("%@ ч %@ мин", "\(minutes / 60)", "\(minutes % 60)") : L("%@ мин", "\(minutes)")
    }
}

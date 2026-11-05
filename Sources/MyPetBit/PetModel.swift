import Foundation
import CoreGraphics

enum PetState: String, CaseIterable {
    case idle, happy, sleep, work, surprised, dizzy, sad, drowsy, purr, shush, yawn, hot, note, dance, love, talk, menu, timer, clock, wave
    // Занятия, когда с Битом давно не играли.
    case reading, tetris, racing, boxing, workout

    var title: String {
        switch self {
        case .idle: return L("Обычный")
        case .happy: return L("Радость")
        case .sleep: return L("Сон")
        case .work: return L("Работает")
        case .surprised: return L("Удивлён")
        case .dizzy: return L("Укачало")
        case .sad: return L("Грустит")
        case .drowsy: return L("Сонный")
        case .purr: return L("Мурчит")
        case .shush: return L("Тсс (звонок)")
        case .yawn: return L("Зевает")
        case .hot: return L("Жарко")
        case .note: return L("Записывает")
        case .dance: return L("Танцует")
        case .love: return L("Влюблён")
        case .talk: return L("Говорит")
        case .menu: return L("Открыто меню")
        case .wave: return L("Машет")
        case .timer: return L("Таймер")
        case .clock: return L("Часы")
        case .reading: return L("Читает")
        case .tetris: return L("Играет в тетрис")
        case .racing: return L("Гонки")
        case .boxing: return L("Боксирует")
        case .workout: return L("Гантели")
        }
    }
}

/// Значок на экране Бита. Первые — «что не так», дальше — короткие новости.
enum PetBadge: String, CaseIterable {
    case offline, vpnOff, hot, memory, batteryLow, diskFull, stretch, night, downloading, music
    case charging, batteryFull, wave, weekend, screenshot, delivered, locate, highFive, levelUp
    case trophy, lost, bookDone, workoutDone
    case claudeAsks, claudeDone, commandFailed

    var title: String {
        switch self {
        case .offline: return L("Нет сети")
        case .vpnOff: return L("VPN отключился")
        case .hot: return L("Mac перегрелся")
        case .memory: return L("Не хватает памяти")
        case .batteryLow: return L("Батарея садится")
        case .diskFull: return L("Мало места на диске")
        case .stretch: return L("Пора размяться: полтора часа без перерыва")
        case .night: return L("Поздно, пора спать")
        case .downloading: return L("Идёт загрузка")
        case .music: return L("Играет музыка")
        case .charging: return L("Заряжается")
        case .batteryFull: return L("Батарея заряжена, можно отключить")
        case .wave: return L("С возвращением")
        case .weekend: return L("Выходной")
        case .screenshot: return L("Снимок экрана")
        case .delivered: return L("Файл загружен")
        case .locate: return L("Курсор здесь")
        case .highFive: return L("Дай пять")
        case .levelUp: return L("Привязанность выросла")
        case .trophy: return L("Победа!")
        case .lost: return L("Проиграл")
        case .bookDone: return L("Дочитал главу")
        case .workoutDone: return L("Размялся")
        case .claudeAsks: return L("ИИ-агент просит разрешение")
        case .claudeDone: return L("ИИ-агент ответил и ждёт")
        case .commandFailed: return L("Команда упала")
        }
    }

    var symbol: String {
        switch self {
        case .offline: return "wifi.slash"
        case .vpnOff: return "lock.slash"
        case .hot: return "thermometer.high"
        case .memory: return "memorychip"
        case .batteryLow: return "battery.25percent"
        case .diskFull: return "internaldrive"
        case .stretch: return "figure.walk"
        case .night: return "moon.zzz.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .music: return "music.note"
        case .charging: return "bolt.fill"
        case .batteryFull: return "battery.100percent.bolt"
        case .wave: return "hand.wave.fill"
        case .weekend: return "sun.max.fill"
        case .screenshot: return "camera.fill"
        case .delivered: return "shippingbox.fill"
        case .locate: return "cursorarrow.rays"
        case .highFive: return "hands.clap.fill"
        case .levelUp: return "heart.fill"
        case .trophy: return "trophy.fill"
        case .lost: return "hand.thumbsdown.fill"
        case .bookDone: return "book.closed.fill"
        case .workoutDone: return "figure.strengthtraining.traditional"
        case .claudeAsks: return "hand.raised.fill"
        case .claudeDone: return "text.bubble.fill"
        case .commandFailed: return "xmark.octagon.fill"
        }
    }

    var color: UInt32 {
        switch self {
        case .offline, .vpnOff, .hot, .memory, .batteryLow: return 0xFF7A6B          // проблема
        case .diskFull, .stretch, .night, .weekend: return 0xFFB547                   // подсказка
        case .charging, .batteryFull, .delivered, .highFive: return 0x34C759          // хорошая новость
        case .downloading, .music, .wave, .screenshot, .locate: return 0x5CF2E0       // просто новость, цветом лица
        case .levelUp: return 0xFF5E8A
        case .trophy: return 0xFFB547
        case .lost: return 0xFF7A6B
        case .bookDone: return 0x5CF2E0
        case .workoutDone: return 0x34C759
        case .claudeAsks: return 0xFFB547
        case .claudeDone: return 0x5CF2E0
        case .commandFailed: return 0xFF7A6B
        }
    }
}

/// То, что рисует BitLayerView. Логику выбора состояния держит PetController.
@MainActor
final class PetModel: ObservableObject {
    @Published private(set) var state: PetState = .idle
    /// Куда смотрит Бит: -1...1 по осям, y вниз.
    @Published var look: CGPoint = .zero
    @Published var badge: PetBadge?
    /// Энергосбережение: без свечения, анимации медленнее.
    @Published var lowPower = false
    @Published var accessories: Set<Accessory> = []

    func set(_ newState: PetState) {
        guard newState != state else { return }
        state = newState
    }
}

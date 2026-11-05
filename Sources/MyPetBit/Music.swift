import AppKit

/// Музыка через помощника MyPetBitMedia (внутри Бита): что играет и пауза, игра, следующий и прошлый трек.
/// Плеер любой, который отдаёт сведения системе: Музыка, Spotify, Яндекс Музыка, браузер.
@MainActor
final class MusicControl {
    struct Track: Codable, Equatable {
        var title: String?
        var artist: String?
        var album: String?
        var app: String?
        var playing: Bool
    }

    /// Номера команд MediaRemote.
    enum Command: UInt32 {
        case play = 0, pause = 1, toggle = 2, next = 4, previous = 5
    }

    /// Что сейчас в плеере (nil — ничего или помощник недоступен).
    private(set) var track: Track?
    /// Сменился трек или пауза: (прежнее, новое).
    var onChange: ((Track?, Track?) -> Void)?

    private var watcher: Process?
    private var input: Pipe?
    private var buffer = Data()
    private var running = false

    /// Помощник лежит в бандле Бита; при `swift run` без бандла его нет — музыка просто недоступна.
    static var helperPath: String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/MyPetBitMedia.xpc/Contents/MacOS/MyPetBitMedia").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    var isAvailable: Bool { Self.helperPath != nil }

    func start() {
        guard !running, let path = Self.helperPath else { return }
        running = true
        launchWatcher(path)
    }

    func stop() {
        running = false
        try? input?.fileHandleForWriting.close()  // помощник видит закрытый stdin и выходит сам
        watcher?.terminate()
        watcher = nil
        input = nil
        if track != nil {
            let old = track
            track = nil
            onChange?(old, nil)
        }
    }

    func send(_ command: Command) {
        guard let path = Self.helperPath else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["--send", "\(command.rawValue)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        // Пауза видна сразу, не дожидаясь, пока плеер разошлёт уведомление.
        if var guess = track, command == .toggle || command == .play || command == .pause {
            guess.playing = command == .play || (command == .toggle && !guess.playing)
            apply(guess)
        }
    }

    /// Строка помощника: JSON трека или «{}» — ничего не играет.
    static func parse(_ line: String) -> Track? {
        guard let track = try? JSONDecoder().decode(Track.self, from: Data(line.utf8)),
              track.title?.isEmpty == false || track.artist?.isEmpty == false else { return nil }
        return track
    }

    private func launchWatcher(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--watch"]
        let out = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(data) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            // Помощник упал — перезапуск через 5 с, пока музыка нужна.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                MainActor.assumeIsolated {
                    guard let self, self.running, self.watcher === process else { return }
                    self.launchWatcher(path)
                }
            }
        }
        do {
            try process.run()
            watcher = process
            self.input = input
        } catch {
            running = false
        }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            apply(Self.parse(line))
        }
    }

    private func apply(_ new: Track?) {
        guard new != track else { return }
        let old = track
        track = new
        onChange?(old, new)
    }
}

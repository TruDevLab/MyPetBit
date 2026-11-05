import AppKit
import Foundation

// Помощник Бита для музыки: что играет и команды плееру через приватный MediaRemote.framework.
//
// С macOS 15.4 MediaRemote отдаёт сведения о треке только процессам, чей bundle id начинается
// с `com.apple.controlcenter.`. Поэтому помощник лежит отдельным бандлом внутри Бита
// (Contents/XPCServices/MyPetBitMedia.xpc) со своим Info.plist — так же, как хелпер Trunook.
// Бит запускает его как обычную команду; если Apple закроет и это, отвалится только музыка.
//
//   --now        что играет — одной строкой JSON ({} — ничего)
//   --send N     команда: 0 играть, 1 пауза, 2 пауза/игра, 4 следующий, 5 предыдущий
//   --watch      строка JSON при каждой смене трека или паузы; завершается, когда Бит закрыл stdin
//   --probe      диагностика для разработчика

struct NowPlaying: Codable, Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var app: String?
    var playing: Bool
}

final class MediaRemote {
    private typealias GetInfo = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias GetBool = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias GetPID = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void
    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
    private typealias Register = @convention(c) (DispatchQueue) -> Void

    private let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
    private lazy var getInfo: GetInfo? = sym("MRMediaRemoteGetNowPlayingInfo")
    private lazy var getPlaying: GetBool? = sym("MRMediaRemoteGetNowPlayingApplicationIsPlaying")
    private lazy var getPID: GetPID? = sym("MRMediaRemoteGetNowPlayingApplicationPID")
    private lazy var sendFn: SendCommand? = sym("MRMediaRemoteSendCommand")
    private lazy var registerFn: Register? = sym("MRMediaRemoteRegisterForNowPlayingNotifications")

    private func sym<T>(_ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    var diagnostics: String {
        "bundle id: \(Bundle.main.bundleIdentifier ?? "—"), info=\(getInfo != nil), send=\(sendFn != nil), register=\(registerFn != nil)"
    }

    /// Трек, флаг «играет» и приложение-плеер. Колбэк MediaRemote иногда не приходит — ждём не больше 2 с.
    func fetch(_ done: @escaping (NowPlaying?) -> Void) {
        guard let getInfo else { return done(nil) }
        let queue = DispatchQueue.global(qos: .userInitiated)
        let group = DispatchGroup()
        var info: [String: Any] = [:]
        var playing = false
        var pid: Int32 = 0
        group.enter()
        getInfo(queue) { info = $0; group.leave() }
        if let getPlaying {
            group.enter()
            getPlaying(queue) { playing = $0; group.leave() }
        }
        if let getPID {
            group.enter()
            getPID(queue) { pid = $0; group.leave() }
        }
        if group.wait(timeout: .now() + 2) == .timedOut { return done(nil) }
        guard !info.isEmpty else { return done(nil) }
        // Флаг «играет» из MediaRemote иногда отстаёт; скорость воспроизведения точнее.
        let rate = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue
        done(NowPlaying(title: info["kMRMediaRemoteNowPlayingInfoTitle"] as? String,
                        artist: info["kMRMediaRemoteNowPlayingInfoArtist"] as? String,
                        album: info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String,
                        app: pid > 0 ? NSRunningApplication(processIdentifier: pid)?.localizedName : nil,
                        playing: rate.map { $0 > 0 } ?? playing))
    }

    func send(_ command: UInt32) -> Bool { sendFn?(command, nil) ?? false }

    /// Без регистрации система не рассылает уведомления о смене трека.
    func register() { registerFn?(DispatchQueue.main) }

    func notificationName(_ symbol: String) -> Notification.Name {
        guard let handle, let pointer = dlsym(handle, symbol),
              let value = pointer.assumingMemoryBound(to: CFString?.self).pointee else { return Notification.Name(symbol) }
        return Notification.Name(value as String)
    }
}

func line(_ track: NowPlaying?) -> String {
    guard let track, let data = try? JSONEncoder().encode(track) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

func emit(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

let remote = MediaRemote()
let args = CommandLine.arguments

if args.contains("--probe") {
    print(remote.diagnostics)
    remote.fetch { print(line($0)) }
    exit(0)
}

if let index = args.firstIndex(of: "--send"), index + 1 < args.count, let command = UInt32(args[index + 1]) {
    let ok = remote.send(command)
    // Команда уходит в mediaremoted асинхронно: выйти сразу — оборвать её (плеер так ничего и не получал).
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    emit(ok ? "ok" : "fail")
    exit(0)
}

if args.contains("--now") {
    remote.fetch { emit(line($0)) }
    exit(0)
}

if args.contains("--watch") {
    var last = ""
    let report = {
        remote.fetch { track in
            let text = line(track)
            DispatchQueue.main.async {
                guard text != last else { return }
                last = text
                emit(text)
            }
        }
    }
    remote.register()
    // В какой из центров MediaRemote шлёт уведомления, не документировано — слушаем оба.
    for symbol in ["kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                   "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"] {
        let name = remote.notificationName(symbol)
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in report() }
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { _ in report() }
    }
    // Подстраховка: не все плееры рассылают уведомления.
    Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in report() }
    report()
    // Бит закрыл stdin (вышел или упал) — помощнику больше незачем жить.
    FileHandle.standardInput.readabilityHandler = { handle in
        if handle.availableData.isEmpty { exit(0) }
    }
    RunLoop.main.run()
}

FileHandle.standardError.write(Data("usage: MyPetBitMedia --now | --send N | --watch | --probe\n".utf8))
exit(2)

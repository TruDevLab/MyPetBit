import AppKit
import ApplicationServices

/// Разовые события, на которые Бит отвечает короткой реакцией.
enum PetEvent {
    case locked, unlocked, didWake, screensChanged, clipboard, screenshot, downloadFinished
}

/// Следит за событиями системы. «Загрузки» и клавиатура — только когда включены (нужны разрешения macOS).
@MainActor
final class EventWatcher {
    var onEvent: ((PetEvent) -> Void)?

    private var clipboardTimer: Timer?
    private var clipboardCount = NSPasteboard.general.changeCount
    private var screenshotQuery: NSMetadataQuery?
    private var screenshotObserver: NSObjectProtocol?
    private var downloads: FolderWatcher?
    private var wantDownloads = false

    /// Доступ к «Загрузкам»: nil — не включали или macOS ещё спрашивает, true — открыли, false — отказано.
    var downloadsAccess: Bool? {
        guard wantDownloads, !openingDownloads else { return nil }
        return downloads != nil
    }
    private var openingDownloads = false
    private var keyMonitor: Any?
    /// Окно «Универсального доступа» за этот запуск уже показывали: macOS выводит его на каждый вызов, пока доступа нет.
    private var askedAccessibility = false
    /// Доступа ещё нет — тихо проверяем раз в 3 с, дали ли его в Настройках.
    private var trustPoll: Timer?
    private var keyTimes: [Date] = []

    /// Быстрый набор: не меньше 30 нажатий за последние 10 с (~180 в минуту). Сами клавиши не запоминаем.
    var isTypingFast: Bool {
        keyTimes.removeAll { $0 < Date().addingTimeInterval(-10) }
        return keyTimes.count >= 30
    }

    func start() {
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, "com.apple.screenIsLocked", .locked)
        observe(distributed, "com.apple.screenIsUnlocked", .unlocked)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification.rawValue, .didWake)
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification.rawValue, .screensChanged)

        // Копирование: смотрим только счётчик изменений буфера, содержимое не читаем.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkClipboard() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clipboardTimer = timer
    }

    /// Включает и выключает то, что требует разрешений. Безопасно вызывать повторно.
    /// askTyping — «Темп набора» только что включили руками: тогда (и только тогда) можно показать окно macOS.
    func configure(screenshots watchScreenshots: Bool, downloads watchDownloads: Bool, typing: Bool, askTyping: Bool = false) {
        // Скриншоты-файлы ищет Spotlight по признаку kMDItemIsScreenCapture: системные, CleanShot и др., в любой папке.
        // Доступ к папкам не нужен. Снимки в буфер обмена ловит checkClipboard.
        if watchScreenshots, screenshotQuery == nil {
            let query = NSMetadataQuery()
            query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
            query.searchScopes = [NSMetadataQueryUserHomeScope]
            screenshotObserver = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] note in
                let added = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [Any] ?? []
                if !added.isEmpty { MainActor.assumeIsolated { self?.onEvent?(.screenshot) } }
            }
            query.start()
            screenshotQuery = query
        } else if !watchScreenshots, let query = screenshotQuery {
            query.stop()
            if let observer = screenshotObserver { NotificationCenter.default.removeObserver(observer) }
            screenshotQuery = nil
            screenshotObserver = nil
        }

        wantDownloads = watchDownloads
        if watchDownloads, downloads == nil, !openingDownloads {
            openingDownloads = true
            let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            // Первое открытие «Загрузок» macOS подтверждает у пользователя, и open() ждёт ответа.
            // Поэтому в фоне: иначе Бит замирает и не рисуется, пока висит запрос.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let watcher = FolderWatcher(url: folder) { names in
                    // Браузер сначала пишет частичный файл, потом переименовывает — событие на итоговое имя.
                    let partial = ["download", "crdownload", "part", "partial", "opdownload"]
                    let finished = names.contains { name in
                        !name.hasPrefix(".") && !partial.contains((name as NSString).pathExtension.lowercased())
                    }
                    if finished { MainActor.assumeIsolated { self?.onEvent?(.downloadFinished) } }
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.openingDownloads = false
                        if self.wantDownloads { self.downloads = watcher }
                    }
                }
            }
        } else if !watchDownloads {
            downloads = nil
        }

        if typing, keyMonitor == nil {
            if AXIsProcessTrusted() {
                startTyping()
            } else {
                // Окно macOS — один раз за запуск и только когда «Темп набора» включили сами,
                // а не при каждом переключателе и не при каждом запуске.
                if askTyping && !askedAccessibility {
                    askedAccessibility = true
                    let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                    _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
                }
                waitForTrust()
            }
        } else if !typing {
            trustPoll?.invalidate()
            trustPoll = nil
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
                keyTimes = []
            }
        }
    }

    private func startTyping() {
        trustPoll?.invalidate()
        trustPoll = nil
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyTimes.append(Date()) }
        }
    }

    /// Доступ дали в Настройках — подсчёт включается сам, без перезапуска.
    private func waitForTrust() {
        guard trustPoll == nil else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted(), self.keyMonitor == nil else { return }
                self.startTyping()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        trustPoll = t
    }

    private func observe(_ center: NotificationCenter, _ name: String, _ event: PetEvent) {
        center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(event) }
        }
    }

    private func checkClipboard() {
        let count = NSPasteboard.general.changeCount
        guard count != clipboardCount else { return }
        clipboardCount = count
        // Картинка в буфере, пока работает системная утилита снимков, — это скриншот в буфер обмена (⌘⇧⌃4).
        // Читаем только типы содержимого, само содержимое — нет.
        let types = NSPasteboard.general.types ?? []
        let image = types.contains(.png) || types.contains(.tiff)
        let capturing = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.screencaptureui").isEmpty
        onEvent?(image && capturing ? .screenshot : .clipboard)
    }

}

/// Сообщает имена новых файлов в папке. Первое открытие папки «Рабочий стол» или «Загрузки» macOS подтверждает у пользователя.
final class FolderWatcher {
    private let url: URL
    private let source: DispatchSourceFileSystemObject
    private var known: Set<String>

    init?(url: URL, onNew: @escaping ([String]) -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }  // нет доступа — молча не следим
        self.url = url
        known = Self.list(url)
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Self.list(self.url)
            let added = now.subtracting(self.known)
            self.known = now
            if !added.isEmpty { onNew(Array(added)) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }

    private static func list(_ url: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
    }
}

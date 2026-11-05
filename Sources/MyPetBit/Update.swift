import AppKit
import CryptoKit
import Foundation
import Security

// Автообновление из релизов GitHub — по образцу Trunook.
//
// Раз в сутки (и после сна) спрашиваем `releases/latest`; новее нашей — качаем `.dmg`, сверяем сумму из описания
// релиза, монтируем, копируем приложение к себе и проверяем, что оно подписано тем же сертификатом, что и мы.
// Готово — Бит говорит об этом облачком; по кнопке «Обновить» отдельный процесс дожидается нашего выхода,
// подменяет бандл и запускает новый. Пароля не просим никогда.
//
// Подпись — главная проверка: сумму кладут в тот же ответ API, что и ссылку на образ, а закрытый ключ
// «MyPetBit Dev Signing» есть только у разработчика. Поэтому выпускать образы нужно после `make cert`
// и всегда одним сертификатом. Копия, подписанная локально (ad-hoc), сама не обновляется — Бит предлагает
// скачать вручную.

/// Журнал обновлений: приложения в момент подмены уже нет, и без журнала любой отказ выглядел бы как «не запустилось».
enum UpdateLog {
    static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MyPetBit.log")

    static func write(_ text: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [обновление] \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }
}

// MARK: - Версия

/// Номер версии, который можно сравнить: строки сравнивать нельзя («0.9.0» > «0.10.0» для строк).
struct AppVersion: Comparable, CustomStringConvertible {
    /// Части без хвостовых нулей: 1.1 и 1.1.0 равны.
    let parts: [Int]
    let isPrerelease: Bool
    let text: String

    /// «1.0.0», «v1.1.0», «1.1», «1.2.0-beta.1».
    init?(_ source: String) {
        var rest = Substring(source.trimmingCharacters(in: .whitespacesAndNewlines))
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        let head = rest.prefix { $0.isNumber || $0 == "." }
        let pieces = head.split(separator: ".", omittingEmptySubsequences: true)
        let numbers = pieces.compactMap { Int($0) }
        guard !numbers.isEmpty, numbers.count == pieces.count else { return nil }
        var normalized = numbers
        while normalized.count > 1, normalized.last == 0 { normalized.removeLast() }
        parts = normalized
        let tail = rest[head.endIndex...].first
        isPrerelease = tail == "-" || tail == "+"
        text = String(head)
    }

    static var current: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }

    var description: String { text }

    private func part(_ index: Int) -> Int { index < parts.count ? parts[index] : 0 }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.parts == rhs.parts && lhs.isPrerelease == rhs.isPrerelease }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) where lhs.part(index) != rhs.part(index) {
            return lhs.part(index) < rhs.part(index)
        }
        return lhs.isPrerelease && !rhs.isPrerelease  // числа равны: предрелиз младше выпуска
    }
}

// MARK: - Выпуск на GitHub

struct GitHubRelease: Equatable {
    let tag: String
    let version: AppVersion
    let assetName: String
    let assetURL: URL
    let assetSize: Int
    /// sha256 из описания выпуска (`RELEASE.md`); нет — не повод отказываться, подлинность держится на подписи.
    let checksum: String?
    let pageURL: URL?

    /// Ответ `/repos/:owner/:repo/releases/latest`. Образ — по расширению `.dmg`; черновики и предрелизы — мимо.
    static func parse(_ data: Data) -> GitHubRelease? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String, let version = AppVersion(tag) else { return nil }
        if root["draft"] as? Bool == true || root["prerelease"] as? Bool == true { return nil }
        guard let assets = root["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let name = asset["name"] as? String,
              let address = asset["browser_download_url"] as? String, let url = URL(string: address) else { return nil }
        return GitHubRelease(tag: tag, version: version, assetName: name, assetURL: url, assetSize: asset["size"] as? Int ?? 0,
                             checksum: checksum(inBody: root["body"] as? String ?? ""),
                             pageURL: (root["html_url"] as? String).flatMap(URL.init(string:)))
    }

    /// Первое отдельное слово из 64 шестнадцатеричных знаков.
    static func checksum(inBody body: String) -> String? {
        body.split(whereSeparator: { !$0.isHexDigit }).first { $0.count == 64 }.map { $0.lowercased() }
    }
}

// MARK: - Расписание

enum UpdateSchedule {
    /// Раз в сутки: лимит GitHub без ключа — 60 запросов в час на адрес, выпуски не ежечасные.
    static let interval: TimeInterval = 24 * 60 * 60

    /// manual — нажали «Проверить»: идёт всегда, даже при выключенной автопроверке.
    static func shouldCheck(now: Date, last: Date?, enabled: Bool, manual: Bool) -> Bool {
        if manual { return true }
        guard enabled else { return false }
        guard let last else { return true }
        if last > now { return true }  // часы перевели назад — иначе проверка залипла бы до «будущего»
        return now.timeIntervalSince(last) >= interval
    }
}

// MARK: - Состояние

enum UpdateFailure: Equatable {
    case network, rateLimited, badResponse, checksumMismatch, unsigned, wrongCertificate, damaged
    case notWritable, notInstalled, noSpace, installFailed

    var message: String {
        switch self {
        case .network: return L("Не удалось связаться с GitHub")
        case .rateLimited: return L("Слишком много проверок, попробую позже")
        case .badResponse: return L("Ответ GitHub не разобран")
        case .checksumMismatch: return L("Контрольная сумма не сошлась")
        case .unsigned: return L("Скачанное приложение не подписано")
        case .wrongCertificate: return L("Обновление подписано другим сертификатом")
        case .damaged: return L("Скачанное приложение повреждено")
        case .notWritable: return L("Нет прав на запись в папку приложения")
        case .notInstalled: return L("Перетащите MyPetBit в «Программы»")
        case .noSpace: return L("Не хватает места на диске")
        case .installFailed: return L("Установка не удалась")
        }
    }
}

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case downloading(GitHubRelease, progress: Double)
    /// Скачано, сумма сошлась, подпись проверена.
    case ready(GitHubRelease, staged: URL)
    /// Новее есть, но поставить самому нельзя (копия подписана локально) — только вручную со страницы релиза.
    case manual(GitHubRelease)
    case installing
    case failed(UpdateFailure)

    /// Строка для настроек.
    var text: String {
        switch self {
        case .idle: return ""
        case .checking: return L("Проверяю…")
        case .upToDate: return L("Версия последняя")
        case let .downloading(_, progress): return L("Загрузка %@ %%", "\(Int((progress * 100).rounded()))")
        case let .ready(release, _): return L("Готово к установке: %@", release.version.text)
        case let .manual(release): return L("Вышла %@ — скачайте вручную", release.version.text)
        case .installing: return L("Устанавливаю…")
        case let .failed(reason): return reason.message
        }
    }
}

// MARK: - Папка обновления

struct StagedUpdate: Codable, Equatable {
    let tag: String
    let version: String
    let build: String
    let checksum: String?
    let verifiedAt: Date
}

/// `Application Support`, а не `Caches`: Caches система вправе выгрести посреди загрузки.
enum UpdateStore {
    static let folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MyPetBit/Update", isDirectory: true)
    static var stagedApp: URL { folder.appendingPathComponent("MyPetBit.app") }
    private static var manifest: URL { folder.appendingPathComponent("staged.json") }

    static func imageFile(named name: String) -> URL { folder.appendingPathComponent(name) }

    @discardableResult
    static func makeFolder() -> Bool { (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil }

    static func staged() -> StagedUpdate? {
        guard let data = try? Data(contentsOf: manifest) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(StagedUpdate.self, from: data),
              FileManager.default.fileExists(atPath: stagedApp.path) else {
            clear()
            return nil
        }
        return record
    }

    static func write(_ record: StagedUpdate) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(record).write(to: manifest, options: .atomic)
    }

    static func clear() { try? FileManager.default.removeItem(at: folder) }
}

// MARK: - Образ

struct MountedImage: Equatable {
    let mountPoint: URL
    let device: String
}

enum DiskImage {
    /// Только на чтение, без показа в Finder, в случайную точку: имя тома предсказуемо, занять его мог кто угодно.
    static func attach(_ image: URL) -> MountedImage? {
        guard let output = run(["attach", "-nobrowse", "-readonly", "-noverify", "-noautoopen",
                                "-mountrandom", "/private/tmp", "-plist", image.path]) else { return nil }
        return mounted(fromPlist: output)
    }

    static func detach(_ image: MountedImage) {
        if run(["detach", "-quiet", image.mountPoint.path]) != nil { return }
        if !image.device.isEmpty { _ = run(["detach", "-force", "-quiet", image.device]) }
    }

    /// Ровно одно приложение в корне образа — гадать между двумя нельзя.
    static func application(in mountPoint: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles])) ?? []
        let applications = contents.filter { $0.pathExtension == "app" }
        return applications.count == 1 ? applications[0] : nil
    }

    static func mounted(fromPlist data: Data) -> MountedImage? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]] else { return nil }
        for entity in entities {
            guard let point = entity["mount-point"] as? String, !point.isEmpty else { continue }
            return MountedImage(mountPoint: URL(fileURLWithPath: point), device: entity["dev-entry"] as? String ?? "")
        }
        return nil
    }

    @discardableResult
    private static func run(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

// MARK: - Подпись

enum CodeSignatureCheck {
    enum Verdict: Equatable {
        case valid
        case rejected(UpdateFailure)
    }

    /// Подписана ли запущенная копия локально (ad-hoc): тогда её требование — хеш кода, и новой версии оно не подойдёт.
    static var selfIsAdHoc: Bool {
        guard let requirement = ownRequirement() else { return true }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return true }
        return (text as String).hasPrefix("cdhash")
    }

    /// Бандл подписан тем же, чем мы (вместе с вложенным помощником музыки — `kSecCSCheckNestedCode`).
    static func matchesSelf(_ bundle: URL) -> Verdict {
        guard let requirement = ownRequirement() else { return .rejected(.damaged) }
        var candidate: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(bundle as CFURL, [], &candidate)
        guard created == errSecSuccess, let candidate else { return verdict(for: created) }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate))
        var failure: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(candidate, flags, requirement, &failure)
        if status != errSecSuccess {
            UpdateLog.write("подпись отклонена — \(failure?.takeRetainedValue().localizedDescription ?? "\(status)")")
        }
        return verdict(for: status)
    }

    static func verdict(for status: OSStatus) -> Verdict {
        switch status {
        case errSecSuccess: return .valid
        case errSecCSUnsigned: return .rejected(.unsigned)
        case errSecCSReqFailed: return .rejected(.wrongCertificate)
        default: return .rejected(.damaged)
        }
    }

    private static func ownRequirement() -> SecRequirement? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var still: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &still) == errSecSuccess, let still else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(still, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }
}

// MARK: - Установка

enum InstallTarget: Equatable {
    case ready(URL)
    case refused(UpdateFailure)
}

enum UpdateInstaller {
    /// Ставим туда, откуда работаем; с образа и из карантина переноса — нет; без права записи — нет (пароль не просим).
    static func target(bundleURL: URL, parentIsWritable: Bool) -> InstallTarget {
        let path = bundleURL.path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") || path.hasPrefix("/private/var/folders/") {
            return .refused(.notInstalled)
        }
        guard parentIsWritable else { return .refused(.notWritable) }
        return .ready(bundleURL)
    }

    /// Готовит копию рядом с целью и запускает подменщика; nil — подменщик пошёл, вызывающему остаётся выйти.
    static func install(staged: URL, into target: URL) -> UpdateFailure? {
        // Подпись — вплотную перед копированием: папка заготовки доступна на запись любому процессу пользователя.
        if case let .rejected(reason) = CodeSignatureCheck.matchesSelf(staged) { return reason }
        let parent = target.deletingLastPathComponent()
        let pid = ProcessInfo.processInfo.processIdentifier
        let prepared = parent.appendingPathComponent(".MyPetBit-update-\(pid).app")
        let backup = parent.appendingPathComponent(".MyPetBit-previous-\(pid).app")
        try? FileManager.default.removeItem(at: prepared)
        do {
            try FileManager.default.copyItem(at: staged, to: prepared)
        } catch {
            UpdateLog.write("заготовка не легла рядом с целью — \(error.localizedDescription)")
            return .notWritable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "mypetbit-update", prepared.path, target.path, backup.path, String(pid)]
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: prepared)
            return .installFailed
        }
        UpdateLog.write("подменщик пошёл, выходим")
        return nil
    }

    /// Хвосты сорвавшейся установки старше часа.
    static func cleanLeftovers(near target: URL) {
        let parent = target.deletingLastPathComponent()
        let contents = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for item in contents where item.lastPathComponent.hasPrefix(".MyPetBit-update-") || item.lastPathComponent.hasPrefix(".MyPetBit-previous-") {
            let changed = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(changed) > 3600 { try? FileManager.default.removeItem(at: item) }
        }
    }

    /// Тело подменщика: текст уезжает аргументом `sh -c`, пути — позиционными аргументами в кавычках, без подстановок.
    /// Ждёт нашего выхода, сдвигает старое, ставит новое, при сбое возвращает старое, запускает.
    private static let script = """
    (
      exec >> "$HOME/Library/Logs/MyPetBit.log" 2>&1
      echo "[обновление] подменщик начал, цель $2"
      waited=0
      while kill -0 "$4" 2>/dev/null; do
        waited=$((waited + 1))
        if [ "$waited" -gt 100 ]; then echo "[обновление] приложение не вышло за десять секунд, ничего не трогаем"; exit 1; fi
        sleep 0.1
      done
      pkill -x MyPetBitMedia 2>/dev/null
      sleep 1
      if ! mv "$2" "$3"; then echo "[обновление] старое не сдвинулось, всё осталось на месте"; exit 1; fi
      if ! mv "$1" "$2"; then echo "[обновление] новое не встало, возвращаем старое"; mv "$3" "$2"; exit 1; fi
      rm -rf "$3"
      xattr -cr "$2" 2>/dev/null
      echo "[обновление] подменено, запускаем"
      /usr/bin/open "$2"
    ) &
    """
}

// MARK: - Служба

/// Проверяет GitHub, скачивает и держит проверенным до «Обновить». Состояние — на главном потоке.
final class UpdateService: NSObject {
    static let repository = "TruDevLab/MyPetBit"
    static var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases/latest")! }

    private(set) var state: UpdateState = .idle
    /// Состояние сменилось (на главном потоке).
    var onChange: ((UpdateState) -> Void)?
    /// Новая версия скачана и проверена — или вышла, но ставить её только вручную. Раз за запуск.
    var onAvailable: ((UpdateState) -> Void)?

    private let defaults = UserDefaults.standard
    private let session: URLSession
    private var timer: Timer?
    private var downloadSession: URLSession?
    private var downloading: GitHubRelease?
    private var announced = false
    private var lastAttempt: Date?

    var enabled: Bool {
        get { defaults.object(forKey: "autoUpdate") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoUpdate") }
    }
    private var lastCheck: Date? {
        get { defaults.object(forKey: "lastUpdateCheck") as? Date }
        set { defaults.set(newValue, forKey: "lastUpdateCheck") }
    }

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
        super.init()
    }

    func start() {
        UpdateInstaller.cleanLeftovers(near: Bundle.main.bundleURL.resolvingSymlinksInPath())
        restoreStaged()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.check(manual: false) }
        // Тик — 6 ч, порог — сутки: суточный таймер съедается сном крышки.
        let timer = Timer(timeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in self?.check(manual: false) }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func woke() { check(manual: false) }

    func check(manual: Bool) {
        let now = Date()
        guard UpdateSchedule.shouldCheck(now: now, last: lastCheck, enabled: enabled, manual: manual) else { return }
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        if !manual, let lastAttempt, now.timeIntervalSince(lastAttempt) < 3600 { return }
        lastAttempt = now
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Без своего имени GitHub отвечает отказом.
        request.setValue("MyPetBit/\(AppVersion.current?.text ?? "?")", forHTTPHeaderField: "User-Agent")
        settle(.checking)
        session.dataTask(with: request) { [weak self] data, response, failure in
            guard let self else { return }
            if let failure {
                UpdateLog.write("проверка не удалась — \(failure.localizedDescription)")
                return self.settle(.failed(.network))
            }
            self.received(data, response as? HTTPURLResponse)
        }.resume()
    }

    private func received(_ data: Data?, _ response: HTTPURLResponse?) {
        if let response, response.statusCode != 200 {
            // 404 — выпусков ещё нет: это «последняя», а не поломка.
            if response.statusCode == 404 { return settle(.upToDate(checkedAt: Date())) }
            let limited = response.statusCode == 403 && response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
            return settle(.failed(limited ? .rateLimited : .badResponse))
        }
        guard let data, let release = GitHubRelease.parse(data), let current = AppVersion.current else {
            return settle(.failed(.badResponse))
        }
        let now = Date()
        DispatchQueue.main.async { self.lastCheck = now }
        guard release.version > current else {
            if UpdateStore.staged() != nil { UpdateStore.clear() }
            return settle(.upToDate(checkedAt: now))
        }
        UpdateLog.write("найдена \(release.version), у нас \(current)")
        if CodeSignatureCheck.selfIsAdHoc { return becomeAvailable(.manual(release)) }
        if let staged = UpdateStore.staged(), AppVersion(staged.version) == release.version {
            return becomeAvailable(.ready(release, staged: UpdateStore.stagedApp))
        }
        UpdateStore.clear()
        guard UpdateStore.makeFolder() else { return settle(.failed(.installFailed)) }
        if release.assetSize > 0,
           let free = try? UpdateStore.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < Int64(release.assetSize) * 3 {
            return settle(.failed(.noSpace))
        }
        settle(.downloading(release, progress: 0))
        downloading = release
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        downloadSession = session
        session.downloadTask(with: release.assetURL).resume()
    }

    /// Сумма → монтирование → копия к себе → подпись своей копии → версия внутри.
    private func unpack(_ release: GitHubRelease, from image: URL) {
        defer { try? FileManager.default.removeItem(at: image) }
        if let expected = release.checksum {
            guard Self.checksum(of: image) == expected else { return settle(.failed(.checksumMismatch)) }
        }
        guard let mounted = DiskImage.attach(image) else { return settle(.failed(.damaged)) }
        defer { DiskImage.detach(mounted) }
        guard let source = DiskImage.application(in: mounted.mountPoint) else { return settle(.failed(.damaged)) }
        let destination = UpdateStore.stagedApp
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            return settle(.failed(.installFailed))
        }
        if case let .rejected(reason) = CodeSignatureCheck.matchesSelf(destination) {
            UpdateStore.clear()
            return settle(.failed(reason))
        }
        let info = NSDictionary(contentsOf: destination.appendingPathComponent("Contents/Info.plist"))
        guard (info?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) == release.version else {
            UpdateStore.clear()
            return settle(.failed(.badResponse))
        }
        UpdateStore.write(StagedUpdate(tag: release.tag, version: release.version.text, build: info?["CFBundleVersion"] as? String ?? "?",
                                       checksum: release.checksum, verifiedAt: Date()))
        UpdateLog.write("\(release.version) скачано и проверено")
        becomeAvailable(.ready(release, staged: destination))
    }

    /// Скачанное с прошлого раза: подпись перепроверяем — бандл, пролежавший сутки, не обязательно тот же.
    private func restoreStaged() {
        guard let staged = UpdateStore.staged() else { return }
        guard let ready = AppVersion(staged.version), let current = AppVersion.current, ready > current,
              CodeSignatureCheck.matchesSelf(UpdateStore.stagedApp) == .valid else {
            UpdateStore.clear()
            return
        }
        UpdateLog.write("с прошлого раза готово \(ready)")
    }

    /// Поставить скачанное и выйти; дальше работает подменщик.
    func install() {
        guard case let .ready(release, staged) = state else { return }
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let writable = FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
        switch UpdateInstaller.target(bundleURL: bundle, parentIsWritable: writable) {
        case let .refused(reason):
            settle(.failed(reason))
        case let .ready(target):
            settle(.installing)
            if let reason = UpdateInstaller.install(staged: staged, into: target) { return settle(.failed(reason)) }
            UpdateLog.write("ставим \(release.version), выходим")
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func becomeAvailable(_ next: UpdateState) {
        settle(next)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.announced else { return }
            self.announced = true
            self.onAvailable?(next)
        }
    }

    private func settle(_ next: UpdateState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state != next else { return }
            self.state = next
            self.onChange?(next)
        }
    }

    static func checksum(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var digest = SHA256()
        while let piece = try? handle.read(upToCount: 1 << 20), !piece.isEmpty { digest.update(data: piece) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension UpdateService: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let release = downloading else { return }
        let total = totalBytesExpectedToWrite > 0 ? Double(totalBytesExpectedToWrite) : Double(release.assetSize)
        guard total > 0 else { return }
        settle(.downloading(release, progress: min(1, Double(totalBytesWritten) / total)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let release = downloading else { return }
        // Временный файл система уносит сразу после возврата — переносим к себе первым делом.
        let image = UpdateStore.imageFile(named: release.assetName)
        try? FileManager.default.removeItem(at: image)
        guard (try? FileManager.default.moveItem(at: location, to: image)) != nil else { return settle(.failed(.installFailed)) }
        unpack(release, from: image)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            downloadSession?.finishTasksAndInvalidate()
            downloadSession = nil
            downloading = nil
        }
        if let error {
            UpdateLog.write("загрузка сорвалась — \(error.localizedDescription)")
            settle(.failed(.network))
        }
    }
}

import AppKit
import EventKit
import Foundation
import Testing
@testable import MyPetBit

/// Чистая логика Бита: то, что можно проверить без окон, экрана и чужих приложений.
@MainActor
struct CommandLineTests {
    @Test("Обычные команды остаются как набрали, длинные укорачиваются")
    func plainCommands() {
        #expect(CommandWatcher.describe("swift build -c release") == "swift build -c release")
        #expect(CommandWatcher.describe("npm run build") == "npm run build")
        #expect(CommandWatcher.describe("bash build.sh --fast") == "bash build.sh --fast")
        let long = CommandWatcher.describe("swift build -c release && tools/build-app.sh && open build/MyPetBit.app")
        #expect(long?.count == 40)
        #expect(long?.hasSuffix("…") == true)
    }

    @Test("Переменные окружения, sudo и time перед командой пропускаются")
    func prefixes() {
        #expect(CommandWatcher.describe("FOO=1 sudo make install") == "make install")
        #expect(CommandWatcher.describe("time cargo test") == "cargo test")
    }

    @Test("Интерактивные программы не считаются командами", arguments: [
        "vim notes.md", "ssh host", "claude", "python3", "node", "ipython", "bash", "less log.txt"
    ])
    func interactive(_ line: String) {
        #expect(CommandWatcher.describe(line) == nil)
    }

    @Test("Оболочка со скриптом или -c — команда, без них — интерактивная")
    func shells() {
        #expect(CommandWatcher.describe("sh -c \"sleep 16; exit 3\"") != nil)
        #expect(CommandWatcher.describe("python3 train.py") == "python3 train.py")
        #expect(CommandWatcher.describe("zsh") == nil)
    }
}

struct AgentEventTests {
    @Test("Claude Code: запрос, конец ответа, разрешение")
    func claude() throws {
        let start = try #require(Notices.normalize(agent: "claude", event: "UserPromptSubmit",
                                                   json: ["session_id": "s1", "cwd": "/tmp/project"]))
        #expect(start["kind"] == "start")
        #expect(start["session"] == "s1")
        #expect(start["cwd"] == "/tmp/project")
        let ask = Notices.normalize(agent: "claude", event: "Notification",
                                    json: ["message": "Claude needs your permission to use Bash"])
        #expect(ask?["kind"] == "ask")
        let wait = Notices.normalize(agent: "claude", event: "Notification", json: ["message": "Claude is waiting for your input"])
        #expect(wait?["kind"] == "wait")
    }

    @Test("Cursor: идентификатор беседы, папка проекта и статус")
    func cursor() throws {
        let stop = try #require(Notices.normalize(agent: "cursor", event: "stop", json: [
            "conversation_id": "c1", "status": "aborted", "workspace_roots": ["/tmp/my-app"]
        ]))
        #expect(stop["kind"] == "stop")
        #expect(stop["session"] == "c1")
        #expect(stop["cwd"] == "/tmp/my-app")
        #expect(stop["status"] == "aborted")
    }

    @Test("Codex notify и Kimi Code")
    func codexAndKimi() {
        let codex = Notices.normalize(agent: "codex", event: "agent-turn-complete", json: ["thread-id": "t1", "cwd": "/tmp"])
        #expect(codex?["kind"] == "stop")
        #expect(codex?["session"] == "t1")
        let kimi = Notices.normalize(agent: "kimi", event: "PermissionRequest",
                                     json: ["session_id": "k1", "session_title": "Починить вход"])
        #expect(kimi?["kind"] == "ask")
        #expect(kimi?["title"] == "Починить вход")
    }

    @Test("Посторонние события агентов пропускаются")
    func ignored() {
        #expect(Notices.normalize(agent: "kimi", event: "Notification", json: ["notification_type": "task.completed"]) == nil)
        #expect(Notices.normalize(agent: "cursor", event: "afterFileEdit", json: [:]) == nil)
    }
}

struct LanguageTests {
    @Test("Минуты по-русски склоняются", arguments: [
        (1, "минуту"), (2, "минуты"), (4, "минуты"), (5, "минут"), (11, "минут"), (14, "минут"), (21, "минуту"), (22, "минуты")
    ])
    func russian(_ n: Int, _ word: String) {
        #expect(Lang.minutes(n, in: "ru") == word)
    }

    @Test("Минуты по-английски и по-китайски")
    func others() {
        #expect(Lang.minutes(1, in: "en") == "minute")
        #expect(Lang.minutes(5, in: "en") == "minutes")
        #expect(Lang.minutes(5, in: "zh") == "分钟")
    }

    @Test("У каждой строки перевода те же подстановки, что у ключа")
    func translations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let spec = try NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:@|\\.\\d+f|%)")
        func specs(_ s: String) -> [String] {
            spec.matches(in: s, range: NSRange(s.startIndex..., in: s)).map {
                String(s[Range($0.range, in: s)!]).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression)
            }.sorted()
        }
        for language in ["en", "zh-Hans"] {
            let url = root.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
            let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
            #expect(table.count > 300)
            for (key, value) in table {
                #expect(specs(key) == specs(value), "\(language): \(key)")
            }
        }
    }

    @Test("У каждой строки L(\"…\") в коде есть английский и китайский перевод")
    func everyKeyTranslated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/MyPetBit")
        let call = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)""#)
        var keys: Set<String> = []
        for file in try FileManager.default.contentsOfDirectory(atPath: sources.path) where file.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for match in call.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                // Как Swift и .strings понимают экранирование: \n — перевод строки.
                keys.insert(String(text[Range(match.range(at: 1), in: text)!]).replacingOccurrences(of: "\\n", with: "\n"))
            }
        }
        #expect(keys.count > 300)
        for language in ["en", "zh-Hans"] {
            let url = root.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
            let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
            for key in keys.sorted() where table[key] == nil {
                Issue.record("\(language): нет перевода для «\(key)»")
            }
        }
    }
}

struct SavedStateTests {
    @Test("Старое сохранение дня без самого долгого отрезка читается")
    func oldDayLog() throws {
        let json = #"{"first": 0, "last": 3600, "activeSeconds": 120, "breaks": 2, "affection": 1.5}"#
        let day = try JSONDecoder().decode(DayLog.self, from: Data(json.utf8))
        #expect(day.activeSeconds == 120)
        #expect(day.breaks == 2)
        #expect(day.longestStreak == 0)
    }

    @Test("Важность реплик: встреча > уведомление > болтовня")
    func speechOrder() {
        #expect(Speech.Kind.meeting > Speech.Kind.notice)
        #expect(Speech.Kind.notice > Speech.Kind.chat)
    }

    @Test("Реплика со сроком устаревает, без срока — нет")
    func speechExpiry() {
        var speech = Speech(text: "Встреча начинается!", kind: .meeting)
        #expect(!speech.isExpired)
        speech.expires = Date().addingTimeInterval(60)
        #expect(!speech.isExpired)
        speech.expires = Date().addingTimeInterval(-1)
        #expect(speech.isExpired)
    }
}

@MainActor
struct MeetingLinkTests {
    @Test("Ссылка видеосвязи важнее остальных, ищется и в заметках")
    func videoFirst() {
        let event = EKEvent(eventStore: EKEventStore())
        event.location = "Переговорка 3, https://example.com/room"
        event.notes = "Повестка: https://docs.example.com\nПодключение: https://meet.google.com/abc-defg-hij"
        #expect(MeetingWatcher.joinLink(event)?.host == "meet.google.com")
    }

    @Test("Без видеосвязи — ссылка из места встречи, из заметок — нет")
    func placeOnly() {
        let event = EKEvent(eventStore: EKEventStore())
        event.location = "https://example.com/room"
        event.notes = "https://docs.example.com"
        #expect(MeetingWatcher.joinLink(event)?.absoluteString == "https://example.com/room")
        let none = EKEvent(eventStore: EKEventStore())
        none.notes = "https://docs.example.com"
        #expect(MeetingWatcher.joinLink(none) == nil)
    }
}

struct DesktopTidyTests {
    private let screen = CGSize(width: 1000, height: 640)

    @Test("Ответ Finder разбирается построчно: имя, x, y, папка или файл")
    func parse() {
        let icons = DesktopTidy.parse("Проекты\t900\t60\tfolder\nотчёт 2.pdf\t120\t300\tfile\nмусор\n")
        #expect(icons == [
            DesktopTidy.Icon(name: "Проекты", position: CGPoint(x: 900, y: 60), isFolder: true),
            DesktopTidy.Icon(name: "отчёт 2.pdf", position: CGPoint(x: 120, y: 300), isFolder: false)
        ])
    }

    @Test("Без запомненного — столбцом от правого верхнего угла, папки первыми, файлы по типу")
    func grid() {
        let icons = [
            DesktopTidy.Icon(name: "b.txt", position: .zero, isFolder: false),
            DesktopTidy.Icon(name: "a.pdf", position: .zero, isFolder: false),
            DesktopTidy.Icon(name: "Папка", position: .zero, isFolder: true)
        ]
        let places = DesktopTidy.layout(icons, remembered: [:], screen: screen, top: 40)
        #expect(places["Папка"] == CGPoint(x: 1000 - 59 - 10, y: 86))
        #expect(places["a.pdf"] == CGPoint(x: 931, y: 204))
        #expect(places["b.txt"] == CGPoint(x: 931, y: 322))
    }

    @Test("Запомненные — на свои места, новые обходят занятые клетки")
    func remembered() {
        let icons = [
            DesktopTidy.Icon(name: "Старое", position: CGPoint(x: 10, y: 10), isFolder: true),
            DesktopTidy.Icon(name: "Новое", position: .zero, isFolder: true)
        ]
        let places = DesktopTidy.layout(icons, remembered: ["Старое": CGPoint(x: 931, y: 86)], screen: screen, top: 40)
        #expect(places["Старое"] == CGPoint(x: 931, y: 86))
        #expect(places["Новое"] == CGPoint(x: 931, y: 204))
    }

    @Test("Под виджеты значки не ставятся: macOS их оттуда выталкивает")
    func widgets() {
        let icons = [DesktopTidy.Icon(name: "Папка", position: .zero, isFolder: true)]
        // Виджет 180×180 в правом верхнем углу, как часы: первая клетка под ним — пропускается.
        let widget = CGRect(x: 812, y: 44, width: 180, height: 180)
        let places = DesktopTidy.layout(icons, remembered: [:], screen: screen, top: 40, avoid: [widget])
        #expect(places["Папка"] == CGPoint(x: 931, y: 322))
    }

    @Test("Не влезло на стол — лишнее не трогается")
    func overflow() {
        let icons = (0..<200).map { DesktopTidy.Icon(name: "f\($0)", position: .zero, isFolder: false) }
        let places = DesktopTidy.layout(icons, remembered: [:], screen: CGSize(width: 300, height: 340), top: 40)
        #expect(places.count == 4)  // 2 строки × 2 столбца
    }
}

struct LoadSpikeTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// Минуты спокойствия, затем значения по порядку; опрос — раз в 5 секунд, как у SystemMonitor.
    private func feed(_ spikes: inout LoadSpikes, calm: Int, cpu: Double = 0.1, memory: Double = 0.5,
                      then values: [(cpu: Double, memory: Double)]) -> [LoadSpikes.Spike] {
        var found: [LoadSpikes.Spike] = []
        var t = start
        for _ in 0..<(calm * 12) {
            found += spikes.add(cpu: cpu, memory: memory, diskUsedBytes: nil, diskTotalBytes: nil, at: t)
            t += 5
        }
        for v in values {
            found += spikes.add(cpu: v.cpu, memory: v.memory, diskUsedBytes: nil, diskTotalBytes: nil, at: t)
            t += 5
        }
        return found
    }

    @Test("Спокойный процессор вдруг загрузился — один раз, без повторов, пока не остынет")
    func cpu() {
        var spikes = LoadSpikes()
        let found = feed(&spikes, calm: 3, then: [(0.9, 0.5), (0.95, 0.5), (0.92, 0.5)])
        #expect(found.map(\.kind) == [.cpu])
        #expect(found.first?.now == 0.9)
    }

    @Test("Долгая высокая нагрузка — не всплеск: сборка всегда грузит процессор")
    func steadyCpu() {
        var spikes = LoadSpikes()
        #expect(feed(&spikes, calm: 3, cpu: 0.85, then: [(0.9, 0.5)]).isEmpty)
    }

    @Test("Память: выросла на 15 пунктов и перевалила за 85 %")
    func memory() {
        var spikes = LoadSpikes()
        let found = feed(&spikes, calm: 3, memory: 0.6, then: [(0.1, 0.88)])
        #expect(found.map(\.kind) == [.memory])
        #expect(found.first?.before == 0.6)
        var steady = LoadSpikes()
        #expect(feed(&steady, calm: 3, memory: 0.84, then: [(0.1, 0.88)]).isEmpty)
    }

    @Test("Диск: за 10 минут занято на 5 ГБ и 2 % больше")
    func disk() {
        var spikes = LoadSpikes()
        let total = 500e9
        #expect(spikes.add(cpu: 0, memory: 0.5, diskUsedBytes: 300e9, diskTotalBytes: total, at: start).isEmpty)
        #expect(spikes.add(cpu: 0, memory: 0.5, diskUsedBytes: 305e9, diskTotalBytes: total, at: start + 240).isEmpty)  // 5 ГБ < 2 %
        let found = spikes.add(cpu: 0, memory: 0.5, diskUsedBytes: 312e9, diskTotalBytes: total, at: start + 480)
        #expect(found == [LoadSpikes.Spike(kind: .disk, now: 312e9, before: 300e9, minutes: 8)])
    }

    @Test("Вывод ps: число и имя с пробелами, сам ps пропускается")
    func parsePs() {
        let top = TopProcess.parse("  0,5 ps\n 312.4 Google Chrome Helper (Renderer)\n 20.1 Xcode\n")
        #expect(top?.name == "Google Chrome Helper (Renderer)")
        #expect(top?.value == 312.4)
    }
}

struct FileShelfTests {
    private func sandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mypetbit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Перенос в папку: файл уезжает, одноимённый не затирается")
    func move() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let from = root.appendingPathComponent("from"), to = root.appendingPathComponent("to")
        try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        let file = from.appendingPathComponent("отчёт.txt")
        try "новый".write(to: file, atomically: true, encoding: .utf8)
        try "старый".write(to: to.appendingPathComponent("отчёт.txt"), atomically: true, encoding: .utf8)
        let moved = try FileShelf.move(file, into: to)
        #expect(moved.lastPathComponent == "отчёт 2.txt")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try String(contentsOf: to.appendingPathComponent("отчёт.txt"), encoding: .utf8) == "старый")
    }

    @Test("Действия с файлами: ZIP — всем, распаковка — только архивам")
    func actions() {
        let png = URL(fileURLWithPath: "/tmp/a.png"), zip = URL(fileURLWithPath: "/tmp/c.zip")
        #expect(FileShelf.actions(for: [zip]) == [.zip, .unzip])
        #expect(FileShelf.actions(for: [png, zip]) == [.zip])
        #expect(FileShelf.baseName(URL(fileURLWithPath: "/tmp/фото.tar.gz")) == "фото")
    }

    @Test("ZIP и обратно: архив рядом, распаковка без лишней папки")
    func zipRoundTrip() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Проект")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "привет".write(to: folder.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let archive = try #require(try FileShelf.perform(.zip, on: [folder]).first)
        #expect(archive.lastPathComponent == "Проект.zip")
        try FileManager.default.removeItem(at: folder)
        let unpacked = try #require(try FileShelf.perform(.unzip, on: [archive]).first)
        #expect(unpacked.lastPathComponent == "Проект")
        #expect(try String(contentsOf: unpacked.appendingPathComponent("readme.txt"), encoding: .utf8) == "привет")
    }
}

struct ConverterTests {
    private let macOnly: Set<ConvertEngine> = [.builtIn]
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }
    private func ids(_ options: [ConvertOption]) -> [String] { options.map { "\($0.id)@\($0.engine.rawValue)" } }

    @Test("Ваши примеры на голой macOS: odt→docx, md→docx, jpg→png, heic→jpg, сжать видео; pptx — нечем")
    func builtInOnly() {
        #expect(ids(Converters.options(for: [url("a.odt")], available: macOnly)).contains("format-docx@builtIn"))
        #expect(ids(Converters.options(for: [url("a.md")], available: macOnly)).contains("format-docx@builtIn"))
        #expect(ids(Converters.options(for: [url("a.jpg")], available: macOnly)).contains("format-png@builtIn"))
        #expect(!ids(Converters.options(for: [url("a.jpg")], available: macOnly)).contains("format-jpg@builtIn"))
        #expect(ids(Converters.options(for: [url("a.HEIC")], available: macOnly)).contains("format-jpg@builtIn"))
        #expect(ids(Converters.options(for: [url("a.mov")], available: macOnly)).prefix(2) == ["videoHEVC@builtIn", "videoH264@builtIn"])
        #expect(Converters.options(for: [url("a.pptx")], available: macOnly).isEmpty)
        #expect(Converters.options(for: [url("a.mkv")], available: macOnly).isEmpty)
    }

    @Test("Лучший из найденных: Keynote для pptx, LibreOffice для документов, pandoc для Markdown, ffmpeg для mkv")
    func bestEngine() {
        let all = Set(ConvertEngine.allCases)
        #expect(ids(Converters.options(for: [url("a.pptx")], available: [.builtIn, .keynote])).contains("format-pdf@keynote"))
        #expect(ids(Converters.options(for: [url("a.pptx")], available: all)).contains("format-pdf@keynote"))
        #expect(ids(Converters.options(for: [url("a.odp")], available: all)).contains("format-pdf@libreOffice"))
        #expect(ids(Converters.options(for: [url("a.odt")], available: all)).contains("format-docx@libreOffice"))
        #expect(ids(Converters.options(for: [url("a.docx")], available: [.builtIn, .pages])).contains("format-pdf@pages"))
        #expect(ids(Converters.options(for: [url("a.md")], available: all)).contains("format-docx@pandoc"))
        #expect(ids(Converters.options(for: [url("a.md")], available: all)).contains("format-pdf@builtIn"))
        #expect(ids(Converters.options(for: [url("a.mkv")], available: all)).contains("videoHEVC@ffmpeg"))
        #expect(ids(Converters.options(for: [url("a.png")], available: all)).contains("format-webp@cwebp"))
        #expect(Converters.options(for: [url("a.png"), url("b.mov")], available: all).isEmpty)
    }

    @Test("Markdown: заголовок, список, жирный и ссылка — по своим строкам")
    func markdown() {
        let text = Converters.renderMarkdown("# Отчёт\n\nПривет, **мир**!\n\n- раз\n- два\n\n1. первый\n2. второй\n\n[сайт](https://example.com)")
        let lines = text.string.components(separatedBy: "\n")
        #expect(lines == ["Отчёт", "Привет, мир!", "• раз", "• два", "1. первый", "2. второй", "сайт"])
        let heading = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect((heading?.pointSize ?? 0) > 20)
        let link = (text.string as NSString).range(of: "сайт")
        #expect(text.attribute(.link, at: link.location, effectiveRange: nil) != nil)
    }

    @Test("Скрипты Keynote, Pages и Numbers собираются", arguments: [
        (ConvertEngine.keynote, "pdf"), (.keynote, "pptx"), (.pages, "docx"), (.pages, "epub"), (.numbers, "xlsx")
    ])
    func iWork(_ engine: ConvertEngine, _ ext: String) throws {
        // Слова вроде «Microsoft PowerPoint» osacompile знает только из словаря установленного приложения:
        // на машине без iWork (сборка на GitHub) проверять нечего.
        let ids: [ConvertEngine: String] = [.keynote: "com.apple.iWork.Keynote", .pages: "com.apple.iWork.Pages",
                                            .numbers: "com.apple.iWork.Numbers"]
        guard let id = ids[engine], NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mypetbit-\(UUID().uuidString).scpt")
        defer { try? FileManager.default.removeItem(at: out) }
        process.arguments = ["-o", out.path, "-e", Converters.iWorkScript(engine, ext)]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("По-настоящему: odt → docx (textutil), картинка → jpg (sips)")
    @MainActor
    func realRuns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mypetbit-conv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let txt = root.appendingPathComponent("заметка.txt")
        try "Привет".write(to: txt, atomically: true, encoding: .utf8)
        let task = ConvertTask()
        try task.run("/usr/bin/textutil", ["-convert", "odt", txt.path])
        let odt = root.appendingPathComponent("заметка.odt")
        let made = try await convert(ConvertOption(job: .format("docx"), engine: .builtIn), [odt])
        #expect(made.map(\.lastPathComponent) == ["заметка.docx"])
        let docx = try NSAttributedString(url: made[0], options: [:], documentAttributes: nil)
        #expect(docx.string.contains("Привет"))

        let png = root.appendingPathComponent("кадр.png")
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])).write(to: png)
        let jpg = try await convert(ConvertOption(job: .format("jpg"), engine: .builtIn), [png])
        #expect(jpg.map(\.lastPathComponent) == ["кадр.jpg"])
    }

    @Test("По-настоящему: Markdown → docx и PDF своими силами")
    @MainActor
    func markdownRuns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mypetbit-md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let md = root.appendingPathComponent("план.md")
        try "# План\n\n- **сделать** окно\n- проверить".write(to: md, atomically: true, encoding: .utf8)
        let docx = try await convert(ConvertOption(job: .format("docx"), engine: .builtIn), [md])
        let back = try NSAttributedString(url: docx[0], options: [:], documentAttributes: nil)
        #expect(back.string.contains("• сделать окно"))
        let pdf = try await convert(ConvertOption(job: .format("pdf"), engine: .builtIn), [md])
        #expect(pdf.first?.pathExtension == "pdf")
        #expect((try? Data(contentsOf: pdf[0]).prefix(4)) == Data("%PDF".utf8))
    }

    @MainActor
    private func convert(_ option: ConvertOption, _ urls: [URL]) async throws -> [URL] {
        try await withCheckedThrowingContinuation { continuation in
            _ = Converters.run(option, on: urls, progress: { _ in }, done: { result in
                continuation.resume(with: result.mapError { $0 as Error })
            })
        }
    }
}

@MainActor
struct MusicTests {
    @Test("Строка помощника: трек, пустой ответ, мусор")
    func parse() {
        let track = MusicControl.parse(#"{"title":"Tell Me Why","artist":"Mos Elian","app":"Яндекс Музыка","playing":false}"#)
        #expect(track?.title == "Tell Me Why")
        #expect(track?.app == "Яндекс Музыка")
        #expect(track?.playing == false)
        #expect(MusicControl.parse("{}") == nil)
        #expect(MusicControl.parse(#"{"playing":true}"#) == nil)
        #expect(MusicControl.parse("fail") == nil)
    }

    @Test("Номера команд — как у MediaRemote")
    func commands() {
        #expect(MusicControl.Command.toggle.rawValue == 2)
        #expect(MusicControl.Command.next.rawValue == 4)
        #expect(MusicControl.Command.previous.rawValue == 5)
    }
}

struct IntegrationTests {
    /// Временный дом с «установленными» агентами, исполняемый «Бит» и хук zsh.
    private func sandbox() throws -> (Integrations, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mypetbit-home-\(UUID().uuidString)")
        for dir in [".claude", ".cursor", ".config/opencode", ".codex", ".kimi-code", "app"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let bin = home.appendingPathComponent("app/MyPetBit")
        try "#!/bin/sh\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        let zsh = home.appendingPathComponent("app/mypetbit.zsh")
        try "# hook\n".write(to: zsh, atomically: true, encoding: .utf8)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return (Integrations(home: home, bin: bin.path, templates: repo.appendingPathComponent("integrations"), zshScript: zsh.path), home)
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test("Claude Code: свои хуки добавляются один раз, чужие и остальные настройки остаются")
    func claude() throws {
        let (integrations, home) = try sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".claude/settings.json")
        try #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(integrations.state(.claude) == .off)
        try integrations.connect(.claude)
        try integrations.connect(.claude)  // повторно — без дублей
        #expect(integrations.state(.claude) == .on)
        let root = try json(file)
        #expect(root["model"] as? String == "opus")
        let stop = try #require((root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        #expect(stop.count == 2)
        #expect(FileManager.default.fileExists(atPath: file.path + ".bak-mypetbit"))
        try integrations.disconnect(.claude)
        #expect(integrations.state(.claude) == .off)
        let left = try #require((try json(file)["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        #expect(left.count == 1)
    }

    @Test("Путь в никуда (переименовали, переложили) чинится сам")
    func repair() throws {
        let (integrations, home) = try sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".cursor/hooks.json")
        try #"{"version":1,"hooks":{"stop":[{"command":"'/nowhere/DeskPet.app/Contents/MacOS/DeskPet' --agent-hook cursor"}]}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(integrations.state(.cursor) == .broken)
        #expect(integrations.repairBroken() == [.cursor])
        #expect(integrations.state(.cursor) == .on)
        let stop = try #require((try json(file)["hooks"] as? [String: Any])?["stop"] as? [[String: Any]])
        #expect(stop.count == 1)
    }

    @Test("Codex: чужой notify не трогаем; свой — до первой таблицы")
    func codex() throws {
        let (integrations, home) = try sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".codex/config.toml")
        try "notify = [\"other-tool\"]\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(integrations.state(.codex) == .blocked)
        #expect(throws: IntegrationError.self) { try integrations.connect(.codex) }
        try "model = \"o3\"\n\n[profiles.fast]\nmodel = \"mini\"\n".write(to: file, atomically: true, encoding: .utf8)
        try integrations.connect(.codex)
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        let notify = try #require(lines.firstIndex { $0.hasPrefix("notify") })
        let table = try #require(lines.firstIndex { $0.hasPrefix("[profiles") })
        #expect(notify < table)
        #expect(integrations.state(.codex) == .on)
    }

    @Test("Kimi Code и zsh: свой блок между метками, чужое остаётся, старая строка DeskPet заменяется")
    func kimiAndZsh() throws {
        let (integrations, home) = try sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        let kimi = home.appendingPathComponent(".kimi-code/config.toml")
        try "[[hooks]]\nevent = \"Stop\"\ncommand = \"notify-send done\"\n".write(to: kimi, atomically: true, encoding: .utf8)
        try integrations.connect(.kimiCode)
        let text = try String(contentsOf: kimi, encoding: .utf8)
        #expect(text.contains("notify-send done"))
        #expect(text.components(separatedBy: "--agent-hook kimi").count - 1 == 3)  // TurnStarted, Stop, PermissionRequest
        try integrations.disconnect(.kimiCode)
        #expect(try String(contentsOf: kimi, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            == "[[hooks]]\nevent = \"Stop\"\ncommand = \"notify-send done\"")

        let zshrc = home.appendingPathComponent(".zshrc")
        try "export A=1\n# Бит (DeskPet): долгие команды\n[[ -r \"/old/deskpet.zsh\" ]] && source \"/old/deskpet.zsh\"\n"
            .write(to: zshrc, atomically: true, encoding: .utf8)
        #expect(integrations.state(.zsh) == .broken)
        try integrations.connect(.zsh)
        let rc = try String(contentsOf: zshrc, encoding: .utf8)
        #expect(rc.hasPrefix("export A=1\n"))
        #expect(!rc.contains("deskpet"))
        #expect(integrations.state(.zsh) == .on)
    }

    @Test("OpenCode — плагин из шаблона с путём к этому Биту; Codex без папки — не установлен")
    func opencode() throws {
        let (integrations, home) = try sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        try integrations.connect(.opencode)
        let plugin = try String(contentsOf: home.appendingPathComponent(".config/opencode/plugins/mypetbit.js"), encoding: .utf8)
        #expect(plugin.contains(integrations.bin))
        #expect(integrations.state(.opencode) == .on)
        #expect(integrations.state(.kimiCLI) == .missing)
    }
}

struct UpdateTests {
    @Test("Версии сравниваются числами, а не строками; хвостовые нули и «v» не мешают")
    func versions() throws {
        let a = try #require(AppVersion("0.9.0")), b = try #require(AppVersion("v0.10.0"))
        #expect(a < b)
        #expect(AppVersion("1.1") == AppVersion("1.1.0"))
        #expect(try #require(AppVersion("1.2.0-beta.1")) < #require(AppVersion("1.2.0")))
        #expect(AppVersion("абв") == nil)
    }

    @Test("Ответ GitHub: образ .dmg, сумма из описания; черновики и предрелизы — мимо")
    func release() throws {
        let sum = String(repeating: "ab", count: 32)
        let json = """
        {"tag_name":"v1.1.0","draft":false,"prerelease":false,"html_url":"https://github.com/TruDevLab/MyPetBit/releases/tag/v1.1.0",
         "body":"Текст\\n`shasum -a 256 MyPetBit-1.1.0.dmg`: `\(sum)`",
         "assets":[{"name":"notes.txt","browser_download_url":"https://x/notes.txt","size":3},
                   {"name":"MyPetBit-1.1.0.dmg","browser_download_url":"https://x/MyPetBit-1.1.0.dmg","size":2016416}]}
        """
        let release = try #require(GitHubRelease.parse(Data(json.utf8)))
        #expect(release.version.text == "1.1.0")
        #expect(release.assetName == "MyPetBit-1.1.0.dmg")
        #expect(release.checksum == sum)
        #expect(GitHubRelease.parse(Data(json.replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true").utf8)) == nil)
    }

    @Test("Расписание: раз в сутки, кнопка — всегда, часы назад не залипают")
    func schedule() {
        let now = Date()
        #expect(UpdateSchedule.shouldCheck(now: now, last: nil, enabled: true, manual: false))
        #expect(!UpdateSchedule.shouldCheck(now: now, last: now.addingTimeInterval(-3600), enabled: true, manual: false))
        #expect(UpdateSchedule.shouldCheck(now: now, last: now.addingTimeInterval(-25 * 3600), enabled: true, manual: false))
        #expect(!UpdateSchedule.shouldCheck(now: now, last: nil, enabled: false, manual: false))
        #expect(UpdateSchedule.shouldCheck(now: now, last: now, enabled: false, manual: true))
        #expect(UpdateSchedule.shouldCheck(now: now, last: now.addingTimeInterval(3600), enabled: true, manual: false))
    }

    @Test("Ставим только туда, откуда работаем: не с образа, не из карантина, без прав — не ставим")
    func target() {
        let app = URL(fileURLWithPath: "/Applications/MyPetBit.app")
        #expect(UpdateInstaller.target(bundleURL: app, parentIsWritable: true) == .ready(app))
        #expect(UpdateInstaller.target(bundleURL: app, parentIsWritable: false) == .refused(.notWritable))
        #expect(UpdateInstaller.target(bundleURL: URL(fileURLWithPath: "/Volumes/MyPetBit 1.0.0/MyPetBit.app"), parentIsWritable: true)
            == .refused(.notInstalled))
        #expect(UpdateInstaller.target(bundleURL: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/y/MyPetBit.app"),
                                       parentIsWritable: true) == .refused(.notInstalled))
    }

    @Test("Ответ hdiutil: точка монтирования из нужной записи")
    func mounted() throws {
        let plist: [String: Any] = ["system-entities": [["dev-entry": "/dev/disk4"],
                                                        ["dev-entry": "/dev/disk4s1", "mount-point": "/private/tmp/dmg.x1"]]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(DiskImage.mounted(fromPlist: data) == MountedImage(mountPoint: URL(fileURLWithPath: "/private/tmp/dmg.x1"), device: "/dev/disk4s1"))
    }
}

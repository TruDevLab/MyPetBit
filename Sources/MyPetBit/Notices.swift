import AppKit
import Darwin
import EventKit

/// Что сообщают Биту снаружи: хуки ИИ-агентов (Claude Code, Cursor, OpenCode, Codex, Kimi) и любые скрипты —
/// через распределённые уведомления.
enum Notices {
    static let say = Notification.Name("com.trudevlab.mypetbit.say")
    static let agent = Notification.Name("com.trudevlab.mypetbit.agent")
    static let command = Notification.Name("com.trudevlab.mypetbit.command")

    /// Режим команды: бинарник Бита запускают из хука или скрипта, он передаёт сообщение запущенному Биту и выходит.
    /// `MyPetBit --say "Сборка готова" [--detail "текст"]` — реплика.
    /// `MyPetBit --agent-hook <агент>` — для хуков агентов: claude, cursor, opencode, kimi, codex. JSON события — на stdin
    /// (у Codex `notify` передаёт его последним аргументом). `--claude-hook` — то же, что `--agent-hook claude`.
    /// `MyPetBit --command-done --status 0 --seconds 75 --tty /dev/ttys003 --shell 123 --command "make"` — из хука zsh
    /// (`tools/mypetbit.zsh`): команда закончилась, с кодом выхода.
    /// Возвращает false, если это обычный запуск.
    static func runCommand(_ args: [String]) -> Bool {
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        if let text = value("--say") {
            var info = ["text": text]
            info["detail"] = value("--detail")
            info["app"] = guiAncestor().map { String($0) }
            post(say, info)
            return true
        }
        if let agent = args.contains("--claude-hook") ? "claude" : value("--agent-hook") {
            // Хук не должен ничего ломать: любые сбои — молча.
            let data: Data
            if let last = args.last, last.hasPrefix("{") {
                data = Data(last.utf8)  // Codex notify: JSON последним аргументом
            } else {
                data = FileHandle.standardInput.readDataToEndOfFile()
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let event = (json["hook_event_name"] ?? json["type"]) as? String ?? ""
            // Cursor ждёт ответ в JSON: продолжать запрос, ничего не добавлять после ответа.
            if agent == "cursor" {
                print(event == "beforeSubmitPrompt" ? #"{"continue": true}"# : "{}")
                fflush(stdout)
            }
            if var info = normalize(agent: agent, event: event, json: json) {
                info["app"] = guiAncestor().map { String($0) }
                post(Notices.agent, info)
            }
            return true
        }
        if args.contains("--command-done") {
            var info: [String: String] = [:]
            for key in ["status", "seconds", "tty", "shell", "command"] { info[key] = value("--" + key) }
            info["app"] = guiAncestor().map { String($0) }
            post(command, info)
            return true
        }
        return false
    }

    /// События разных агентов — к одному виду: kind = start (начал отвечать), stop (ответил), ask (просит разрешение),
    /// wait (ждёт ответа). Остальное (фоновые задачи Kimi и т. п.) — nil.
    static func normalize(agent: String, event: String, json: [String: Any]) -> [String: String]? {
        let message = ((json["message"] ?? json["body"] ?? json["title"]) as? String) ?? ""
        let lower = (message + " " + ((json["notification_type"] as? String) ?? "")).lowercased()
        let kind: String
        switch event {
        case "UserPromptSubmit", "beforeSubmitPrompt", "TurnStarted":
            kind = "start"
        case "Stop", "stop", "agent-turn-complete":
            kind = "stop"
        case "PermissionRequest":
            kind = "ask"
        case "Notification":
            if lower.contains("permission") || lower.contains("approv") || lower.contains("разреш") {
                kind = "ask"
            } else if lower.contains("waiting for your input") {
                kind = "wait"
            } else {
                return nil
            }
        default:
            return nil
        }
        var info = ["agent": agent, "kind": kind]
        let session = json["session_id"] ?? json["conversation_id"] ?? json["thread-id"] ?? json["turn-id"]
        info["session"] = (session as? String) ?? "default"
        let roots = json["workspace_roots"] as? [String]
        info["cwd"] = (json["cwd"] as? String) ?? roots?.first
        info["title"] = json["session_title"] as? String
        info["transcript"] = json["transcript_path"] as? String
        info["status"] = json["status"] as? String  // Cursor: completed, aborted, error
        info["message"] = message.isEmpty ? nil : message
        return info
    }

    private static func post(_ name: Notification.Name, _ info: [String: String]) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: info, deliverImmediately: true)
    }

    /// Приложение с окнами, из которого запущена команда (Терминал, iTerm, Claude…): его покажет кнопка «Открыть».
    private static func guiAncestor() -> pid_t? {
        var pid = getppid()
        for _ in 0..<12 where pid > 1 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return pid }
            guard let parent = Proc.parent(of: pid) else { return nil }
            pid = parent
        }
        return nil
    }
}

/// Процессы пользователя через sysctl: без разрешений macOS, только свои процессы.
enum Proc {
    struct Info {
        let pid: pid_t
        let parent: pid_t
        let group: pid_t
        let terminalGroup: pid_t
        let terminal: dev_t
        let name: String
        let start: Date
    }

    static func all() -> [Info] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var list = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = list.count * stride
        guard sysctl(&mib, 4, &list, &size, nil, 0) == 0 else { return [] }
        return list.prefix(size / stride).map(info)
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var p = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &p, &size, nil, 0) == 0, size > 0 else { return nil }
        return p.kp_eproc.e_ppid
    }

    /// Аргументы командной строки процесса (KERN_PROCARGS2: argc, путь, нули, argv).
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size && buffer[i] != 0 { i += 1 }  // путь к исполняемому файлу
        while i < size && buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    private static func info(_ p: kinfo_proc) -> Info {
        let name = withUnsafeBytes(of: p.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let t = p.kp_proc.p_starttime
        return Info(pid: p.kp_proc.p_pid, parent: p.kp_eproc.e_ppid, group: p.kp_eproc.e_pgid,
                    terminalGroup: p.kp_eproc.e_tpgid, terminal: p.kp_eproc.e_tdev, name: name,
                    start: Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1e6))
    }
}

/// Долгие команды в терминале: задание переднего плана, запущенное из оболочки, закончилось.
/// Настраивать оболочку не нужно: процессы видны через sysctl. Код возврата так не узнать.
@MainActor
final class CommandWatcher {
    struct Finished {
        let command: String
        let duration: TimeInterval
        let app: pid_t?
        let shell: pid_t
        /// Терминал задания, «/dev/ttys003»: по нему кнопка находит вкладку.
        let tty: String?
    }

    var onFinished: ((Finished) -> Void)?
    /// Короче — не сообщаем.
    var minimum: TimeInterval = 30

    private struct Job {
        let start: Date
        let shell: pid_t
        let command: String
        let app: pid_t?
        let tty: String?
        /// Сервер (слушает порт), приложение с окнами или «dev/serve/watch» — висит, пока его не закроют.
        var longLived = false
        var checkedAt = Date.distantPast
    }

    /// Команда, которая идёт сейчас на переднем плане терминала: для «работает» и пункта «Прервать».
    struct Running {
        let pid: pid_t
        let command: String
        let start: Date
        let longLived: Bool
    }

    private var jobs: [pid_t: Job] = [:]
    /// Задания на переднем плане при последнем опросе (остановленные ⌃Z — не здесь).
    private var foreground: Set<pid_t> = []
    /// Прервали из меню Бита — о завершении не сообщаем.
    private var interrupted: Set<pid_t> = []

    var running: [Running] {
        jobs.filter { foreground.contains($0.key) }
            .map { Running(pid: $0.key, command: $0.value.command, start: $0.value.start, longLived: $0.value.longLived) }
            .sorted { $0.start < $1.start }
    }

    /// В терминале идёт команда (дольше 5 секунд — короткие не в счёт, чтобы Бит не дёргался).
    /// ignoringLongLived — серверы и приложения не считаются.
    func isBusy(ignoringLongLived: Bool) -> Bool {
        let now = Date()
        return running.contains { now.timeIntervalSince($0.start) >= 5 && !(ignoringLongLived && $0.longLived) }
    }

    /// Как ⌃C в терминале: SIGINT всей группе процессов задания.
    func interrupt(_ pid: pid_t) {
        guard jobs[pid] != nil else { return }
        interrupted.insert(pid)
        kill(-pid, SIGINT)
    }
    private var ignored: Set<pid_t> = []
    private var timer: Timer?

    private static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "tcsh", "ksh", "nu"]
    /// Интерактивные программы: их закрывают руками, сообщать незачем.
    private static let interactive: Set<String> = [
        "claude", "codex", "gemini", "aider", "vim", "nvim", "vi", "nano", "emacs", "micro", "hx", "helix", "less", "more",
        "man", "top", "htop", "btop", "ssh", "mosh", "tmux", "screen", "zellij", "watch", "tail", "lazygit", "tig", "fzf",
        "mc", "ranger", "yazi", "psql", "mysql", "sqlite3", "redis-cli", "mongosh", "irb", "ghci", "lua", "node", "python",
        "python3", "ipython", "bpython", "ollama", "k9s", "ncdu", "nnn", "lf", "telnet", "nc", "ftp", "sftp", "login", "su", "sudo"
    ]
    private static let interpreters: Set<String> = ["node", "python", "python3", "ruby", "perl", "bun", "deno", "php", "java"]

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        jobs = [:]
        foreground = []
        ignored = []
    }

    private func poll() {
        let list = Proc.all()
        let byPid = Dictionary(list.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var seen: Set<pid_t> = []
        for p in list where p.terminal != -1 && p.pid == p.group && p.terminalGroup == p.group {
            guard let shell = byPid[p.parent], Self.shells.contains(shell.name) else { continue }
            seen.insert(p.pid)
            if jobs[p.pid] != nil || ignored.contains(p.pid) { continue }
            let args = Proc.arguments(of: p.pid)
            guard let command = Self.describe(name: p.name, args: args) else {
                ignored.insert(p.pid)
                continue
            }
            let tty = devname(p.terminal, S_IFCHR).map { "/dev/" + String(cString: $0) }
            jobs[p.pid] = Job(start: p.start, shell: shell.pid, command: command, app: Self.app(above: shell.pid, in: byPid), tty: tty)
        }
        ignored.formIntersection(Set(byPid.keys))
        foreground = seen
        classify(list)
        for (pid, job) in jobs where !seen.contains(pid) {
            // Ушло с переднего плана: закончилось, или его остановили (⌃Z) — тогда процесс ещё жив.
            if let p = byPid[pid], p.start == job.start { continue }
            jobs[pid] = nil
            // Закрыли вкладку вместе с оболочкой — это не завершение команды; прервали из меню — уже сказали.
            guard byPid[job.shell] != nil, interrupted.remove(pid) == nil else { continue }
            let duration = Date().timeIntervalSince(job.start)
            if duration >= minimum {
                onFinished?(Finished(command: job.command, duration: duration, app: job.app, shell: job.shell, tty: job.tty))
            }
        }
    }

    /// Сервер или приложение? Проверяем задание через 10 секунд после старта и потом раз в 10 секунд, пока не станет ясно:
    /// по словам команды (dev, serve, watch…), по открытому на прослушку порту и по окнам у процессов задания.
    private func classify(_ list: [Proc.Info]) {
        let now = Date()
        let children = Dictionary(grouping: list, by: \.parent)
        for (pid, job) in jobs where !job.longLived && now.timeIntervalSince(job.start) >= 10 && now.timeIntervalSince(job.checkedAt) >= 10 {
            jobs[pid]?.checkedAt = now
            var tree: [pid_t] = [pid]
            var i = 0
            while i < tree.count && tree.count < 200 {
                tree += (children[tree[i]] ?? []).map(\.pid)
                i += 1
            }
            let words = job.command.lowercased().split(separator: " ").map(String.init)
            if words.contains(where: Self.longLivedWords.contains)
                || tree.contains(where: { Self.listens($0) || NSRunningApplication(processIdentifier: $0) != nil }) {
                jobs[pid]?.longLived = true
            }
        }
    }

    private static let longLivedWords: Set<String> = [
        "dev", "serve", "server", "runserver", "start", "watch", "--watch", "preview", "storybook", "nodemon", "vite",
        "uvicorn", "gunicorn", "http.server", "up", "tunnel", "ngrok"
    ]

    /// Есть ли у процесса TCP-сокет на прослушке (libproc, без запуска lsof).
    private static func listens(_ pid: pid_t) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        for fd in fds.prefix(Int(max(got, 0)) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let length = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, length) == length else { continue }
            if info.psi.soi_kind == SOCKINFO_TCP && info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN { return true }
        }
        return false
    }

    /// Строка команды из хука оболочки — как набрали (длину ограничим) или nil, если программа интерактивная.
    static func describe(_ line: String) -> String? {
        var words = line.split(separator: " ").map(String.init)
        // Переменные окружения, sudo, time перед командой пропускаем: «FOO=1 sudo make» — это make.
        while let first = words.first, first.contains("=") || ["sudo", "time", "env", "nohup", "caffeinate"].contains(first) {
            words.removeFirst()
        }
        guard !words.isEmpty, !isInteractive(words) else { return nil }
        let text = words.joined(separator: " ")
        return text.count > 40 ? String(text.prefix(39)) + "…" : text
    }

    /// Короткое имя команды по аргументам процесса: «swift build», «npm run build». nil — интерактивная, не следим.
    private static func describe(name: String, args: [String]) -> String? {
        var words = args.isEmpty ? [name] : args
        words[0] = (words[0] as NSString).lastPathComponent
        // `sh -c "make all"` → «make all».
        if shells.contains(words[0]), let c = words.firstIndex(of: "-c"), words.indices.contains(c + 1) {
            return describe(words[c + 1])
        }
        // `node /…/npm run build` → «npm run build», `bash build.sh` → «build.sh».
        if interpreters.contains(words[0]) || shells.contains(words[0]),
           let index = words.indices.dropFirst().first(where: { !words[$0].hasPrefix("-") }) {
            words = [(words[index] as NSString).lastPathComponent] + words[(index + 1)...]
        }
        guard !isInteractive(words) else { return nil }
        let text = words.prefix(4).joined(separator: " ")
        return text.count > 40 ? String(text.prefix(39)) + "…" : text
    }

    /// Редакторы, ssh, REPL без скрипта, оболочка без команды, сам Claude — их закрывают руками.
    private static func isInteractive(_ words: [String]) -> Bool {
        guard let first = words.first.map({ ($0 as NSString).lastPathComponent }) else { return true }
        let hasTarget = words.dropFirst().contains { !$0.hasPrefix("-") }
        if (shells.contains(first) || interpreters.contains(first)) && !hasTarget { return true }
        if interactive.contains(first) && !interpreters.contains(first) { return true }
        return words.contains { $0 == "claude" || $0.hasSuffix("/claude") }
    }

    private static func app(above shell: pid_t, in byPid: [pid_t: Proc.Info]) -> pid_t? {
        var pid = shell
        for _ in 0..<10 {
            guard let p = byPid[pid], p.parent > 1 else { return nil }
            pid = p.parent
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return pid }
        }
        return nil
    }
}

/// Встречи из Календаря: за 5 минут и в момент начала. Нужен доступ к календарям — macOS спросит сама.
@MainActor
final class MeetingWatcher {
    struct Reminder {
        let title: String
        let start: Date
        let end: Date
        /// Через сколько минут; 0 — начинается.
        let minutes: Int
        let link: URL?
    }

    var onReminder: ((Reminder) -> Void)?

    private let store = EKEventStore()
    private var granted = false
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var announced: Set<String> = []

    /// Первое включение показывает системный запрос доступа; ответ даёт пользователь.
    func start() {
        guard timer == nil else { return }
        store.requestFullAccessToEvents { [weak self] ok, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.granted = ok
                    if ok { self.check() }
                }
            }
        }
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func check() {
        guard granted || EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 60), end: now.addingTimeInterval(6 * 60), calendars: nil)
        for event in store.events(matching: predicate) {
            guard !event.isAllDay, event.status != .canceled, !Self.declined(event) else { continue }
            let lead = event.startDate.timeIntervalSince(now)
            let key = "\(event.eventIdentifier ?? event.title ?? "")|\(event.startDate.timeIntervalSince1970)"
            if lead <= 20 && lead > -120 {
                guard !announced.contains(key + "|now") else { continue }
                announced.insert(key + "|now")
                announced.insert(key + "|soon")  // добавили в последний момент — «скоро» уже не нужно
                onReminder?(reminder(event, minutes: 0))
            } else if lead <= 5 * 60 + 10 && lead > 20 {
                guard !announced.contains(key + "|soon") else { continue }
                announced.insert(key + "|soon")
                onReminder?(reminder(event, minutes: max(1, Int((lead / 60).rounded()))))
            }
        }
        if announced.count > 200 { announced.removeAll() }
    }

    private func reminder(_ event: EKEvent, minutes: Int) -> Reminder {
        let title = (event.title ?? "").isEmpty ? L("Встреча") : event.title!
        return Reminder(title: title, start: event.startDate, end: event.endDate, minutes: minutes, link: Self.joinLink(event))
    }

    private static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    /// Ссылка для подключения: сначала известные сервисы видеосвязи в адресе, месте и заметках,
    /// иначе адрес события или первая ссылка в поле «Место».
    static func joinLink(_ event: EKEvent) -> URL? {
        let known = ["zoom.us", "zoom.ru", "meet.google.com", "teams.microsoft.com", "teams.live.com", "telemost.yandex",
                     "webex.com", "meet.jit.si", "whereby.com", "ktalk.ru", "jazz.sber", "salutejazz", "mts-link",
                     "trueconf", "facetime.apple.com", "skype.com", "bluejeans.com", "gotomeeting.com", "chime.aws",
                     "vk.com/call", "calls.vk", "dion.vc", "videomost"]
        let place = links(in: [event.url?.absoluteString, event.location].compactMap { $0 })
        let all = place + links(in: [event.notes].compactMap { $0 })
        if let video = all.first(where: { url in known.contains { url.absoluteString.lowercased().contains($0) } }) {
            return video
        }
        return place.first
    }

    private static func links(in texts: [String]) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return texts.flatMap { text in
            detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
        }.filter { ["http", "https", "zoommtg", "msteams"].contains($0.scheme?.lowercased() ?? "") }
    }
}

/// Ollama отвечает: хуков у неё нет, зато модель считает отдельный процесс (`llama-server` или `ollama runner`),
/// и во время ответа он грузит процессор на сотни процентов, а в покое — почти ноль.
@MainActor
final class OllamaWatcher {
    /// true — начала отвечать, false — закончила. app и tty — откуда спросили: терминал с `ollama run` или само приложение.
    var onChange: ((_ busy: Bool, _ app: pid_t?, _ tty: String?) -> Void)?

    private var timer: Timer?
    private var lastTicks: [pid_t: UInt64] = [:]
    private var lastSample = Date()
    private var hot = 0
    private var cold = 0
    private(set) var busy = false
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastTicks = [:]
        if busy {
            busy = false
            onChange?(false, nil, nil)
        }
    }

    private func poll() {
        let list = Proc.all()
        let runners = list.filter { $0.name == "llama-server" || ($0.name == "ollama" && Proc.arguments(of: $0.pid).contains("runner")) }
        let now = Date()
        let seconds = now.timeIntervalSince(lastSample)
        lastSample = now
        var cpu = 0.0
        var ticks: [pid_t: UInt64] = [:]
        for runner in runners {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(runner.pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            let total = info.pti_total_user + info.pti_total_system
            ticks[runner.pid] = total
            if let before = lastTicks[runner.pid], total >= before, seconds > 0 {
                cpu += Double(total - before) * Self.timebase / 1e9 / seconds
            }
        }
        lastTicks = ticks
        // Больше 40 % два опроса подряд — отвечает; меньше 15 % три опроса — закончила.
        if cpu > 0.4 { hot += 1; cold = 0 } else if cpu < 0.15 { cold += 1; hot = 0 }
        if !busy && hot >= 2 {
            busy = true
            onChange?(true, nil, nil)
        } else if busy && cold >= 3 {
            busy = false
            let (app, tty) = Self.source(list)
            onChange?(false, app, tty)
        }
    }

    /// Кто спросил: `ollama run` в терминале (его вкладка) — иначе приложение Ollama.
    private static func source(_ list: [Proc.Info]) -> (pid_t?, String?) {
        let byPid = Dictionary(list.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        if let client = list.first(where: { $0.name == "ollama" && $0.terminal != -1 && Proc.arguments(of: $0.pid).contains("run") }) {
            var pid = client.parent
            for _ in 0..<10 {
                if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                    return (pid, devname(client.terminal, S_IFCHR).map { "/dev/" + String(cString: $0) })
                }
                guard let p = byPid[pid], p.parent > 1 else { break }
                pid = p.parent
            }
        }
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.electron.ollama").first
        return (app?.processIdentifier, nil)
    }
}

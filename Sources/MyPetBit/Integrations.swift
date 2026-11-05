import Foundation

/// Куда Бит умеет прописать свои хуки: ИИ-агенты и zsh.
enum Integration: String, CaseIterable {
    case claude, cursor, opencode, codex, kimiCLI, kimiCode, zsh

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .opencode: return "OpenCode"
        case .codex: return "Codex"
        case .kimiCLI: return "Kimi CLI"
        case .kimiCode: return "Kimi Code"
        case .zsh: return L("Терминал (zsh)")
        }
    }

    /// Файл настроек относительно домашней папки.
    var file: String {
        switch self {
        case .claude: return ".claude/settings.json"
        case .cursor: return ".cursor/hooks.json"
        case .opencode: return ".config/opencode/plugins/mypetbit.js"
        case .codex: return ".codex/config.toml"
        case .kimiCLI: return ".kimi/config.toml"
        case .kimiCode: return ".kimi-code/config.toml"
        case .zsh: return ".zshrc"
        }
    }

    /// Папка, по которой видно, что программа есть (zsh — всегда).
    fileprivate var home: String? {
        switch self {
        case .claude: return ".claude"
        case .cursor: return ".cursor"
        case .opencode: return ".config/opencode"
        case .codex: return ".codex"
        case .kimiCLI: return ".kimi"
        case .kimiCode: return ".kimi-code"
        case .zsh: return nil
        }
    }

    /// По этим строкам свой хук узнаётся при любом пути к Биту (в том числе от DeskPet, до переименования).
    fileprivate var markers: [String] {
        switch self {
        case .claude: return ["--claude-hook", "--agent-hook claude"]
        case .cursor: return ["--agent-hook cursor"]
        case .opencode: return ["const BIT ="]
        case .codex: return ["\"--agent-hook\", \"codex\""]
        case .kimiCLI, .kimiCode: return ["--agent-hook kimi"]
        case .zsh: return ["mypetbit.zsh", "deskpet.zsh"]
        }
    }
}

/// Подключение Бита к агентам и терминалу: по кнопке в настройках и знакомстве, не молча.
/// Трогает только свои записи; перед первой правкой файла кладёт рядом копию `*.bak-mypetbit`.
/// Чистая логика над файлами — дом и пути передаются снаружи, поэтому проверяется тестами на временной папке.
struct Integrations {
    enum State: Equatable {
        /// Программы на этом Mac нет.
        case missing
        case off
        case on
        /// Подключено, но к другой копии Бита (она есть).
        case other
        /// Подключено, но путь ведёт в никуда — приложение переехало или переименовано.
        case broken
        /// Место занято чужим (у Codex один `notify`).
        case blocked
    }

    let home: URL
    /// Исполняемый файл Бита, который сейчас запущен.
    let bin: String
    /// Шаблоны (`integrations/` в ресурсах приложения) — для плагина OpenCode.
    let templates: URL
    /// Хук zsh (`mypetbit.zsh` в ресурсах приложения).
    let zshScript: String

    private func url(_ integration: Integration) -> URL { home.appendingPathComponent(integration.file) }
    private func read(_ integration: Integration) -> String? { try? String(contentsOf: url(integration), encoding: .utf8) }

    func isInstalled(_ integration: Integration) -> Bool {
        guard let dir = integration.home else { return true }
        return FileManager.default.fileExists(atPath: home.appendingPathComponent(dir).path)
    }

    func state(_ integration: Integration) -> State {
        let text = read(integration) ?? ""
        let ours = linesWithMarker(integration, in: text)
        if ours.isEmpty {
            if !isInstalled(integration) { return .missing }
            if integration == .codex, notifyLine(in: text) != nil { return .blocked }
            return .off
        }
        let paths = ours.compactMap { Self.path(in: $0) }
        if integration == .zsh {
            // Строка source с путём к самому хуку: жив файл — работает (он сам найдёт Бита).
            if paths.allSatisfy({ !FileManager.default.fileExists(atPath: $0) }) { return .broken }
            return paths.contains(zshScript) ? .on : .other
        }
        if paths.allSatisfy({ !FileManager.default.isExecutableFile(atPath: $0) }) { return .broken }
        return paths.contains(bin) ? .on : .other
    }

    /// Подключить (или переподключить к этой копии Бита).
    func connect(_ integration: Integration) throws {
        let file = url(integration)
        try backup(file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = read(integration) ?? ""
        switch integration {
        case .claude:
            var root = try json(text)
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for event in ["UserPromptSubmit", "Stop", "Notification"] {
                var groups = withoutOurs(hooks[event] as? [[String: Any]] ?? [], integration)
                groups.append(["hooks": [["type": "command", "command": "\(Self.quoted(bin)) --claude-hook", "timeout": 5]]])
                hooks[event] = groups
            }
            root["hooks"] = hooks
            try write(root, to: file)
        case .cursor:
            var root = try json(text)
            if root["version"] == nil { root["version"] = 1 }
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for event in ["beforeSubmitPrompt", "stop"] {
                var entries = withoutOurs(hooks[event] as? [[String: Any]] ?? [], integration)
                entries.append(["command": "\(Self.quoted(bin)) --agent-hook cursor", "timeout": 5])
                hooks[event] = entries
            }
            root["hooks"] = hooks
            try write(root, to: file)
        case .opencode:
            let template = try String(contentsOf: templates.appendingPathComponent("opencode/mypetbit.js"), encoding: .utf8)
            let plugin = template.replacingOccurrences(of: "/Applications/MyPetBit.app/Contents/MacOS/MyPetBit", with: bin)
            try plugin.write(to: file, atomically: true, encoding: .utf8)
            // Плагин от DeskPet, до переименования, — убрать, иначе события придут дважды.
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent().appendingPathComponent("deskpet.js"))
        case .codex:
            if notifyLine(in: text) != nil && linesWithMarker(integration, in: text).isEmpty {
                throw IntegrationError.occupied
            }
            // notify — ключ верхнего уровня: только до первой таблицы, иначе он попадёт внутрь неё.
            var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
            lines.removeAll { Self.isNotify($0) && $0.contains("--agent-hook") }
            let line = "notify = [\(Self.tomlString(bin)), \"--agent-hook\", \"codex\"]  # MyPetBit"
            let firstTable = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
            lines.insert(line, at: firstTable)
            try (lines.joined(separator: "\n") + (lines.last == "" ? "" : "\n")).write(to: file, atomically: true, encoding: .utf8)
        case .kimiCLI, .kimiCode:
            let start = integration == .kimiCode ? "TurnStarted" : "UserPromptSubmit"
            let events = [start, "Stop"] + (integration == .kimiCode ? ["PermissionRequest"] : [])
            // Запускает ли Kimi команду через оболочку, не знаем: кавычки — только если в пути пробелы.
            let program = bin.contains(" ") ? Self.quoted(bin) : bin
            let command = Self.tomlString("\(program) --agent-hook kimi")
            let block = events.map { "[[hooks]]\nevent = \"\($0)\"\ncommand = \(command)\n" }.joined(separator: "\n")
            var rest = Self.removingTomlHooks(from: text, markers: integration.markers)
            if !rest.isEmpty && !rest.hasSuffix("\n\n") { rest += rest.hasSuffix("\n") ? "\n" : "\n\n" }
            try (rest + "# MyPetBit begin\n" + block + "# MyPetBit end\n").write(to: file, atomically: true, encoding: .utf8)
        case .zsh:
            var rest = Self.removingShellLines(from: text, markers: integration.markers)
            if !rest.isEmpty && !rest.hasSuffix("\n") { rest += "\n" }
            let source = "[[ -r \(Self.shellString(zshScript)) ]] && source \(Self.shellString(zshScript))"
            try (rest + "# MyPetBit begin — долгие команды с кодом выхода (подключено в настройках Бита)\n" + source + "\n# MyPetBit end\n")
                .write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Отключить: убрать только свои записи, всё чужое остаётся как было.
    func disconnect(_ integration: Integration) throws {
        let file = url(integration)
        guard let text = read(integration) else { return }
        try backup(file)
        switch integration {
        case .claude, .cursor:
            var root = try json(text)
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for (event, value) in hooks {
                let left = withoutOurs(value as? [[String: Any]] ?? [], integration)
                hooks[event] = left.isEmpty ? nil : left
            }
            root["hooks"] = hooks
            try write(root, to: file)
        case .opencode:
            try FileManager.default.removeItem(at: file)
        case .codex:
            let lines = text.components(separatedBy: "\n").filter { !(Self.isNotify($0) && $0.contains("--agent-hook")) }
            try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        case .kimiCLI, .kimiCode:
            try Self.removingTomlHooks(from: text, markers: integration.markers).write(to: file, atomically: true, encoding: .utf8)
        case .zsh:
            try Self.removingShellLines(from: text, markers: integration.markers).write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Хуки, которые ведут в никуда (Бита переложили или переименовали), — переподключить к этой копии.
    func repairBroken() -> [Integration] {
        Integration.allCases.filter { integration in
            guard state(integration) == .broken else { return false }
            return (try? connect(integration)) != nil
        }
    }

    // MARK: - Разбор

    private func linesWithMarker(_ integration: Integration, in text: String) -> [String] {
        text.components(separatedBy: "\n").filter { line in integration.markers.contains { line.contains($0) } }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    }

    private func notifyLine(in text: String) -> String? {
        text.components(separatedBy: "\n").first(where: Self.isNotify)
    }

    private static func isNotify(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("notify") && trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces).hasPrefix("=")
    }

    /// Путь к программе из строки настроек: в кавычках (одинарных или двойных) или первым словом команды.
    static func path(in line: String) -> String? {
        for quote: Character in ["'", "\""] {
            var rest = Substring(line)
            while let open = rest.firstIndex(of: quote) {
                let after = rest[rest.index(after: open)...]
                guard let close = after.firstIndex(of: quote) else { break }
                let candidate = String(after[..<close])
                if candidate.hasPrefix("/") { return candidate }
                rest = after[after.index(after: close)...]
            }
        }
        return line.split(separator: " ").first { $0.hasPrefix("/") }.map(String.init)
    }

    private func withoutOurs(_ list: [[String: Any]], _ integration: Integration) -> [[String: Any]] {
        list.filter { entry in
            let commands = ((entry["hooks"] as? [[String: Any]]) ?? [entry]).compactMap { $0["command"] as? String }
            return !commands.contains { command in integration.markers.contains { command.contains($0) } }
        }
    }

    /// Убрать таблицы [[hooks]], в которых наша команда, и свои метки.
    static func removingTomlHooks(from text: String, markers: [String]) -> String {
        var chunks: [[String]] = [[]]
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") { chunks.append([]) }
            chunks[chunks.count - 1].append(line)
        }
        let kept = chunks.filter { chunk in
            !(chunk.first?.trimmingCharacters(in: .whitespaces) == "[[hooks]]" && chunk.contains { line in markers.contains { line.contains($0) } })
        }
        var result = kept.flatMap { $0 }.filter { !$0.hasPrefix("# MyPetBit begin") && !$0.hasPrefix("# MyPetBit end") }
            .joined(separator: "\n")
        while result.contains("\n\n\n") { result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return result
    }

    /// Убрать строки, подключающие хук Бита, свой блок и комментарии к нему.
    static func removingShellLines(from text: String, markers: [String]) -> String {
        text.components(separatedBy: "\n").filter { line in
            !markers.contains { line.contains($0) } && !line.hasPrefix("# MyPetBit") && !line.hasPrefix("# Бит (MyPetBit)")
                && !line.hasPrefix("# Бит (DeskPet)")
        }.joined(separator: "\n")
    }

    // MARK: - Запись

    private func json(_ text: String) throws -> [String: Any] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw IntegrationError.unreadable
        }
        return object
    }

    private func write(_ object: [String: Any], to file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
    }

    /// Копия до первой правки; уже есть — не трогаем, в ней самое старое состояние.
    private func backup(_ file: URL) throws {
        let copy = URL(fileURLWithPath: file.path + ".bak-mypetbit")
        guard FileManager.default.fileExists(atPath: file.path), !FileManager.default.fileExists(atPath: copy.path) else { return }
        try FileManager.default.copyItem(at: file, to: copy)
    }

    static func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func shellString(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "`", with: "\\`") + "\""
    }

    static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

enum IntegrationError: LocalizedError {
    case unreadable, occupied

    var errorDescription: String? {
        switch self {
        case .unreadable: return L("Файл настроек не читается как JSON — поправьте его вручную")
        case .occupied: return L("notify уже занят другой программой — Бит его не перезаписывает")
        }
    }
}

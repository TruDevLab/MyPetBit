import AppKit

/// Значки рабочего стола: прочитать, где стоят, и расставить. Через Finder (AppleScript в отдельном процессе),
/// поэтому в первый раз macOS спросит разрешение управлять Finder.
///
/// Координаты — как у Finder (`desktop position`): от левого верхнего угла главного экрана, ось y вниз.
enum DesktopTidy {
    struct Icon: Equatable {
        let name: String
        let position: CGPoint
        let isFolder: Bool
    }

    enum Failure: Error {
        /// Нет разрешения управлять Finder (ошибка -1743).
        case notAllowed
        /// Включены стопки: значки собраны в группы, ставить их по местам Finder не даёт.
        case stacks
        case other(String)
    }

    /// Стопки на рабочем столе: в настройках вида Finder группировка не «Нет».
    static var stacksOn: Bool {
        let settings = CFPreferencesCopyAppValue("DesktopViewSettings" as CFString, "com.apple.finder" as CFString) as? [String: Any]
        let group = settings?["GroupBy"] as? String
        return group != nil && group != "None"
    }

    // MARK: - Finder

    /// Список берётся снимком (`get`), а не «item N of desktop» по номеру: номер у Finder мог указывать в пустоту
    /// (-1728 «Не удается получить item 5 of desktop»). Значок, у которого места не получить, пропускается.
    private static let readScript = """
    tell application "Finder"
        set out to ""
        repeat with i in (get every item of desktop)
            try
                set p to desktop position of i
                set k to "file"
                if class of i is folder then set k to "folder"
                set out to out & (name of i) & tab & (item 1 of p) & tab & (item 2 of p) & tab & k & linefeed
            end try
        end repeat
        return out
    end tell
    """

    /// Аргументы: имя, x, y, имя, x, y… Возвращает, сколько значков удалось поставить.
    /// Пауза после каждого значка: без неё Finder обрывал анимацию переезда, и значок оставался нарисованным
    /// на полпути, внахлёст с соседями, хотя место у него уже новое.
    private static let applyScript = """
    on run argv
        tell application "Finder"
            try
                set arrangement of icon view options of window of desktop to not arranged
            end try
            set n to 0
            repeat with k from 1 to (count argv) by 3
                try
                    set desktop position of item (item k of argv) of desktop to {(item (k + 1) of argv) as integer, (item (k + 2) of argv) as integer}
                    set n to n + 1
                    delay 0.35
                end try
            end repeat
            return n
        end tell
    end run
    """

    /// Где стоят значки. Ответ — на главном потоке.
    @MainActor static func read(_ done: @escaping @MainActor (Result<[Icon], Failure>) -> Void) {
        run(readScript, []) { result in
            done(result.map(parse))
        }
    }

    /// Для разбора (-demoEvent desktopDiagnose): что Finder отвечает о каждом значке. Только читает.
    @MainActor static func diagnose(_ done: @escaping @MainActor (String) -> Void) {
        let script = """
        tell application "Finder"
            set out to ""
            try
                set o to icon view options of window of desktop
                set out to out & "view" & tab & (icon size of o) & tab & (arrangement of o as text) & linefeed
            on error e
                set out to out & "view error" & tab & e & linefeed
            end try
            set allItems to (get every item of desktop)
            set out to out & "count" & tab & (count allItems) & linefeed
            repeat with i in allItems
                set ln to ""
                try
                    set ln to ln & (name of i)
                end try
                try
                    set ln to ln & tab & ((class of i) as text)
                end try
                try
                    set p to desktop position of i
                    set ln to ln & tab & "dp=" & (item 1 of p) & "," & (item 2 of p)
                on error e
                    set ln to ln & tab & "dp error " & e
                end try
                try
                    set p to position of i
                    set ln to ln & tab & "pos=" & (item 1 of p) & "," & (item 2 of p)
                end try
                try
                    set b to bounds of i
                    set ln to ln & tab & "bounds=" & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b)
                end try
                set out to out & ln & linefeed
            end repeat
            return out
        end tell
        """
        run(script, []) { result in
            switch result {
            case .success(let text): done(text + "widgets\t\(widgetFrames())\ngrid\t\(finderGrid)\n")
            case .failure(let failure): done("failure: \(failure)")
            }
        }
    }

    /// Поставить значки на места. Ответ — сколько поставлено.
    @MainActor static func apply(_ places: [String: CGPoint], _ done: @escaping @MainActor (Result<Int, Failure>) -> Void) {
        let args = places.sorted { $0.key < $1.key }.flatMap { [$0.key, "\(Int($0.value.x.rounded()))", "\(Int($0.value.y.rounded()))"] }
        run(applyScript, args) { result in
            done(result.map { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 })
        }
    }

    static func parse(_ output: String) -> [Icon] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 4, let x = Double(parts[1]), let y = Double(parts[2]) else { return nil }
            return Icon(name: String(parts[0]), position: CGPoint(x: x, y: y), isFolder: parts[3] == "folder")
        }
    }

    @MainActor private static func run(_ script: String, _ args: [String], _ done: @escaping @MainActor (Result<String, Failure>) -> Void) {
        if stacksOn {
            done(.failure(.stacks))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script] + args
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            var result: Result<String, Failure>
            do {
                try process.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    result = .success(String(decoding: data, as: UTF8.self))
                } else if error.contains("-1743") || error.contains("-1744") {
                    result = .failure(.notAllowed)
                } else {
                    result = .failure(.other(error.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            } catch {
                result = .failure(.other(error.localizedDescription))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(result) }
            }
        }
    }

    // MARK: - Раскладка

    /// Сетка Finder на столе: размер значка и шаг между центрами (значок + «шаг сетки» из настроек вида, по умолчанию 64 + 54).
    static var finderGrid: (icon: CGFloat, cell: CGSize) {
        let desktop = CFPreferencesCopyAppValue("DesktopViewSettings" as CFString, "com.apple.finder" as CFString) as? [String: Any]
        let view = desktop?["IconViewSettings"] as? [String: Any]
        let icon = CGFloat((view?["iconSize"] as? NSNumber)?.doubleValue ?? 64)
        let grid = CGFloat((view?["gridSpacing"] as? NSNumber)?.doubleValue ?? 54)
        return (icon, CGSize(width: icon + grid, height: icon + grid))
    }

    /// Виджеты на рабочем столе — окна Центра уведомлений ниже обычных окон. Из-под них macOS выталкивает значки,
    /// и поставленные туда налезали на соседей. Рамки — в тех же координатах, что у Finder.
    @MainActor static func widgetFrames() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { window in
            guard let layer = window[kCGWindowLayer as String] as? Int, layer < 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.notificationcenterui",
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width < 1000 else { return nil }
            return rect
        }
    }

    /// Куда поставить значки. Запомненные — на свои места; остальные — по сетке от правого верхнего угла,
    /// как Finder: столбцами сверху вниз, справа налево, папки первыми, файлы по типу, потом по имени.
    /// Клетки, где уже стоит запомненный значок или виджет (avoid), пропускаются. Место — центр значка, подпись под ним.
    static func layout(_ icons: [Icon], remembered: [String: CGPoint], screen: CGSize,
                       cell: CGSize = CGSize(width: 118, height: 118), icon: CGFloat = 64, top: CGFloat = 40,
                       avoid: [CGRect] = []) -> [String: CGPoint] {
        var places: [String: CGPoint] = [:]
        var taken: [CGPoint] = []
        for item in icons {
            if let p = remembered[item.name] {
                places[item.name] = p
                taken.append(p)
            }
        }
        // Значок с подписью: сам значок и до двух строк подписи под ним.
        func footprint(_ p: CGPoint) -> CGRect {
            CGRect(x: p.x - cell.width / 2 + 6, y: p.y - icon / 2 - 6, width: cell.width - 12, height: icon + 46)
        }
        let rest = icons.filter { remembered[$0.name] == nil }.sorted(by: order)
        let rows = max(1, Int((screen.height - top - 14 - icon - 40) / cell.height) + 1)
        var index = 0
        for item in rest {
            while true {
                let column = index / rows, row = index % rows
                index += 1
                let p = CGPoint(x: screen.width - cell.width / 2 - 10 - CGFloat(column) * cell.width,
                                y: top + icon / 2 + 14 + CGFloat(row) * cell.height)
                guard p.x >= cell.width / 2 else { return places }  // стол кончился — остальное не трогаем
                if taken.contains(where: { abs($0.x - p.x) < cell.width * 0.6 && abs($0.y - p.y) < cell.height * 0.6 }) { continue }
                if avoid.contains(where: { $0.insetBy(dx: -6, dy: -6).intersects(footprint(p)) }) { continue }
                places[item.name] = p
                break
            }
        }
        return places
    }

    private static func order(_ a: Icon, _ b: Icon) -> Bool {
        if a.isFolder != b.isFolder { return a.isFolder }
        let ea = (a.name as NSString).pathExtension.lowercased(), eb = (b.name as NSString).pathExtension.lowercased()
        if ea != eb { return ea < eb }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

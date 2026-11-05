import AppKit
import UniformTypeIdentifiers

/// Файлы в руках у Бита: перенос в другую папку, архив и распаковка. Конвертация — в `Converters`.
/// Пока Бит держит файл, файл остаётся на своём месте; переезжает он, только когда его кладут в другую папку.
enum FileShelf {
    enum Action: String, CaseIterable {
        case zip, unzip
    }

    static let archiveExtensions: Set<String> = ["zip", "tar", "tgz", "gz", "bz2", "xz", "tbz", "txz"]

    static func isArchive(_ url: URL) -> Bool { archiveExtensions.contains(url.pathExtension.lowercased()) }

    /// Свободное имя в папке: «отчёт.pdf», «отчёт 2.pdf», «отчёт 3.pdf»…
    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        for n in 2...9999 {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return folder.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
    }

    /// Перенести файл или папку в папку (на другой диск — копированием с удалением). Возвращает новое место.
    static func move(_ url: URL, into folder: URL) throws -> URL {
        if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { return url }  // уже там
        let target = uniqueURL(folder.appendingPathComponent(url.lastPathComponent))
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// Какие действия подходят ко всем файлам сразу.
    static func actions(for urls: [URL]) -> [Action] {
        guard !urls.isEmpty else { return [] }
        var result: [Action] = [.zip]
        if urls.allSatisfy(isArchive) { result.append(.unzip) }
        return result
    }

    /// Выполнить действие в фоне. Результат — новые файлы (они ложатся рядом с исходными) или текст ошибки.
    @MainActor static func run(_ action: Action, on urls: [URL], _ done: @escaping @MainActor (Result<[URL], ActionError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try perform(action, on: urls) }.mapError { ($0 as? ActionError) ?? ActionError(message: $0.localizedDescription) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(result) }
            }
        }
    }

    struct ActionError: Error {
        let message: String
    }

    static func perform(_ action: Action, on urls: [URL]) throws -> [URL] {
        let folder = urls[0].deletingLastPathComponent()
        switch action {
        case .zip:
            let name = urls.count == 1 ? urls[0].lastPathComponent : L("Архив")
            let out = uniqueURL(folder.appendingPathComponent(name + ".zip"))
            if urls.count == 1 {
                try tool("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].path, out.path])
            } else {
                // zip из общей папки: в архиве — сами файлы, без полного пути.
                let sameFolder = urls.allSatisfy { $0.deletingLastPathComponent() == folder }
                let names = sameFolder ? urls.map(\.lastPathComponent) : urls.map(\.path)
                try tool("/usr/bin/zip", ["-r", "-q", "-y", out.path] + names, in: folder)
            }
            return [out]
        case .unzip:
            return try urls.map { archive in
                // Сначала во временную скрытую папку рядом: иначе она заняла бы имя той, что лежит в архиве.
                let parent = archive.deletingLastPathComponent()
                let temp = parent.appendingPathComponent(".mypetbit-unpack-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: temp) }
                if archive.pathExtension.lowercased() == "zip" {
                    try tool("/usr/bin/ditto", ["-x", "-k", archive.path, temp.path])
                } else {
                    try tool("/usr/bin/tar", ["-xf", archive.path, "-C", temp.path])
                }
                // В архиве одна папка — достаём её, без лишней вложенности; иначе всё — в папку с именем архива.
                let inside = (try? FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? []
                let visible = inside.filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
                if visible.count == 1, (try? visible[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let lifted = uniqueURL(parent.appendingPathComponent(visible[0].lastPathComponent))
                    try FileManager.default.moveItem(at: visible[0], to: lifted)
                    return lifted
                }
                let dest = uniqueURL(parent.appendingPathComponent(baseName(archive)))
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
                for item in visible {
                    try FileManager.default.moveItem(at: item, to: dest.appendingPathComponent(item.lastPathComponent))
                }
                return dest
            }
        }
    }

    /// Имя без расширения архива: «фото.tar.gz» → «фото».
    static func baseName(_ archive: URL) -> String {
        var name = archive.lastPathComponent
        for ext in [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz", ".txz", ".zip", ".tar", ".gz", ".bz2", ".xz"]
        where name.lowercased().hasSuffix(ext) && name.count > ext.count {
            name = String(name.dropLast(ext.count))
            break
        }
        return name
    }

    private static func tool(_ path: String, _ args: [String], in folder: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if let folder { process.currentDirectoryURL = folder }
        let err = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        try process.run()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let line = message.split(separator: "\n").last.map(String.init) ?? ""
            throw ActionError(message: line.isEmpty ? "\(URL(fileURLWithPath: path).lastPathComponent): \(process.terminationStatus)" : line)
        }
    }
}

/// Отдать файлы перетаскиванием: Finder сообщает, в какую папку бросили, и Бит переносит туда файл сам.
/// Так файл именно переезжает (и на другой диск тоже), а не копируется.
final class HeldFilePromise: NSObject, NSFilePromiseProviderDelegate {
    let original: URL
    /// Куда переехал файл (на главном потоке).
    var onMoved: (@MainActor (URL, URL?) -> Void)?
    private let queue = OperationQueue()

    init(original: URL) {
        self.original = original
        queue.qualityOfService = .userInitiated
    }

    func provider() -> NSFilePromiseProvider {
        let type = (try? original.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? .data
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = original
        return provider
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        original.lastPathComponent
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { queue }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        var moved: URL?
        var failure: Error?
        do {
            moved = try FileShelf.move(original, into: url.deletingLastPathComponent())
        } catch {
            failure = error
        }
        completionHandler(failure)
        let original = original
        let onMoved = onMoved
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onMoved?(original, moved) }
        }
    }
}

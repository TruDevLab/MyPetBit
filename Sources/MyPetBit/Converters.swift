import AppKit
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Чем конвертировать: встроенное в macOS, iWork (через AppleScript) и открытые программы, если они установлены.
/// Внутрь Бита ничего не встраивается — он находит то, что уже есть на Mac.
enum ConvertEngine: String, CaseIterable {
    case builtIn, keynote, pages, numbers, libreOffice, pandoc, ffmpeg, cwebp, magick

    var title: String {
        switch self {
        case .builtIn: return L("macOS")
        case .keynote: return "Keynote"
        case .pages: return "Pages"
        case .numbers: return "Numbers"
        case .libreOffice: return "LibreOffice"
        case .pandoc: return "pandoc"
        case .ffmpeg: return "ffmpeg"
        case .cwebp: return "libwebp"
        case .magick: return "ImageMagick"
        }
    }

    /// Что добавляет — для раздела «Конвертеры» в настройках.
    var adds: String {
        switch self {
        case .builtIn: return L("Картинки, документы, Markdown, PDF, видео mov/mp4 и аудио")
        case .keynote: return L("pptx и key → PDF и PowerPoint")
        case .pages: return L("docx, doc, rtf → PDF, Word, EPUB с вёрсткой")
        case .numbers: return L("xlsx, csv → PDF и Excel")
        case .libreOffice: return L("Любые офисные форматы друг в друга и в PDF")
        case .pandoc: return L("Markdown, docx, odt, html, epub — лучшее качество")
        case .ffmpeg: return L("Любое видео и аудио: mkv, webm, mp3, flac")
        case .cwebp: return L("Картинки в WebP")
        case .magick: return L("Картинки в WebP и AVIF")
        }
    }

    /// Как поставить; nil — уже есть в macOS.
    var install: String? {
        switch self {
        case .builtIn: return nil
        case .keynote, .pages, .numbers: return L("App Store, бесплатно")
        case .libreOffice: return "brew install --cask libreoffice"
        case .pandoc: return "brew install pandoc"
        case .ffmpeg: return "brew install ffmpeg"
        case .cwebp: return "brew install webp"
        case .magick: return "brew install imagemagick"
        }
    }

    fileprivate var bundleID: String? {
        switch self {
        case .keynote: return "com.apple.iWork.Keynote"
        case .pages: return "com.apple.iWork.Pages"
        case .numbers: return "com.apple.iWork.Numbers"
        case .libreOffice: return "org.libreoffice.script"
        default: return nil
        }
    }

    fileprivate var command: String? {
        switch self {
        case .pandoc: return "pandoc"
        case .ffmpeg: return "ffmpeg"
        case .cwebp: return "cwebp"
        case .magick: return "magick"
        default: return nil
        }
    }
}

/// Где лежат конвертеры. Ищет один раз (и по «Проверить снова»): у приложения из Dock нет PATH оболочки,
/// поэтому смотрим и в папки Homebrew.
@MainActor
enum ConvertTools {
    private static var found: [ConvertEngine: String]?

    static var paths: [ConvertEngine: String] {
        if let found { return found }
        let result = scan()
        found = result
        return result
    }

    static var available: Set<ConvertEngine> { Set(paths.keys) }

    static func refresh() { found = nil }

    private static func scan() -> [ConvertEngine: String] {
        var result: [ConvertEngine: String] = [.builtIn: "/usr/bin"]
        let env = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] + env
        for engine in ConvertEngine.allCases {
            if let id = engine.bundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                result[engine] = engine == .libreOffice ? app.appendingPathComponent("Contents/MacOS/soffice").path : app.path
            } else if engine == .libreOffice,
                      FileManager.default.isExecutableFile(atPath: "/Applications/LibreOffice.app/Contents/MacOS/soffice") {
                result[engine] = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
            } else if let command = engine.command,
                      let dir = dirs.first(where: { FileManager.default.isExecutableFile(atPath: "\($0)/\(command)") }) {
                result[engine] = "\(dir)/\(command)"
            }
        }
        return result
    }
}

/// Один вариант в меню «Конвертировать в…».
struct ConvertOption: Equatable {
    enum Job: Equatable {
        case format(String)
        case shrink, imagesToPDF, pdfPages, pdfCompress, pdfMerge
        case videoHEVC, videoH264, gif, audioM4A, audioMP3
    }

    let job: Job
    let engine: ConvertEngine

    /// Для демо и тестов: «format-docx», «videoHEVC».
    var id: String {
        if case .format(let ext) = job { return "format-\(ext)" }
        return "\(job)"
    }

    var title: String {
        let base: String
        switch job {
        case .format(let ext): base = L("В %@", ext.uppercased())
        case .shrink: base = L("Уменьшить до 1920 px")
        case .imagesToPDF, .pdfMerge: base = L("Склеить в один PDF")
        case .pdfPages: base = L("Страницы в PNG")
        case .pdfCompress: base = L("Сжать PDF")
        case .videoHEVC: base = L("Сжать видео (HEVC, 1080p)")
        case .videoH264: base = L("Сжать видео (H.264, 720p)")
        case .gif: base = L("В GIF")
        case .audioM4A: base = L("Звук из видео (M4A)")
        case .audioMP3: base = L("Звук в MP3")
        }
        return engine == .builtIn ? base : "\(base) · \(engine.title)"
    }

    var symbol: String {
        switch job {
        case .format(let ext) where ext == "pdf": return "doc.richtext"
        case .format: return "arrow.triangle.2.circlepath"
        case .shrink: return "arrow.down.right.and.arrow.up.left"
        case .imagesToPDF, .pdfMerge: return "doc.on.doc"
        case .pdfPages: return "photo.on.rectangle"
        case .pdfCompress, .videoHEVC, .videoH264: return "arrow.down.circle"
        case .gif: return "photo.stack"
        case .audioM4A, .audioMP3: return "waveform"
        }
    }
}

enum Converters {
    enum Category { case image, document, markdown, presentation, spreadsheet, pdf, video, audio }

    static let images: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "avif"]
    static let documents: Set<String> = ["txt", "rtf", "rtfd", "html", "htm", "doc", "docx", "odt", "webarchive", "pages"]
    static let markdown: Set<String> = ["md", "markdown"]
    static let presentations: Set<String> = ["pptx", "ppt", "odp", "key"]
    static let spreadsheets: Set<String> = ["xlsx", "xls", "ods", "numbers", "csv"]
    static let videos: Set<String> = ["mov", "mp4", "m4v", "mkv", "webm", "avi", "flv", "wmv", "mpg", "mpeg", "3gp"]
    /// Что читает AVFoundation без внешних программ.
    static let avVideos: Set<String> = ["mov", "mp4", "m4v", "3gp"]
    static let audios: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "caf", "aac", "flac", "ogg", "opus"]
    static let avAudios: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "caf", "aac", "flac"]

    static func category(_ url: URL) -> Category? {
        let ext = url.pathExtension.lowercased()
        if images.contains(ext) { return .image }
        if documents.contains(ext) { return .document }
        if markdown.contains(ext) { return .markdown }
        if presentations.contains(ext) { return .presentation }
        if spreadsheets.contains(ext) { return .spreadsheet }
        if ext == "pdf" { return .pdf }
        if videos.contains(ext) { return .video }
        if audios.contains(ext) { return .audio }
        return nil
    }

    /// Одно имя для одного формата: jpeg → jpg, htm → html, tif → tiff, aif → aiff.
    static func normalized(_ ext: String) -> String {
        ["jpeg": "jpg", "htm": "html", "tif": "tiff", "aif": "aiff", "heif": "heic", "markdown": "md"][ext.lowercased()] ?? ext.lowercased()
    }

    /// Какие форматы умеет каждый конвертер: (что читает, во что пишет).
    static let formats: [ConvertEngine: [(Set<String>, [String])]] = [
        .libreOffice: [(["doc", "docx", "odt", "rtf", "txt", "html"], ["pdf", "docx", "odt", "rtf", "txt", "html", "doc", "epub"]),
                       (["pptx", "ppt", "odp"], ["pdf", "pptx", "odp"]),
                       (["xlsx", "xls", "ods", "csv"], ["pdf", "xlsx", "ods", "csv"])],
        .pandoc: [(["docx", "odt", "html", "epub", "md", "rtf"], ["docx", "odt", "html", "md", "epub", "rtf", "txt"])],
        .pages: [(["pages", "doc", "docx", "rtf", "txt"], ["pdf", "docx", "epub", "txt", "rtf"])],
        .keynote: [(["key", "pptx", "ppt"], ["pdf", "pptx"])],
        .numbers: [(["numbers", "xlsx", "xls", "csv"], ["pdf", "xlsx"])],
        .builtIn: [(["txt", "rtf", "rtfd", "html", "doc", "docx", "odt", "webarchive"], ["docx", "odt", "rtf", "html", "txt", "doc", "pdf"]),
                   (["md"], ["docx", "odt", "rtf", "html", "txt", "pdf"]),
                   (["jpg", "png", "heic", "tiff", "gif", "bmp", "webp", "avif"], ["jpg", "png", "heic", "tiff", "gif", "bmp", "pdf"]),
                   (["mp3", "m4a", "wav", "aiff", "caf", "aac", "flac"], ["m4a", "wav", "aiff"])],
        .cwebp: [(["jpg", "png", "tiff"], ["webp"])],
        .magick: [(["jpg", "png", "heic", "tiff", "gif", "bmp", "webp", "avif"], ["webp", "avif"])],
        .ffmpeg: [(["jpg", "png", "bmp", "tiff", "gif", "webp"], ["webp"]),
                  (["mov", "mp4", "m4v", "mkv", "webm", "avi", "flv", "wmv", "mpg", "mpeg", "3gp"], ["mp4"]),
                  (["mp3", "m4a", "wav", "aiff", "caf", "aac", "flac", "ogg", "opus"], ["mp3", "flac", "m4a", "wav"])]
    ]

    /// Кого спрашивать первым: у кого вёрстка точнее.
    private static func priority(_ category: Category) -> [ConvertEngine] {
        switch category {
        case .document, .markdown: return [.libreOffice, .pandoc, .pages, .builtIn]
        case .presentation: return [.keynote, .libreOffice]
        case .spreadsheet: return [.numbers, .libreOffice]
        case .image: return [.builtIn, .cwebp, .magick, .ffmpeg]
        case .pdf, .video, .audio: return [.builtIn, .ffmpeg]
        }
    }

    private static let targetOrder = ["pdf", "docx", "odt", "rtf", "doc", "html", "md", "txt", "epub", "pptx", "odp", "xlsx", "ods", "csv",
                                      "jpg", "png", "heic", "webp", "avif", "tiff", "gif", "bmp", "mp4", "m4a", "mp3", "flac", "wav", "aiff"]

    /// Что можно сделать со всеми файлами сразу — по одному лучшему конвертеру на каждый вариант.
    static func options(for urls: [URL], available: Set<ConvertEngine>) -> [ConvertOption] {
        guard let category = urls.first.flatMap(category), urls.allSatisfy({ self.category($0) == category }) else { return [] }
        let exts = Set(urls.map { normalized($0.pathExtension) })
        var result: [ConvertOption] = []
        for target in targetOrder where !(exts.count == 1 && exts.first == target) {
            let engine = priority(category).first { engine in
                available.contains(engine) && (formats[engine] ?? []).contains { exts.isSubset(of: $0.0) && $0.1.contains(target) }
            }
            if let engine { result.append(ConvertOption(job: .format(target), engine: engine)) }
        }
        switch category {
        case .image:
            result.append(ConvertOption(job: .shrink, engine: .builtIn))
            if urls.count > 1 { result.append(ConvertOption(job: .imagesToPDF, engine: .builtIn)) }
        case .pdf:
            result += [ConvertOption(job: .pdfCompress, engine: .builtIn), ConvertOption(job: .pdfPages, engine: .builtIn)]
            if urls.count > 1 { result.append(ConvertOption(job: .pdfMerge, engine: .builtIn)) }
        case .video:
            let engine: ConvertEngine? = exts.isSubset(of: avVideos) ? .builtIn : available.contains(.ffmpeg) ? .ffmpeg : nil
            if let engine {
                result.removeAll { $0.job == .format("mp4") && engine == .builtIn }  // mp4 из mov — это и есть сжатие
                result.insert(contentsOf: [.videoHEVC, .videoH264, .gif, .audioM4A].map { ConvertOption(job: $0, engine: engine) }, at: 0)
            }
            if available.contains(.ffmpeg) { result.append(ConvertOption(job: .audioMP3, engine: .ffmpeg)) }
        default:
            break
        }
        return result
    }

    // MARK: - Запуск

    /// Конвертирует по одному файлу; результаты ложатся рядом с исходными под свободными именами.
    @MainActor
    static func run(_ option: ConvertOption, on urls: [URL], progress: @escaping @MainActor (Double) -> Void,
                    done: @escaping @MainActor (Result<[URL], FileShelf.ActionError>) -> Void) -> ConvertTask {
        let task = ConvertTask()
        let tool = ConvertTools.paths[option.engine] ?? ""
        let finish: @MainActor (Result<[URL], Error>) -> Void = { result in
            if task.isCancelled {
                done(.failure(FileShelf.ActionError(message: L("Остановлено"))))
            } else {
                done(result.mapError { ($0 as? FileShelf.ActionError) ?? FileShelf.ActionError(message: $0.localizedDescription) })
            }
        }
        let viaText: Bool
        if case .format(let ext) = option.job, option.engine == .builtIn {
            // Markdown — всегда, остальные документы — в PDF: через текст AppKit на главном потоке.
            viaText = urls.allSatisfy { markdown.contains($0.pathExtension.lowercased()) }
                || (ext == "pdf" && urls.allSatisfy { documents.contains($0.pathExtension.lowercased()) })
        } else {
            viaText = false
        }
        if viaText, case .format(let ext) = option.job {
            finish(Result { try urls.map { try textDocument($0, to: ext) } })
        } else if option.engine == .builtIn, [.videoHEVC, .videoH264, .audioM4A].contains(option.job) {
            exportAV(option.job, urls, task: task, progress: progress, done: finish)
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try background(option, urls, tool: tool, task: task) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { finish(result) }
                }
            }
        }
        return task
    }

    private static func output(_ url: URL, ext: String, suffix: String = "") -> URL {
        let base = url.deletingPathExtension().lastPathComponent + suffix
        return FileShelf.uniqueURL(url.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension(ext))
    }

    /// Всё, что выполняется вне главного потока: внешние программы, PDFKit, ImageIO.
    private static func background(_ option: ConvertOption, _ urls: [URL], tool: String, task: ConvertTask) throws -> [URL] {
        switch option.job {
        case .format(let ext):
            return try urls.map { url in
                try task.checkCancelled()
                return try format(url, to: ext, engine: option.engine, tool: tool, task: task)
            }
        case .shrink:
            return try urls.map { url in
                let out = output(url, ext: url.pathExtension, suffix: " 1920")
                try task.run("/usr/bin/sips", ["-Z", "1920", url.path, "--out", out.path])
                return out
            }
        case .imagesToPDF:
            let document = PDFDocument()
            for url in urls {
                guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else { continue }
                document.insert(page, at: document.pageCount)
            }
            let out = FileShelf.uniqueURL(urls[0].deletingLastPathComponent().appendingPathComponent(L("Картинки") + ".pdf"))
            guard document.write(to: out) else { throw FileShelf.ActionError(message: L("Не удалось записать PDF")) }
            return [out]
        case .pdfMerge:
            let document = PDFDocument()
            for url in urls {
                guard let part = PDFDocument(url: url) else { continue }
                for i in 0..<part.pageCount { if let page = part.page(at: i) { document.insert(page, at: document.pageCount) } }
            }
            let out = FileShelf.uniqueURL(urls[0].deletingLastPathComponent().appendingPathComponent(L("Объединённый") + ".pdf"))
            guard document.write(to: out) else { throw FileShelf.ActionError(message: L("Не удалось записать PDF")) }
            return [out]
        case .pdfCompress:
            return try urls.map { url in
                guard let document = PDFDocument(url: url) else { throw FileShelf.ActionError(message: L("Не открывается: %@", url.lastPathComponent)) }
                let out = output(url, ext: "pdf", suffix: L(" (сжатый)"))
                guard document.write(to: out, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]) else {
                    throw FileShelf.ActionError(message: L("Не удалось записать PDF"))
                }
                return out
            }
        case .pdfPages:
            return try urls.map { url in try pdfPages(url, task: task) }
        case .gif:
            return try urls.map { url in
                try task.checkCancelled()
                if option.engine == .ffmpeg {
                    let out = output(url, ext: "gif")
                    try task.run(tool, ["-nostdin", "-hide_banner", "-loglevel", "error", "-i", url.path,
                                        "-vf", "fps=10,scale=480:-1:flags=lanczos", out.path])
                    return out
                }
                return try videoToGIF(url, task: task)
            }
        case .videoHEVC, .videoH264, .audioM4A, .audioMP3:
            // Встроенные варианты идут через exportAV; сюда попадает только ffmpeg.
            return try urls.map { url in
                try task.checkCancelled()
                let common = ["-nostdin", "-hide_banner", "-loglevel", "error", "-i", url.path]
                switch option.job {
                case .videoHEVC:
                    let out = output(url, ext: "mp4", suffix: L(" (сжатое)"))
                    try task.run(tool, common + ["-c:v", "hevc_videotoolbox", "-q:v", "55", "-tag:v", "hvc1",
                                                 "-vf", "scale='min(1920,iw)':-2", "-c:a", "aac", "-b:a", "128k", out.path])
                    return out
                case .videoH264:
                    let out = output(url, ext: "mp4", suffix: L(" (сжатое)"))
                    try task.run(tool, common + ["-c:v", "h264_videotoolbox", "-b:v", "2500k", "-vf", "scale='min(1280,iw)':-2",
                                                 "-c:a", "aac", "-b:a", "128k", out.path])
                    return out
                case .audioM4A:
                    let out = output(url, ext: "m4a")
                    try task.run(tool, common + ["-vn", "-c:a", "aac", "-b:a", "192k", out.path])
                    return out
                default:
                    let out = output(url, ext: "mp3")
                    try task.run(tool, common + ["-vn", "-c:a", "libmp3lame", "-q:a", "2", out.path])
                    return out
                }
            }
        }
    }

    /// Файл в другой формат выбранным конвертером.
    private static func format(_ url: URL, to ext: String, engine: ConvertEngine, tool: String, task: ConvertTask) throws -> URL {
        let out = output(url, ext: ext)
        let input = normalized(url.pathExtension)
        switch engine {
        case .builtIn:
            if images.contains(input) {
                let sipsFormat = ["jpg": "jpeg"][ext] ?? ext
                try task.run("/usr/bin/sips", ["-s", "format", sipsFormat, url.path, "--out", out.path])
            } else if avAudios.contains(input) {
                let (file, data) = ["m4a": ("m4af", "aac"), "wav": ("WAVE", "LEI16"), "aiff": ("AIFF", "BEI16")][ext] ?? ("m4af", "aac")
                try task.run("/usr/bin/afconvert", ["-f", file, "-d", data, url.path, out.path])
            } else {
                try task.run("/usr/bin/textutil", ["-convert", ext, url.path, "-output", out.path])
            }
        case .keynote, .pages, .numbers:
            try task.run("/usr/bin/osascript", ["-e", iWorkScript(engine, ext), url.path, out.path])
        case .libreOffice:
            // Своя временная папка и свой профиль: открытый LibreOffice не мешает, одноимённое не затирается.
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mypetbit-lo-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let filter = ext == "txt" ? "txt:Text (encoded):UTF8" : ext
            try task.run(tool, ["-env:UserInstallation=file://\(temp.path)/profile", "--headless", "--convert-to", filter,
                                "--outdir", temp.path, url.path])
            let made = temp.appendingPathComponent(url.deletingPathExtension().lastPathComponent).appendingPathExtension(ext)
            guard FileManager.default.fileExists(atPath: made.path) else { throw FileShelf.ActionError(message: L("LibreOffice не создал файл")) }
            try FileManager.default.moveItem(at: made, to: out)
        case .pandoc:
            try task.run(tool, [url.path, "-o", out.path] + (ext == "txt" ? ["-t", "plain"] : []))
        case .ffmpeg:
            let video = ext == "mp4" ? ["-c:v", "h264_videotoolbox", "-b:v", "5000k", "-c:a", "aac"] : []
            try task.run(tool, ["-nostdin", "-hide_banner", "-loglevel", "error", "-i", url.path] + video + [out.path])
        case .cwebp:
            try task.run(tool, ["-quiet", "-q", "85", url.path, "-o", out.path])
        case .magick:
            try task.run(tool, [url.path, out.path])
        }
        guard FileManager.default.fileExists(atPath: out.path) else { throw FileShelf.ActionError(message: L("Файл не появился: %@", out.lastPathComponent)) }
        return out
    }

    /// Экспорт из Keynote, Pages, Numbers: открыть, сохранить в нужном формате, закрыть; приложение, которого не было, — закрыть.
    static func iWorkScript(_ engine: ConvertEngine, _ ext: String) -> String {
        let app = engine.title
        let format: String
        switch ext {
        case "pdf": format = "PDF"
        case "pptx": format = "Microsoft PowerPoint"
        case "docx": format = "Microsoft Word"
        case "xlsx": format = "Microsoft Excel"
        case "epub": format = "EPUB"
        case "txt": format = "unformatted text"
        default: format = "formatted text"
        }
        return """
        on run argv
            set wasRunning to application "\(app)" is running
            tell application "\(app)"
                set d to open (POSIX file (item 1 of argv))
                export d to (POSIX file (item 2 of argv)) as \(format)
                close d saving no
                if not wasRunning then quit
            end tell
        end run
        """
    }

    // MARK: Текстовые документы и Markdown — через AppKit

    @MainActor
    private static func textDocument(_ url: URL, to ext: String) throws -> URL {
        let text: NSAttributedString
        if markdown.contains(url.pathExtension.lowercased()) {
            text = renderMarkdown(try String(contentsOf: url, encoding: .utf8))
        } else {
            text = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        }
        let out = output(url, ext: ext)
        if ext == "pdf" {
            try writePDF(text, to: out)
        } else if ext == "txt" {
            try text.string.write(to: out, atomically: true, encoding: .utf8)
        } else {
            let types: [String: NSAttributedString.DocumentType] = ["docx": .officeOpenXML, "odt": .openDocument, "rtf": .rtf,
                                                                    "html": .html, "doc": .docFormat]
            guard let type = types[ext] else { throw FileShelf.ActionError(message: L("Не умею в %@", ext)) }
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
            try data.write(to: out)
        }
        return out
    }

    /// Текст на страницы A4 с полями 2 см — печатью в файл.
    @MainActor
    static func writePDF(_ text: NSAttributedString, to url: URL) throws {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)
        info.topMargin = 56
        info.bottomMargin = 56
        info.leftMargin = 56
        info.rightMargin = 56
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 595 - 112, height: 100))
        view.textStorage?.setAttributedString(text)
        view.isVerticallyResizable = true
        view.backgroundColor = .white
        if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
        view.sizeToFit()
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), FileManager.default.fileExists(atPath: url.path) else {
            throw FileShelf.ActionError(message: L("Не удалось записать PDF"))
        }
    }

    /// Markdown в оформленный текст: заголовки, списки, цитаты, код, жирный, курсив, ссылки, таблицы — табуляцией.
    static func renderMarkdown(_ source: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return NSAttributedString(string: source, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
        }
        let out = NSMutableAttributedString()
        var lastBlock: Int?
        var lastRow: Int?
        var lastItem: Int?
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            var font = NSFont.systemFont(ofSize: 12)
            var color = NSColor.black
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 6
            var prefix = ""
            var listDepth = 0
            var row: Int?
            let ordered = components.contains { if case .orderedList = $0.kind { return true } else { return false } }
            for component in components {
                switch component.kind {
                case .header(let level):
                    font = NSFont.boldSystemFont(ofSize: [22, 18, 15, 13, 12, 12][min(max(level, 1), 6) - 1])
                    paragraph.paragraphSpacingBefore = 10
                case .codeBlock:
                    font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                case .blockQuote:
                    color = .darkGray
                    paragraph.headIndent = 18
                    paragraph.firstLineHeadIndent = 18
                case .unorderedList, .orderedList:
                    listDepth += 1
                case .listItem(let ordinal):
                    // Маркер — только у первого куска пункта и только у самого внутреннего пункта.
                    if component.identity != lastItem, prefix.isEmpty, listDepth == 0 {
                        prefix = ordered ? "\(ordinal). " : "• "
                        lastItem = component.identity
                    }
                case .tableRow:
                    row = component.identity
                case .thematicBreak:
                    prefix = "———"
                default:
                    break
                }
            }
            if listDepth > 0 {
                paragraph.headIndent = CGFloat(listDepth) * 18
                paragraph.firstLineHeadIndent = CGFloat(listDepth - 1) * 18
            }
            if let block, block != lastBlock, out.length > 0 {
                out.append(NSAttributedString(string: row != nil && row == lastRow ? "\t" : "\n"))
            }
            lastBlock = block
            lastRow = row
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.code) { font = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular) }
                if inline.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            if run.inlinePresentationIntent?.contains(.strikethrough) == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            out.append(NSAttributedString(string: prefix + String(parsed[run.range].characters), attributes: attributes))
        }
        return out
    }

    // MARK: Видео и аудио — AVFoundation

    @MainActor
    private static func exportAV(_ job: ConvertOption.Job, _ urls: [URL], task: ConvertTask,
                                 progress: @escaping @MainActor (Double) -> Void, done: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        var made: [URL] = []
        func next(_ index: Int) {
            guard index < urls.count else { return done(.success(made)) }
            if task.isCancelled { return done(.failure(FileShelf.ActionError(message: L("Остановлено")))) }
            let url = urls[index]
            let asset = AVURLAsset(url: url)
            let preset: String
            let out: URL
            switch job {
            case .videoHEVC: preset = AVAssetExportPresetHEVC1920x1080; out = output(url, ext: "mp4", suffix: L(" (сжатое)"))
            case .videoH264: preset = AVAssetExportPreset1280x720; out = output(url, ext: "mp4", suffix: L(" (сжатое)"))
            default: preset = AVAssetExportPresetAppleM4A; out = output(url, ext: "m4a")
            }
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                return done(.failure(FileShelf.ActionError(message: L("macOS не умеет так с %@", url.lastPathComponent))))
            }
            session.outputURL = out
            session.outputFileType = job == .audioM4A ? .m4a : .mp4
            session.shouldOptimizeForNetworkUse = true
            task.session = session
            let timer = Timer(timeInterval: 0.3, repeats: true) { _ in
                MainActor.assumeIsolated { progress((Double(index) + Double(session.progress)) / Double(urls.count)) }
            }
            RunLoop.main.add(timer, forMode: .common)
            session.exportAsynchronously {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        timer.invalidate()
                        task.session = nil
                        if session.status == .completed {
                            made.append(out)
                            next(index + 1)
                        } else {
                            try? FileManager.default.removeItem(at: out)
                            done(.failure(FileShelf.ActionError(message: session.error?.localizedDescription ?? L("Остановлено"))))
                        }
                    }
                }
            }
        }
        next(0)
    }

    /// GIF шириной до 480 px, до 200 кадров на всё видео (не чаще 10 в секунду).
    private static func videoToGIF(_ url: URL, task: ConvertTask) throws -> URL {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds > 0 else { throw FileShelf.ActionError(message: L("Не открывается: %@", url.lastPathComponent)) }
        let fps = min(10, 200 / seconds)
        let count = max(1, Int(seconds * fps))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        let out = output(url, ext: "gif")
        guard let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw FileShelf.ActionError(message: L("Не удалось записать GIF"))
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<count {
            try task.checkCancelled()
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: time, actualTime: nil) { CGImageDestinationAddImage(destination, image, frame) }
        }
        guard CGImageDestinationFinalize(destination) else { throw FileShelf.ActionError(message: L("Не удалось записать GIF")) }
        return out
    }

    /// Каждая страница PDF — в PNG (144 точки на дюйм), в папку рядом.
    private static func pdfPages(_ url: URL, task: ConvertTask) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw FileShelf.ActionError(message: L("Не открывается: %@", url.lastPathComponent)) }
        let folder = FileShelf.uniqueURL(url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + L(" — страницы")))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for i in 0..<document.pageCount {
            try task.checkCancelled()
            guard let page = document.page(at: i), let space = CGColorSpace(name: CGColorSpace.sRGB) else { continue }
            let box = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2
            guard let context = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale), bitsPerComponent: 8,
                                          bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: box.width * scale, height: box.height * scale))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            let file = folder.appendingPathComponent(String(format: "%03d.png", i + 1))
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        return folder
    }
}

/// Идущая конвертация: её можно остановить из меню Бита.
final class ConvertTask: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    /// Экспорт AVFoundation (только с главного потока).
    var session: AVAssetExportSession?

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock {
            cancelled = true
            process?.terminate()
        }
        session?.cancelExport()
    }

    func checkCancelled() throws {
        if isCancelled { throw FileShelf.ActionError(message: L("Остановлено")) }
    }

    /// Запустить программу и дождаться; при ошибке — последняя строка её вывода.
    func run(_ path: String, _ args: [String]) throws {
        try checkCancelled()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let err = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        lock.withLock { self.process = process }
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        lock.withLock { self.process = nil }
        try checkCancelled()
        guard process.terminationStatus == 0 else {
            let line = message.split(separator: "\n").last.map(String.init) ?? ""
            throw FileShelf.ActionError(message: line.isEmpty ? "\(URL(fileURLWithPath: path).lastPathComponent): \(process.terminationStatus)" : line)
        }
    }
}

// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Тесты собираются и без Xcode, как в Trunook. У Command Line Tools макросы swift-testing
// лежат в `plugins/testing`, а не в `plugins`, — без этого пути `@Test` не раскрывается.
// Пути добавляются, только если такая раскладка на машине есть: у Xcode (и на CI) всё лежит внутри Xcode.app.
let toolsRoot = "/Library/Developer/CommandLineTools"
let usesCommandLineTools = FileManager.default.fileExists(atPath: "\(toolsRoot)/usr/lib/swift/host/plugins/testing")

let testingSwiftSettings: [SwiftSetting] = usesCommandLineTools
    ? [.unsafeFlags(["-plugin-path", "\(toolsRoot)/usr/lib/swift/host/plugins/testing",
                     "-F", "\(toolsRoot)/Library/Developer/Frameworks"])]
    : []

let testingLinkerSettings: [LinkerSetting] = usesCommandLineTools
    ? [.unsafeFlags(["-F", "\(toolsRoot)/Library/Developer/Frameworks",
                     "-Xlinker", "-rpath", "-Xlinker", "\(toolsRoot)/Library/Developer/Frameworks",
                     "-Xlinker", "-rpath", "-Xlinker", "\(toolsRoot)/Library/Developer/usr/lib"])]
    : []

let package = Package(
    name: "MyPetBit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MyPetBit",
            path: "Sources/MyPetBit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Помощник для музыки: MediaRemote отвечает только процессам с bundle id com.apple.controlcenter.*,
        // поэтому он живёт отдельным бандлом внутри Бита (Helper/Info.plist, как хелпер Trunook).
        .executableTarget(
            name: "MyPetBitMedia",
            path: "Sources/MyPetBitMedia",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Чистая логика: разбор команд и событий агентов, склонения, чтение старых сохранений, ссылки на встречи.
        // Окна, анимации и системные события тестами не покрываются — там проверка дороже ошибки.
        .testTarget(
            name: "MyPetBitTests",
            dependencies: ["MyPetBit"],
            path: "Tests/MyPetBitTests",
            swiftSettings: [.swiftLanguageMode(.v5)] + testingSwiftSettings,
            linkerSettings: testingLinkerSettings
        ),
    ]
)

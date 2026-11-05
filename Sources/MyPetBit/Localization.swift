import Foundation

/// Перевод интерфейса, как в Trunook: ключ — исходная русская строка, переводы — в
/// `Resources/en.lproj` и `Resources/zh-Hans.lproj` (`Localizable.strings`). Нет перевода — остаётся русский.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// Строка с подстановками: все аргументы — строки (`%@`); в переводе порядок можно менять (`%2$@`).
func L(_ key: String, _ args: String...) -> String {
    String(format: L(key), arguments: args.map { $0 as NSString })
}

enum Lang {
    /// Язык интерфейса — ru, en или zh: тот, что macOS выбрала для приложения из настроек пользователя.
    static let current: String = {
        let first = Bundle.main.preferredLocalizations.first ?? "ru"
        if first.hasPrefix("zh") { return "zh" }
        if first.hasPrefix("en") { return "en" }
        return "ru"
    }()

    /// Для дат и дней недели на экране Бита — на языке интерфейса.
    static var locale: Locale {
        Locale(identifier: current == "zh" ? "zh_CN" : current == "en" ? "en_US" : "ru_RU")
    }

    /// Слово «минута» после числа: «5 минут», «5 minutes», «5 分钟».
    static func minutes(_ n: Int, in language: String = current) -> String {
        switch language {
        case "en":
            return n == 1 ? "minute" : "minutes"
        case "zh":
            return "分钟"
        default:
            if (11...14).contains(n % 100) { return "минут" }
            switch n % 10 {
            case 1: return "минуту"
            case 2...4: return "минуты"
            default: return "минут"
            }
        }
    }
}

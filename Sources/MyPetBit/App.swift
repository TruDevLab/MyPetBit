import AppKit
import Combine

@main
enum MyPetBitApp {
    @MainActor
    static func main() {
        // Режим команды для хуков и скриптов: передать сообщение запущенному Биту и выйти.
        if Notices.runCommand(CommandLine.arguments) { return }
        if let folder = UserDefaults.standard.string(forKey: "exportStatusIcons") {
            StatusIcon.export(to: folder)
            return
        }
        migrateFromDeskPet()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Без иконки в Dock и без главного меню: питомец и значок в строке меню.
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// До 1.0 приложение называлось DeskPet (настройки — в домене `local.deskpet`). Один раз переносим всё,
    /// чего в новом домене ещё нет: характер, дружбу, расстановку стола, реакции. Разрешения macOS привязаны
    /// к идентификатору приложения — их переспросит система.
    static func migrateFromDeskPet() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromDeskPet") else { return }
        defaults.set(true, forKey: "migratedFromDeskPet")
        guard let old = defaults.persistentDomain(forName: "local.deskpet"), !old.isEmpty else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PetController!
    private var statusItem: NSStatusItem!
    private var stateSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = PetController()
        controller.show()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Значок в строке меню повторяет настроение Бита.
        stateSubscription = controller.model.$state.removeDuplicates().sink { [weak self] state in
            self?.statusItem.button?.image = StatusIcon.image(for: state)
        }
        let menu = NSMenu()
        menu.delegate = controller
        statusItem.menu = menu
    }
}

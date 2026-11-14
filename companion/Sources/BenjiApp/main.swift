import AppKit
import BenjiCore

LegacyEnvironment.apply()   // first: everything below reads only the BENJI_* names
// Benji's folder: moved from its older names into ~/.benji once, before any object can write a file there.
let homeMove = HomeMigration.run()
HomeMigration.ensureHome()
AppController.homeMove = homeMove
HomeMigration.moveKeyFile()   // before the engine starts and looks for it
DefaultsMigration.run(finish: homeMove.kind != .busy)   // before anything reads a setting; not marked done while the old app can still change them
DefaultsMigration.figureSensing()
if homeMove.kind != .busy {
    BrowserRenameMigration.reconcile(home: FileManager.default.homeDirectoryForCurrentUser,
                                     assistantDir: AppConfig.assistantDir,
                                     browserOn: BrowserSetting.isOn(UserDefaults.standard.object(forKey: BrowserSetting.defaultsKey)),
                                     othersRunning: !HomeMigration.otherProcesses(home: FileManager.default.homeDirectoryForCurrentUser).isEmpty)
}
let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()

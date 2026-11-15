import AppKit
import BenjiCore

WorkingFolder.ensureHome()   // ~/.benji, private, before any object can write a file there
let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()

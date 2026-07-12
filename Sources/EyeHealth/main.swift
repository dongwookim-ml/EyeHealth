import AppKit

// EyeHealth runs as a menu bar accessory (no dock icon, no main window).
let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()

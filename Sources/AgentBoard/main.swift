import AppKit

if isBench {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    // Animations pace to the display only once the app is running; before that they tick as fast as the run loop spins.
    // A run loop block, not a main-queue one: the bench spins nested run loops that must still drain the main queue.
    RunLoop.main.perform {
        Bench.run()
        exit(0)
    }
    NSApp.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.mainMenu = editingMenu()
app.run()

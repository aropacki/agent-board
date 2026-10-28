import AppKit

/// Text fields take ⌘C, ⌘V, and the other editing keys from the main menu's key equivalents. The app never shows a
/// menu bar, but without a main menu those keys reach nothing.
func editingMenu() -> NSMenu {
    let edit = NSMenu(title: "Edit")
    let items: [(String, Selector, String, NSEvent.ModifierFlags)] = [
        ("Undo", Selector(("undo:")), "z", .command),
        ("Redo", Selector(("redo:")), "z", [.command, .shift]),
        ("Cut", #selector(NSText.cut(_:)), "x", .command),
        ("Copy", #selector(NSText.copy(_:)), "c", .command),
        ("Paste", #selector(NSText.paste(_:)), "v", .command),
        ("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
        ("Select All", #selector(NSText.selectAll(_:)), "a", .command),
    ]
    for (title, action, key, modifiers) in items {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        edit.addItem(item)
    }
    let holder = NSMenuItem()
    holder.submenu = edit
    let main = NSMenu()
    main.addItem(NSMenuItem())
    main.addItem(holder)
    return main
}

// MainMenu — the app menu shown while a Flickwise window is open (the app is a menu bar
// app otherwise). The Edit menu matters: without it ⌘C/⌘V/⌘A don't work in text fields.
import AppKit

enum MainMenu {
    static func make(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "Flickwise")
        app.addItem(item("About Flickwise", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", nil))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(AppDelegate.showSettings), ",", target))
        app.addItem(item("Set Up & Permissions…", #selector(AppDelegate.showSetup), "", target))
        app.addItem(.separator())
        app.addItem(item("Hide Flickwise", #selector(NSApplication.hide(_:)), "h", nil))
        app.addItem(item("Quit Flickwise", #selector(NSApplication.terminate(_:)), "q", nil))
        add(app, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z", nil))
        edit.addItem(item("Redo", Selector(("redo:")), "Z", nil))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x", nil))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c", nil))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v", nil))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a", nil))
        add(edit, to: main)

        let window = NSMenu(title: "Window")
        window.addItem(item("Voice History", #selector(AppDelegate.showHistory), "1", target))
        window.addItem(.separator())
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", nil))
        window.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w", nil))
        add(window, to: main)
        NSApp.windowsMenu = window
        return main
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let holder = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ target: AnyObject?) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = target
        return it
    }
}

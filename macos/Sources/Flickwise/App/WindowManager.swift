// WindowManager — opens the app's few windows (History, Settings, Setup) as normal,
// focused windows on the active Space (also over full-screen apps). While any window is open, Flickwise shows in the Dock and ⌘-Tab;
// when the last one closes it goes back to being a menu bar app.
import AppKit
import SwiftUI

final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var windows: [String: NSWindow] = [:]

    func show<V: View>(_ id: String, title: String, size: NSSize, resizable: Bool = true, @ViewBuilder content: () -> V) {
        if let win = windows[id] {
            activate()
            win.makeKeyAndOrderFront(nil)
            return
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        win.title = title
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.contentViewController = NSHostingController(rootView: content())
        win.setContentSize(size)
        win.minSize = NSSize(width: min(size.width, 520), height: min(size.height, 420))
        win.center()
        win.setFrameAutosaveName("Flickwise.\(id)")
        win.identifier = NSUserInterfaceItemIdentifier(id)
        // Open on the Space you're on, even over a full-screen app (otherwise macOS puts it on
        // a desktop Space and it looks like nothing opened).
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        win.delegate = self
        windows[id] = win
        activate()
        win.makeKeyAndOrderFront(nil)
        Log.debug("Window \(id) at \(win.frame) on \(win.screen?.localizedName ?? "no screen"), visible=\(win.isVisible)")
    }

    func close(_ id: String) { windows[id]?.close() }

    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow, let id = win.identifier?.rawValue else { return }
        windows[id] = nil
        if windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }

    private func activate() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

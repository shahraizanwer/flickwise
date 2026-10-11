// AppDelegate — wires everything together: settings, modes, the dictation controller, text fixes
// (global hotkeys, picker, radial menu), the menu bar item, and the windows. Launch does almost nothing up front (no
// network, no audio) so the app is ready in a few milliseconds.
import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?

    let store = SettingsStore.shared
    private(set) var dictation: DictationController!
    private var statusItem: NSStatusItem!
    private var bag = Set<AnyCancellable>()
    private var axPoll: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        if quitIfAlreadyRunning() { return }
        Log.rotate()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        Log.info("Flickwise \(version) started")

        NSApp.mainMenu = MainMenu.make(target: self)
        let launchedAtLogin = Self.launchedAsLoginItem()
        LegacyImport.migrateIfNeeded(store)              // once: Hammerspoon fix settings + fix history
        resolveImportedRadialModes()
        dictation = DictationController(store: store)
        dictation.onStateChange = { [weak self] _ in self?.updateIcon() }
        setUpStatusItem()

        ModeStore.shared.$modes.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.registerHotkeys() }
        }.store(in: &bag)
        store.$settings.map(\.picker).removeDuplicates().dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.registerHotkeys() }
        }.store(in: &bag)
        registerHotkeys()

        store.$settings.dropFirst().receive(on: RunLoop.main).sink { [weak self] new in
            self?.dictation.apply()
            RadialMenu.shared.apply()
            self?.updateIcon()
            self?.prepareSpeechModel(new)
            HistoryStore.shared.prune(olderThanDays: new.history.retentionDays)
        }.store(in: &bag)
        NotificationCenter.default.addObserver(forName: ModelStore.didInstall, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.prepareSpeechModel(self.store.settings)
            }
        }
        prepareSpeechModel(store.settings)

        LegacyImport.importAPIKeyIfMissing()
        HistoryStore.shared.prune(olderThanDays: store.settings.history.retentionDays)
        if !dictation.apply() { waitForAccessibility() }
        RadialMenu.shared.apply()
        Log.info("Accessibility: \(Permissions.accessibility), microphone: \(Permissions.microphone.rawValue), "
                 + "engine: \(store.settings.transcription.engine.rawValue), ready: \(speechReady)")
        if !Permissions.accessibility || !speechReady || Permissions.microphone != .authorized {
            showSetup()
        } else if !launchedAtLogin && ProcessInfo.processInfo.environment["FLICKWISE_OPEN"] == nil {
            showHistory()          // opened by hand: show something (the menu bar icon may be hidden)
        }
        switch ProcessInfo.processInfo.environment["FLICKWISE_OPEN"] {   // tests: open a window at launch
        case "history": showHistory()
        case "settings": showSettings()
        case "modes": show(.modes)
        case "hud": demoHUD()
        default: break
        }
    }

    /// Opening the app again (Finder, Spotlight, Dock) while it runs brings up History.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showHistory() }
        return true
    }

    /// True when the menu bar is so full that macOS put our icon behind the camera notch.
    var menuBarIconHidden: Bool {
        guard let win = statusItem?.button?.window, let screen = win.screen ?? NSScreen.main else { return false }
        let left = screen.auxiliaryTopLeftArea ?? .zero, right = screen.auxiliaryTopRightArea ?? .zero
        guard left != .zero || right != .zero else { return false }        // no notch
        let x = win.frame.midX
        return !(x >= left.minX && x <= left.maxX) && !(x >= right.minX && x <= right.maxX)
    }

    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictation?.shutdown()
        RadialMenu.shared.stop()
        GlobalHotkeys.shared.unregisterAll()
        WhisperEngine.shared.shutdown()
        Log.info("Flickwise stopped")
    }

    /// Called by the setup window as soon as Accessibility is granted.
    func permissionsChanged() {
        if dictation.apply() { axPoll?.invalidate(); axPoll = nil; updateIcon() }
        RadialMenu.shared.apply()
    }

    // ── windows ──────────────────────────────────────────────────────────────

    @objc func showHistory() { show(.history) }
    @objc func showProgress() { show(.progress) }
    @objc func showModes() { show(.modes) }
    @objc func showSettings() {
        let p = MainNav.shared.page
        show([.modes, .dictation, .features, .ai, .general].contains(p) ? p : .modes)
    }

    func show(_ page: MainNav.Page) {
        MainNav.shared.page = page
        WindowManager.shared.show("main", title: "Flickwise", size: NSSize(width: 980, height: 680)) { MainWindowView() }
    }

    @objc func showSetup() {
        WindowManager.shared.show("setup", title: "Set Up Flickwise", size: NSSize(width: 560, height: 680)) { SetupView() }
    }

    // ── menu bar ─────────────────────────────────────────────────────────────

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let name: String
        switch dictation?.state ?? .idle {
        case .recording: name = "waveform.circle.fill"
        case .processing: name = "ellipsis.circle"
        default: name = (dictation?.isListening ?? false) && store.settings.dictation.enabled ? "waveform" : "waveform.slash"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Flickwise")
        image?.isTemplate = true
        button.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = store.settings.dictation
        let header: String
        if !Permissions.accessibility { header = "Needs Accessibility access" }
        else if !speechReady { header = "Set up speech recognition" }
        else if !s.enabled { header = "Dictation is paused" }
        else { header = "Hold \(s.trigger.short) to dictate · \(s.style.title)" }
        let info = NSMenuItem(title: header, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        let today = HistoryStore.shared.stats().todayWords
        if today > 0 {
            let words = NSMenuItem(title: "\(today.formatted()) words dictated today", action: nil, keyEquivalent: "")
            words.isEnabled = false
            menu.addItem(words)
        }
        menu.addItem(.separator())

        let modes = NSMenuItem(title: "Modes", action: nil, keyEquivalent: "")
        let modesMenu = NSMenu()
        for m in ModeStore.shared.enabledModes {
            let it = item(m.name, #selector(runModeFromMenu(_:)), "")
            it.representedObject = m.id
            if let hk = m.hotkey { it.title += "    \(hk.display)" }
            modesMenu.addItem(it)
        }
        modesMenu.addItem(.separator())
        modesMenu.addItem(item("Mode Picker…  \(store.settings.picker.hotkey.display)", #selector(openPicker), ""))
        modesMenu.addItem(item("Edit Modes…", #selector(showModes), ""))
        modes.submenu = modesMenu
        menu.addItem(modes)
        let features = NSMenuItem(title: "Features", action: nil, keyEquivalent: "")
        let featuresMenu = NSMenu()
        for (key, title, on) in featureToggles() {
            let it = item(title, #selector(toggleFeature(_:)), "")
            it.representedObject = key
            it.state = on ? .on : .off
            featuresMenu.addItem(it)
        }
        features.submenu = featuresMenu
        menu.addItem(features)
        menu.addItem(.separator())
        menu.addItem(item("Open Flickwise…", #selector(showHistory), "o"))
        menu.addItem(item("My Progress…", #selector(showProgress), ""))
        let styles = NSMenuItem(title: "Dictation Style", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for style in DictationStyle.allCases {
            let it = item(style.title, #selector(pickStyle(_:)), "")
            it.representedObject = style.rawValue
            it.state = style == s.style ? .on : .off
            sub.addItem(it)
        }
        styles.submenu = sub
        menu.addItem(styles)
        let pause = item(s.enabled ? "Pause Dictation" : "Resume Dictation", #selector(togglePause), "")
        menu.addItem(pause)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), ","))
        menu.addItem(item("Set Up & Permissions…", #selector(showSetup), ""))
        menu.addItem(.separator())
        menu.addItem(item("Quit Flickwise", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = target ?? self
        return it
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let style = DictationStyle(rawValue: raw) {
            store.settings.dictation.style = style
        }
    }

    @objc private func runModeFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let mode = ModeStore.shared.mode(id: id) else { return }
        // The menu closes first; the app you were in still has focus (a menu bar menu doesn't take it).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { FixController.shared.run(mode) }
    }

    @objc private func openPicker() { ModePicker.shared.open() }

    private func featureToggles() -> [(String, String, Bool)] {
        let s = store.settings
        return [
            ("dictation", "Voice Dictation (Hold \(s.dictation.trigger.short))", s.dictation.enabled),
            ("diff", "“What Changed” Card + Undo", s.diffCard.enabled),
            ("radial", "Radial Menu (Hold \(s.radialMenu.trigger.short))", s.radialMenu.enabled),
            ("picker", "Mode Picker (\(s.picker.hotkey.display))", s.picker.enabled),
            ("direct", "Replace Without Clipboard", s.fixes.directReplace),
            ("answer", "Answer Card", s.resultCard.enabled),
            ("reply", "Reply Helper Card", s.replyCard.enabled),
            ("history", "History & My Progress", s.history.enabled),
        ]
    }

    @objc private func toggleFeature(_ sender: NSMenuItem) {
        switch sender.representedObject as? String {
        case "dictation": store.settings.dictation.enabled.toggle()
        case "diff": store.settings.diffCard.enabled.toggle()
        case "radial": store.settings.radialMenu.enabled.toggle()
        case "picker": store.settings.picker.enabled.toggle()
        case "direct": store.settings.fixes.directReplace.toggle()
        case "answer": store.settings.resultCard.enabled.toggle()
        case "reply": store.settings.replyCard.enabled.toggle()
        case "history": store.settings.history.enabled.toggle()
        default: break
        }
    }

    // ── text fixes ───────────────────────────────────────────────────────────

    /// Every enabled mode with a shortcut, plus the picker. Re-run whenever modes or settings change.
    func registerHotkeys() {
        var entries: [(combo: KeyCombo, label: String, action: () -> Void)] = []
        for m in ModeStore.shared.enabledModes {
            guard let hk = m.hotkey else { continue }
            let id = m.id
            entries.append((hk, m.name, {
                guard let mode = ModeStore.shared.mode(id: id) else { return }
                FixController.shared.run(mode)
            }))
        }
        if store.settings.picker.enabled {
            entries.append((store.settings.picker.hotkey, "Mode picker", { ModePicker.shared.open() }))
        }
        GlobalHotkeys.shared.register(entries)
    }

    /// Radial menu modes imported from Hammerspoon by name → ids, once modes exist.
    private func resolveImportedRadialModes() {
        let names = store.settings.radialMenu.modeNames
        guard !names.isEmpty else { return }
        let modes = ModeStore.shared.modes
        store.settings.radialMenu.modes = names.compactMap { n in modes.first { $0.name == n }?.id }
        store.settings.radialMenu.modeNames = []
    }

    @objc private func togglePause() {
        store.settings.dictation.enabled.toggle()
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    /// The selected engine can run: the local model is downloaded, or a Gemini key is saved.
    var speechReady: Bool {
        let t = store.settings.transcription
        switch t.engine {
        case .local: return WhisperModel.find(t.model).map(ModelStore.shared.isInstalled) ?? false
        case .gemini: return Secrets.hasAPIKey
        }
    }

    /// Keeps the selected local model loaded (or frees it when it isn't needed).
    private func prepareSpeechModel(_ s: AppSettings) {
        let t = s.transcription
        guard t.engine == .local, let model = WhisperModel.find(t.model), ModelStore.shared.isInstalled(model) else {
            WhisperEngine.shared.unload()
            return
        }
        if t.keepModelLoaded {
            WhisperEngine.shared.preload(model)
        } else if dictation.state == .idle {
            WhisperEngine.shared.unload()
            WhisperEngine.shared.warmUp(model)     // one-time setup now, not on the first dictation
        }
    }

    /// FLICKWISE_OPEN=hud: plays the pill's states with a fake waveform (for checking the UI).
    private func demoHUD() {
        HUD.shared.listening(hint: "esc to cancel")
        var t = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            t += 0.05
            HUD.shared.level(Float(abs(sin(t * 3)) * (0.4 + 0.6 * Double.random(in: 0...1))))
            if t > 3 { timer.invalidate() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { HUD.shared.working("Transcribing…") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            HUD.shared.done("Inserted", detail: "I think we should move the meeting to Thursday because…")
        }
    }

    /// Accessibility can be granted in System Settings at any time: keep checking.
    private func waitForAccessibility() {
        axPoll?.invalidate()
        axPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard Permissions.accessibility else { return }
            MainActor.assumeIsolated { self?.permissionsChanged() }
        }
    }

    private func quitIfAlreadyRunning() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return false }
        NSApp.terminate(nil)
        return true
    }
}

import AppKit
import KeyboardShortcuts
import SwiftUI
import os
import ServiceManagement

@main
struct ShporaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI wraps the app delegate, so `NSApp.delegate as? AppDelegate` is nil; use this instead.
    static private(set) weak var shared: AppDelegate?
    let model = AppModel()
    private var window: WindowController!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var keyMonitor: Any?
    private let log = Logger(subsystem: "ru.nagornik.shpora", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        buildMainMenu()
        window = WindowController(model: model)
        setupStatusItem()
        model.onIconsChange = { [weak self] in self?.applyIcons() }
        NSApp.setActivationPolicy(model.showInDock ? .regular : .accessory)
        statusItem.isVisible = model.showInMenuBar

        KeyboardShortcuts.onKeyDown(for: .toggleShpora) { [weak self] in
            MainActor.assumeIsolated { self?.window.toggle() }
        }
        installKeyMonitor()
        #if DEBUG
        TestHooks.install(model: model, window: window)
        #endif

        // Sleep or logout must not leave a single keystroke only in memory.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.flushAll() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.flushAll() }
        }

        #if !DEBUG
        enableLaunchAtLoginOnce()   // never register a throwaway debug build as a login item
        #endif
        window.show()
        log.info("launched")
    }

    /// Owner's main fear is losing notes after a restart: start with the Mac by default, once.
    /// If he turns it off in Settings, that choice stays.
    private func enableLaunchAtLoginOnce() {
        let key = "launchAtLoginDefaulted"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        do { try SMAppService.mainApp.register() } catch {
            log.error("launch at login: \(error.localizedDescription, privacy: .public)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.flushAll()
    }

    /// Opening Shpora again (Finder, Spotlight, Dock) always shows the window — the way back in
    /// even with no Dock icon, no menu-bar icon and a forgotten shortcut.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.show()
        return false
    }

    /// Dock and menu-bar icons follow Settings → General.
    private func applyIcons() {
        NSApp.setActivationPolicy(model.showInDock ? .regular : .accessory)
        statusItem?.isVisible = model.showInMenuBar
        if !model.showInDock { window.panel.orderFrontRegardless() }   // switching policy may hide windows
        // Switching the Dock icon off drops the app's focus; give it back to Settings, where the
        // owner just clicked, or the next click there only re-focuses the window.
        if let s = settingsWindow, s.isVisible {
            DispatchQueue.main.async { NSApp.activate(); s.makeKeyAndOrderFront(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Keys inside the window

    /// The panel never activates the app (so the dialer keeps focus), which means menu shortcuts
    /// are not guaranteed — our own window keys are handled here directly.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // ⌘W closes any other Shpora window (Settings) — there is no File menu to do it.
            if event.window !== self.window.panel {
                if event.keyCode == 13, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                    event.window?.performClose(nil); return nil
                }
                return event
            }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53, mods.isEmpty {   // Esc
                // Esc first closes what is open inside the window (find bar); only then hides it,
                // so a reflex Esc mid-call doesn't make the notes vanish.
                if let tv = event.window?.firstResponder as? NSTextView,
                   let scroll = tv.enclosingScrollView, scroll.isFindBarVisible {
                    scroll.isFindBarVisible = false
                    event.window?.makeFirstResponder(tv)
                    return nil
                }
                self.window.hide(); return nil
            }
            // Owner-configurable window keys (Settings → Shortcuts). Only here, i.e. only while the
            // Shpora window has focus — never global, so they don't steal ⌘D etc. from other apps.
            if let pressed = KeyboardShortcuts.Shortcut(event: event) {
                if pressed == KeyboardShortcuts.getShortcut(for: .toggleSplitPane) { self.model.toggleSplit(); return nil }
                if pressed == KeyboardShortcuts.getShortcut(for: .openSettings) { self.openSettings(); return nil }
            }
            // Physical keys, not letters: with the Russian layout ⌘W arrives as "ц" and was ignored.
            let cmdOnly = mods == .command, cmdShift = mods == [.command, .shift]
            guard cmdOnly || cmdShift else { return event }
            switch (event.keyCode, cmdShift) {
            case (13, false): if self.model.splitOpen { self.model.setSplit(false) } else { self.window.hide() }   // W
            case (17, false): self.model.insertTimestamp()                                                        // T
            case (31, false): self.model.openActiveInDefaultApp()                                                 // O
            case (33, false): self.model.focus(.left)                                                             // [
            case (30, false): self.model.focus(.right)                                                            // ]
            case (24, _): self.model.changeFont(by: 1)                                                            // = and +
            case (27, false): self.model.changeFont(by: -1)                                                       // -
            case (29, false): self.model.fontSize = 17                                                            // 0
            default: return self.performEditKey(event.keyCode, shift: cmdShift) ? nil : event
            }
            return nil
        }
    }

    /// ⌘A/C/V/X/Z/F/G inside the panel. The Edit menu only fires while Shpora is the active app,
    /// and the panel deliberately never activates it — so without this the text editor had no
    /// copy/paste at all (owner 12.11.2026). Physical keys, so the Russian layout works too.
    private func performEditKey(_ keyCode: UInt16, shift: Bool) -> Bool {
        var findTag: NSFindPanelAction?
        let action: Selector
        switch (keyCode, shift) {
        case (0, false): action = #selector(NSText.selectAll(_:))       // A
        case (8, false): action = #selector(NSText.copy(_:))            // C
        case (9, false): action = #selector(NSText.paste(_:))           // V
        case (7, false): action = #selector(NSText.cut(_:))             // X
        case (6, false): action = Selector(("undo:"))                   // Z
        case (6, true):  action = Selector(("redo:"))                   // ⇧Z
        case (3, false): action = #selector(NSTextView.performFindPanelAction(_:)); findTag = .showFindPanel  // F
        case (5, false): action = #selector(NSTextView.performFindPanelAction(_:)); findTag = .next          // G
        case (5, true):  action = #selector(NSTextView.performFindPanelAction(_:)); findTag = .previous      // ⇧G
        default: return false
        }
        // The find bar reads the action kind from the sender's tag, as it would from a menu item.
        let sender: Any? = findTag.map { tag -> NSMenuItem in let m = NSMenuItem(); m.tag = Int(tag.rawValue); return m }
        let handled = NSApp.sendAction(action, to: nil, from: sender)
        log.debug("edit key \(keyCode) shift=\(shift) handled=\(handled)")
        return handled
    }

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettingsAction), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit Shpora"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = edit.addItem(withTitle: String(localized: "Find…"), action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: Menu bar icon

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Own glyph (the folded cheat sheet from the app icon). The asset is marked as a template,
        // so the menu bar recolours it for light and dark bars by itself.
        let glyph = NSImage(named: "MenuBarIcon")
        glyph?.size = NSSize(width: 18, height: 18)
        glyph?.accessibilityDescription = "Shpora"
        statusItem.button?.image = glyph
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Show Shpora"), action: #selector(showAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettingsAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Shpora"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func showAction() { window.show() }
    @objc private func openSettingsAction() { openSettings() }

    func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = String(localized: "Shpora Settings")
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.contentView = NSHostingView(rootView: SettingsView().environmentObject(model))
            w.center()
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

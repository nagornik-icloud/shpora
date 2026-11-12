#if DEBUG
import AppKit
import os

/// Debug-only remote control for automated checks (the screen-control tool can't see menu-bar apps).
/// Send: `xcrun swift scripts/send.swift <command> [arg]`. Not compiled into Release.
@MainActor
enum TestHooks {
    static func install(model: AppModel, window: WindowController) {
        let log = Logger(subsystem: "ru.nagornik.shpora", category: "test")
        DistributedNotificationCenter.default().addObserver(forName: .init("ru.nagornik.shpora.test"), object: nil, queue: .main) { note in
            let cmd = note.object as? String ?? ""
            let arg = (note.userInfo?["arg"] as? String) ?? ""
            log.info("test command \(cmd, privacy: .public)")
            MainActor.assumeIsolated {
                switch cmd {
                case "show": window.show()
                case "hide": window.hide()
                case "toggle": window.toggle()
                case "split": model.setSplit(true)
                case "unsplit": model.setSplit(false)
                case "type": model.testType(arg)
                case "timestamp": model.insertTimestamp()
                case "left": model.focus(.left)
                case "right": model.focus(.right)
                case "settings": AppDelegate.shared?.openSettings()
                case "bg": if let b = WindowBackground(rawValue: arg) { model.background = b }
                case "keystate":
                    // Lets the walk-through tool type only when Shpora really holds the keyboard.
                    // Any Shpora window (main panel or settings) holding the keyboard counts.
                    let ok = NSApp.windows.contains { $0.isVisible && $0.isKeyWindow }
                    try? (ok ? "1" : "0").write(toFile: NSTemporaryDirectory() + "shpora-keystate", atomically: true, encoding: .utf8)
                case "backdrop": showBackdrop(behind: window.panel, light: arg == "light")
                // Site screenshots (09.11.2026): light or dark window look without touching the
                // owner's system appearance setting. Debug build only.
                case "appearance": NSApp.appearance = NSAppearance(named: arg == "dark" ? .darkAqua : .aqua)
                case "frame":
                    let v = arg.split(separator: ",").compactMap { Double($0) }
                    if v.count == 4 { window.panel.setFrame(NSRect(x: v[0], y: v[1], width: v[2], height: v[3]), display: true) }
                default: break
                }
            }
        }
    }
}

/// A known, colourful picture placed right behind the panel, so a region screenshot shows how
/// the glass looks without capturing anything of the owner's own screen.
@MainActor private var backdropWindow: NSWindow?

@MainActor private func showBackdrop(behind panel: NSPanel, light: Bool) {
    backdropWindow?.orderOut(nil)
    let frame = panel.frame.insetBy(dx: -40, dy: -40)
    let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.level = .floating
    w.isReleasedWhenClosed = false
    let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
    v.wantsLayer = true
    let g = CAGradientLayer()
    g.frame = v.bounds
    g.colors = light
        ? [NSColor.systemYellow.cgColor, NSColor.white.cgColor, NSColor.systemTeal.cgColor]
        : [NSColor.systemBlue.cgColor, NSColor.systemPurple.cgColor, NSColor.systemOrange.cgColor]
    g.startPoint = CGPoint(x: 0, y: 0); g.endPoint = CGPoint(x: 1, y: 1)
    v.layer?.addSublayer(g)
    for i in 0..<8 {
        let t = NSTextField(labelWithString: "Viber · Call with lead · 03:1\(i)")
        t.font = .boldSystemFont(ofSize: 30)
        t.textColor = light ? .black : .white
        t.frame = NSRect(x: 30 + CGFloat(i % 2) * 220, y: CGFloat(i) * 52 + 10, width: 700, height: 40)
        v.addSubview(t)
    }
    w.contentView = v
    w.order(.below, relativeTo: panel.windowNumber)
    backdropWindow = w
}

extension AppModel {
    func testType(_ s: String) {
        focusActive()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            let side: Side = self.splitOpen ? self.activeSide : .left
            self.insert(s, side: side)
        }
    }
}
#endif

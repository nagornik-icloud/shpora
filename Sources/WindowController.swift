import AppKit
import SwiftUI
import os

/// Floating panel that stays above everything, including other apps' full-screen spaces,
/// and does not hide when the user clicks into another app (owner: «Всегда видно»).
final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Transparent window so the glass/blur backdrop shows what is behind it.
        isOpaque = false
        backgroundColor = .clear
        minSize = NSSize(width: AppModel.minPane, height: 160)
        standardWindowButton(.zoomButton)?.isEnabled = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The first click on an unfocused Shpora window must already press the button under it
/// ("+", gear, split icon), not just focus the window — the owner clicks it mid-call.
final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class WindowController: NSObject, NSWindowDelegate {
    let panel = FloatingPanel()
    private let model: AppModel
    private let log = Logger(subsystem: "ru.nagornik.shpora", category: "window")
    private let defaults = UserDefaults.standard
    private var animating = false

    private static let singleKey = "frame.single"
    private static let splitKey = "frame.split"

    init(model: AppModel) {
        self.model = model
        super.init()
        panel.delegate = self
        let host = FirstClickHostingView(rootView: AnyView(ContentView(controller: self).environmentObject(model)))
        host.sizingOptions = []
        let container = BackdropContainer(content: host)
        container.wantsLayer = true   // the show animation moves this layer, never the window
        container.apply(model.background)
        panel.contentView = container
        model.onBackgroundChange = { [weak container] style in container?.apply(style) }
        panel.setFrame(initialFrame(), display: false)
        panel.minSize.width = Self.minWidth(split: model.splitOpen)
        model.onSplitChange = { [weak self] open in self?.animateSplit(open) }
    }

    // MARK: Show / hide

    var isShown: Bool { panel.isVisible && panel.alphaValue > 0.5 }

    func toggle() {
        // Visible but focus is elsewhere (user clicked the dialer): bring focus back, don't hide.
        if isShown && panel.isKeyWindow { hide() } else { show() }
    }

    /// Bumped on every show/hide: a late "hide finished" must not order out a window that was
    /// shown again in the meantime (owner saw it vanish instead of appearing, 1 in 16).
    private var visibilityGeneration = 0

    func show() {
        visibilityGeneration += 1
        if !panel.isVisible || panel.alphaValue < 0.99 {
            // Fade in while the CONTENT rises 6 pt (layer transform). The window frame itself never
            // moves: moving it and snapping it back at the end was the visible 5-px jerk.
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            if let layer = panel.contentView?.layer {
                let rise = CABasicAnimation(keyPath: "transform.translation.y")
                rise.fromValue = -6; rise.toValue = 0; rise.duration = 0.2
                rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(rise, forKey: "rise")
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
        }
        panel.makeKey()
        model.focusActive(after: 0.02)
        log.info("show")
    }

    func hide() {
        model.flushAll()
        visibilityGeneration += 1
        let gen = visibilityGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.visibilityGeneration else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
        log.info("hide")
    }

    // MARK: Second pane

    /// The left pane never changes width or place on screen. Opening: the window grows to the right
    /// by the right pane's width (narrower right pane if the screen edge is near). Closing: the window
    /// shrinks back to exactly the left pane. The right pane is drawn at a fixed width the whole time
    /// and is just uncovered/covered by the moving edge, fading in/out — nothing re-lays out.
    private static let rightKey = "rightPaneWidth"

    /// The window can't be dragged narrower than its panes' minimums allow.
    private static func minWidth(split: Bool) -> CGFloat { split ? AppModel.minPane * 2 + 1 : AppModel.minPane }

    private func animateSplit(_ open: Bool) {
        let cur = panel.frame
        panel.minSize.width = Self.minWidth(split: open)
        let screen = (panel.screen ?? NSScreen.main)?.visibleFrame ?? cur
        var target = cur
        if open {
            model.leftWidth = cur.width
            let wantedRight = max(260, CGFloat(defaults.double(forKey: Self.rightKey)) > 0 ? CGFloat(defaults.double(forKey: Self.rightKey)) : cur.width)
            // The right pane always opens at its remembered width; if the screen edge is in the way,
            // the whole window slides left as far as needed (owner 09.11.2026).
            let right = max(AppModel.minPane, min(wantedRight, screen.width - cur.width - 1))
            if cur.maxX + 1 + right > screen.maxX { target.origin.x = max(screen.minX, screen.maxX - cur.width - 1 - right) }
            target.size.width = cur.width + 1 + right
            model.rightRevealWidth = right
            model.rightOpacity = 0
            model.splitVisible = true
            withAnimation(.easeOut(duration: 0.3)) { model.rightOpacity = 1 }
        } else {
            let left = min(model.leftWidth, cur.width)
            defaults.set(Double(cur.width - left - 1), forKey: Self.rightKey)
            model.rightRevealWidth = cur.width - left - 1
            target.size.width = max(panel.minSize.width, left)
            // Fade out BEFORE the edge reaches the text, so nothing is visibly cut mid-word.
            withAnimation(.linear(duration: 0.1)) { model.rightOpacity = 0 }
        }

        animating = true
        // The toolbar rides the moving edge and would sweep across the right file's name: hide it
        // for the length of the animation.
        var instant = Transaction(); instant.disablesAnimations = true
        withTransaction(instant) { model.toolbarHidden = true }   // gone before the first frame moves
        // Closing: let the right pane fade out first, so the moving edge never cuts visible text.
        let delay: TimeInterval = open ? 0 : 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // Build and draw the right pane BEFORE the clock starts: otherwise that first layout
            // stalls the main thread, the time-based frame animation skips ahead, and the window
            // leaps 60–90% of the way in a single frame (measured 09.11.2026).
            self.panel.contentView?.layoutSubtreeIfNeeded()
            self.panel.displayIfNeeded()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            self.panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) {
                    if !open { self.model.splitVisible = false }
                    self.model.rightRevealWidth = nil
                    self.model.rightOpacity = 1
                }
                self.animating = false
                withAnimation(.easeOut(duration: 0.15)) { self.model.toolbarHidden = false }
                self.saveFrame()
            }
        })
        }
    }

    // MARK: Frames

    private func initialFrame() -> NSRect {
        let key = model.splitOpen ? Self.splitKey : Self.singleKey
        if let s = defaults.string(forKey: key) {
            let r = NSRectFromString(s)
            if r.width >= 200, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) { return r }
        }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w: CGFloat = model.splitOpen ? 900 : 520, h: CGFloat = 300
        return NSRect(x: screen.midX - w / 2, y: screen.minY + screen.height * 0.6, width: w, height: h)
    }

    private func saveFrame() {
        guard !animating else { return }
        defaults.set(NSStringFromRect(panel.frame), forKey: model.splitOpen ? Self.splitKey : Self.singleKey)
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()   // the red dot hides; notes are already on disk
        return false
    }
}

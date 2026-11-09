import AppKit
import SwiftUI

/// How the window's backdrop looks (owner 09.11.2026: «полупрозрачным с эффектом стекла»).
enum WindowBackground: String, CaseIterable, Identifiable {
    // "frosted" removed 09.11.2026: on macOS 26 it was indistinguishable from glass even with busy
    // text behind it (owner: «не вижу разницы между глас и фростед»). Old saved value maps to glass.
    case glass, clearGlass, solid
    var id: String { rawValue }

    var title: String {
        switch self {
        case .glass: String(localized: "Glass")
        case .clearGlass: String(localized: "Clear glass")
        case .solid: String(localized: "Solid")
        }
    }
}

/// Container that keeps a backdrop view (system glass / blur) behind the SwiftUI content and
/// swaps it when the setting changes. The window itself is transparent.
final class BackdropContainer: NSView {
    private let content: NSView
    private var backdrop: NSView?

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ style: WindowBackground) {
        backdrop?.removeFromSuperview()
        let view = WindowBackground.makeBackdrop(style, inWindow: false)
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .below, relativeTo: content)
        backdrop = view
    }
}

extension WindowBackground {
    /// One place that builds each backdrop, used by the window and by the Settings preview.
    /// `inWindow`: the preview blurs what is drawn inside its own window, not what is behind it.
    static func makeBackdrop(_ style: WindowBackground, inWindow: Bool) -> NSView {
        let view: NSView
        switch style {
        case .glass, .clearGlass:
            let g = NSGlassEffectView()
            g.style = style == .glass ? .regular : .clear
            g.cornerRadius = 0   // the window's own rounded shape clips it
            // Clear glass alone lets text behind the window fight with the notes; a light veil
            // in the window's own colour keeps it see-through but readable.
            if style == .clearGlass { g.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.45) }
            view = g
        case .solid:
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            view = v
        }
        return view
    }
}

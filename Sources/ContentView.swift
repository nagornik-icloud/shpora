import AppKit
import SwiftUI

/// The window: one or two panes, each a live file. Minimal chrome — a file name with a chevron,
/// two quiet icons, nothing else (owner: «удобно, красиво и минималистично»).
struct ContentView: View {
    let controller: WindowController
    @EnvironmentObject var model: AppModel
    @State private var edgeHover = false
    @State private var dragStartLeft: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            // The left pane never changes width or place while the second pane opens or closes:
            // it is an absolute width, and the right pane is drawn at its final width and simply
            // uncovered (or covered) by the moving window edge. Nothing re-lays out mid-animation.
            // `total`, not `total - 1`: at the first frame of opening the window is still exactly the
            // left pane wide, and the old clamp shrank the left pane by 1 pt for a moment — a line on
            // the edge of fitting un-wrapped and re-wrapped (measured 09.11.2026).
            // Settled (no open/close running): if the window is narrowed by its edge, the left pane
            // gives way so the right one never drops below the minimum.
            let settled = model.rightRevealWidth == nil
            let left = !model.splitVisible ? total
                : settled ? min(model.leftWidth, max(AppModel.minPane, total - 1 - AppModel.minPane))
                : min(model.leftWidth, max(total, 1))
            HStack(spacing: 0) {
                PaneView(side: .left)
                    .frame(width: left)
                if model.splitVisible {
                    divider(total: total)
                    PaneView(side: .right)
                        .frame(width: max(model.rightRevealWidth ?? 0, total - left - 1), alignment: .leading)
                        .opacity(model.rightOpacity)
                }
            }
            .frame(width: total, height: geo.size.height, alignment: .leading)
            .clipped()
        }
        // The toolbar rides the window edge; animating it separately left a ghost icon mid-way.
        .overlay(alignment: .topTrailing) { toolbar.transaction { $0.animation = nil }.opacity(model.toolbarHidden ? 0 : 1) }
        .overlay(alignment: .trailing) { if !model.splitVisible { addPaneEdge } }
        .ignoresSafeArea()
    }

    // MARK: Pieces

    private var toolbar: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "rectangle.split.2x1", selected: model.splitVisible,
                       help: model.splitVisible ? String(localized: "Close second pane  ⌘W") : String(localized: "Second pane  ⌘D")) {
                model.toggleSplit()
            }
            IconButton(symbol: "gearshape", help: String(localized: "Settings  ⌘,")) {
                AppDelegate.shared?.openSettings()
            }
        }
        .padding(.top, 9)
        .padding(.trailing, 10)
    }

    /// Thin strip on the right edge: shows a "+" on hover, opens the second pane on click.
    private var addPaneEdge: some View {
        ZStack {
            Color.clear.frame(width: 22)
            if edgeHover {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 44)
                    .background(.quaternary, in: Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.trailing, 4)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { edgeHover = h } }
        .onTapGesture { model.setSplit(true) }
        .help(String(localized: "Second pane  ⌘D"))
        // Hit area starts BELOW the header: the strip used to reach up over the gear icon.
        .padding(.top, 48)
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .padding(.vertical, 12)
            .overlay(
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        // Global coordinates: the divider moves with the drag, so measuring the
                        // finger relative to it fed its own movement back in — it jittered 60×/s.
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in
                                let start = dragStartLeft ?? model.leftWidth
                                if dragStartLeft == nil { dragStartLeft = start }
                                model.leftWidth = min(total - 1 - AppModel.minPane, max(AppModel.minPane, start + v.translation.width))
                            }
                            .onEnded { _ in dragStartLeft = nil }
                    )
            )
    }
}

/// One file: its name on top (click to switch), the editor below.
struct PaneView: View {
    let side: Side
    @EnvironmentObject var model: AppModel
    @State private var hover = false

    private var isActive: Bool { !model.splitVisible || model.activeSide == side }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let doc = model.document(for: side) {
                DocumentPane(document: doc, side: side)
                    // Scoped: only the dimming animates. The unscoped form also animated any width
                    // change of the editor made in the same update, so text re-wrapped mid-way.
                    .animation(.easeOut(duration: 0.2)) { $0.opacity(isActive ? 1 : 0.55) }
            } else {
                emptyState
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if side == .right {
                IconButton(symbol: "xmark", size: 10, help: String(localized: "Close pane  ⌘W")) { model.setSplit(false) }
                    .opacity(hover ? 1 : 0)
            }
            FileMenu(side: side)
                .opacity(isActive ? 1 : 0.5)
            if side == .right { Color.clear.frame(width: 22, height: 1) }   // keeps the title centred
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .padding(.horizontal, side == .left ? 76 : 70)   // clear of the window dots / toolbar icons
        .overlay(alignment: .bottom) {
            // Where typing goes must be obvious at a glance after coming back from the dialer.
            if model.splitVisible {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 36, height: 3)
                    .opacity(isActive ? 1 : 0)
                    .offset(y: -2)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isActive)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("Add a file to start capturing notes")
                .foregroundStyle(.secondary)
            HStack {
                Button(String(localized: "Add File…")) { model.pickFile(for: side) }
                Button(String(localized: "New File…")) { model.newFile(for: side) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Editor plus quiet status lines (file missing, conflict copy saved).
struct DocumentPane: View {
    @ObservedObject var document: TextDocument
    let side: Side

    var body: some View {
        EditorView(document: document, side: side)
            // Lines scrolling up fade out under the title instead of being cut in half.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                    Rectangle()
                }
            }
            .overlay(alignment: .bottom) {
                if let line = statusLine {
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .onTapGesture { document.notice = nil }
                }
            }
            .overlay(alignment: .topLeading) {
                // Quiet key hint in an empty file; gone with the first letter.
                if document.text.isEmpty {
                    Text("⌘T — new lead · ⌘F — search")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 27)
                        .padding(.top, 5)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.2), value: statusLine)
            .task(id: document.notice) {
                guard document.notice != nil else { return }
                try? await Task.sleep(for: .seconds(6))
                document.notice = nil
            }
    }

    private var statusLine: String? {
        if let n = document.notice { return n }
        if document.missing { return String(localized: "File not found — it will be created again as you type") }
        return nil
    }
}

struct FileMenu: View {
    let side: Side
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            ForEach(model.files, id: \.self) { url in
                // Toggle renders the system checkmark in a menu; a Label with an icon does not.
                Toggle(url.lastPathComponent, isOn: Binding(
                    get: { model.url(for: side) == url },
                    set: { _ in model.select(url, for: side) }))
            }
            if !model.files.isEmpty { Divider() }
            Button(String(localized: "Add File…")) { model.pickFile(for: side) }
            Button(String(localized: "New File…")) { model.newFile(for: side) }
        } label: {
            HStack(spacing: 4) {
                Text(model.url(for: side)?.lastPathComponent ?? String(localized: "No file"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // Not fixed horizontally: on a narrow pane the name shortens ("emp…d.md") instead of
        // running out over the window dots.
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct IconButton: View {
    let symbol: String
    var size: CGFloat = 14
    var selected = false
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(hover || selected ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .background(hover || selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

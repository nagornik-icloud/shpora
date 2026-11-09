import AppKit
import SwiftUI
import os

enum Side: String { case left, right }

/// App state: which files exist, what each pane shows, whether the second pane is open.
/// Persisted in UserDefaults so the window comes back exactly as it was.
@MainActor
final class AppModel: ObservableObject {
    private let log = Logger(subsystem: "ru.nagornik.shpora", category: "model")
    private let defaults = UserDefaults.standard

    @Published var files: [URL] = [] { didSet { saveFiles() } }
    @Published var leftURL: URL? { didSet { defaults.set(leftURL?.path, forKey: "leftPath") } }
    @Published var rightURL: URL? { didSet { defaults.set(rightURL?.path, forKey: "rightPath") } }
    @Published private(set) var splitOpen = false
    @Published var splitFraction: CGFloat = 0.5 { didSet { defaults.set(Double(splitFraction), forKey: "splitFraction") } }
    @Published var activeSide: Side = .left
    /// Drives the on-screen pane (animated); `splitOpen` is the persisted intent.
    @Published var splitVisible = false
    /// Width of the left pane in two-pane mode, in points. Absolute (not a fraction) so opening or
    /// closing the second pane never moves or resizes it.
    /// Narrowest a pane may get: below this the file name runs under the window dots / icons
    /// (owner saw it 09.11.2026). Holds for the divider, the window edge and saved widths.
    static let minPane: CGFloat = 280

    @Published var leftWidth: CGFloat = 520 { didSet { defaults.set(Double(leftWidth), forKey: "leftWidth") } }
    /// During open/close the right pane is drawn at this fixed width and revealed by the window edge.
    @Published var rightRevealWidth: CGFloat?
    @Published var rightOpacity: Double = 1
    @Published var toolbarHidden = false
    @Published var showInDock = false { didSet { defaults.set(showInDock, forKey: "showInDock"); onIconsChange?() } }
    @Published var showInMenuBar = true { didSet { defaults.set(showInMenuBar, forKey: "showInMenuBar"); onIconsChange?() } }
    @Published var autoCheckUpdates = true { didSet { defaults.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }
    var onIconsChange: (() -> Void)?
    @Published var background: WindowBackground = .glass {
        didSet { defaults.set(background.rawValue, forKey: "background"); onBackgroundChange?(background) }
    }
    var onBackgroundChange: ((WindowBackground) -> Void)?
    @Published var fontSize: CGFloat = 17 { didSet { defaults.set(Double(fontSize), forKey: "fontSize") } }

    func changeFont(by step: CGFloat) { fontSize = min(28, max(11, fontSize + step)) }

    private var documents: [URL: TextDocument] = [:]
    /// Live editors so keyboard commands can reach the focused text.
    private var editors: [Side: WeakTextView] = [:]

    /// Set by the window controller; animates the window when the split changes.
    var onSplitChange: ((Bool) -> Void)?

    init() {
        let paths = defaults.stringArray(forKey: "files") ?? []
        files = paths.map { URL(fileURLWithPath: $0) }
        if files.isEmpty { files = Self.importFromMarkie() }
        leftURL = defaults.string(forKey: "leftPath").map { URL(fileURLWithPath: $0) } ?? files.first
        rightURL = defaults.string(forKey: "rightPath").map { URL(fileURLWithPath: $0) }
        splitOpen = defaults.bool(forKey: "splitOpen")
        splitVisible = splitOpen
        showInDock = defaults.bool(forKey: "showInDock")
        showInMenuBar = defaults.object(forKey: "showInMenuBar") as? Bool ?? true
        autoCheckUpdates = defaults.object(forKey: "autoCheckUpdates") as? Bool ?? true
        let lw = defaults.double(forKey: "leftWidth")
        if lw > 0 { leftWidth = max(Self.minPane, CGFloat(lw)) }
        let fs = defaults.double(forKey: "fontSize")
        if fs >= 11 { fontSize = CGFloat(fs) }
        background = defaults.string(forKey: "background").flatMap(WindowBackground.init) ?? .glass
        let f = defaults.double(forKey: "splitFraction")
        splitFraction = f > 0.15 && f < 0.85 ? CGFloat(f) : 0.5
        // With two panes open the caret belongs to the answers side (TZ п.6).
        activeSide = splitOpen ? .right : .left
        // didSet does not run inside init: persist the Markie import explicitly.
        saveFiles()
        log.info("start files=\(self.files.count) split=\(self.splitOpen)")
    }

    func url(for side: Side) -> URL? { side == .left ? leftURL : rightURL }

    func document(for side: Side) -> TextDocument? {
        guard let url = url(for: side) else { return nil }
        return document(at: url)
    }

    func document(at url: URL) -> TextDocument {
        if let d = documents[url] { return d }
        let d = TextDocument(url: url)
        documents[url] = d
        return d
    }

    func select(_ url: URL, for side: Side) {
        if !files.contains(url) { files.append(url) }
        if side == .left { leftURL = url } else { rightURL = url }
        activeSide = side
        focusActive(after: 0.05)
    }

    func remove(_ url: URL) {
        document(at: url).flush()
        files.removeAll { $0 == url }
        if leftURL == url { leftURL = files.first }
        if rightURL == url { rightURL = nil }
    }

    func flushAll() {
        documents.values.forEach { $0.flush() }
    }

    // MARK: Split

    func setSplit(_ open: Bool) {
        guard open != splitOpen else { return }
        if open, rightURL == nil {
            rightURL = files.first(where: { $0 != leftURL })
        }
        splitOpen = open
        defaults.set(open, forKey: "splitOpen")
        activeSide = open ? .right : .left
        log.info("split \(open ? "open" : "closed")")
        onSplitChange?(open)
        focusActive(after: 0.4)
    }

    func toggleSplit() { setSplit(!splitOpen) }

    // MARK: Editors and commands

    func register(_ tv: NSTextView, side: Side) { editors[side] = WeakTextView(tv) }

    func focusActive(after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let side: Side = self.splitOpen ? self.activeSide : .left
            guard let tv = self.editors[side]?.view, let win = tv.window else { return }
            win.makeFirstResponder(tv)
        }
    }

    func focus(_ side: Side) {
        guard side == .left || splitOpen else { return }
        activeSide = side
        focusActive()
    }

    /// New-lead marker: "#### 09.11 06:45 · " with the caret left on that line, so the name or
    /// phone goes right after it and the lead can be found later by searching the name.
    func insertTimestamp() {
        let side: Side = splitOpen ? activeSide : .left
        guard let tv = editors[side]?.view else { return }
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm"
        let ns = tv.string as NSString
        let caret = tv.selectedRange().location
        let atLineStart = caret == 0 || ns.character(at: caret - 1) == 10
        let needsBlankLine = caret > 0 && !(caret >= 2 && ns.character(at: caret - 1) == 10 && ns.character(at: caret - 2) == 10)
        let lead = atLineStart ? (needsBlankLine && caret > 0 ? "\n" : "") : "\n\n"
        tv.insertText(lead + "#### \(f.string(from: Date())) · ", replacementRange: tv.selectedRange())
    }

    /// Types text into a pane as if from the keyboard (undoable, triggers autosave).
    func insert(_ s: String, side: Side) {
        guard let tv = editors[side]?.view else { return }
        tv.insertText(s, replacementRange: tv.selectedRange())
    }

    func openActiveInDefaultApp() {
        let side: Side = splitOpen ? activeSide : .left
        guard let url = url(for: side) else { return }
        document(at: url).flush()
        NSWorkspace.shared.open(url)
    }

    // MARK: Files

    func pickFile(for side: Side) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .init(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.level = .floating + 1
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { select(url, for: side) }
    }

    func newFile(for side: Side) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "notes.md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.level = .floating + 1
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        select(url, for: side)
    }

    private func saveFiles() {
        defaults.set(files.map(\.path), forKey: "files")
    }

    /// First run: take the file list from the original Markie so nothing has to be set up again.
    private static func importFromMarkie() -> [URL] {
        let markie = UserDefaults(suiteName: "com.asekachov.Markie")
        guard let json = markie?.data(forKey: "documentEntries") ?? markie?.string(forKey: "documentEntries")?.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return [] }
        var urls: [URL] = []
        for e in entries {
            guard let b64 = e["bookmarkData"] as? String, let data = Data(base64Encoded: b64) else { continue }
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], bookmarkDataIsStale: &stale) {
                urls.append(url)
            }
        }
        Logger(subsystem: "ru.nagornik.shpora", category: "model").info("imported from Markie: \(urls.count)")
        return urls
    }
}

final class WeakTextView {
    weak var view: NSTextView?
    init(_ v: NSTextView) { view = v }
}

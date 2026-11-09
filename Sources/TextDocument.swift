import Foundation
import os

/// One markdown/text file on disk, edited live.
///
/// Why this shape: the window *is* the file (owner's choice 09.11.2026 «Живой файл»), so every
/// keystroke must reach disk quickly and survive a crash, and edits made in another editor
/// (One Markdown, Obsidian) must show up here without either side silently overwriting the other.
@MainActor
final class TextDocument: ObservableObject {
    let url: URL
    private let log = Logger(subsystem: "ru.nagornik.shpora", category: "document")

    /// Current text as the user sees it (always "\n" line endings).
    private(set) var text: String = ""
    /// Bumped whenever `text` changes; views compare it to know they must refresh.
    @Published private(set) var revision = 0
    /// Which editor caused the last change, so it does not reload its own keystrokes.
    private(set) var lastEditor: ObjectIdentifier?
    @Published private(set) var missing = false
    @Published var notice: String?

    // Encoding facts are decided once, on the first good read, and never flip afterwards:
    // a half-written file read mid-write must not turn the document into cp1251 garbage.
    private var encoding: String.Encoding?
    private var hadBOM = false
    private var usesCRLF = false
    /// Exact bytes we last read or wrote; equal bytes on disk mean "nothing new from outside".
    private var lastDiskData: Data?
    /// File exists but could not be read (permissions prompt, mid-write): never write over it.
    private var unreadable = false

    private var pendingSave: DispatchWorkItem?
    private var firstUnsavedAt: Date?
    private var watcher: DispatchSourceFileSystemObject?
    private var eventDebounce: DispatchWorkItem?

    static let saveDelay: TimeInterval = 0.3
    /// Even while typing non-stop, nothing older than this stays only in memory.
    static let maxUnsavedAge: TimeInterval = 1.0

    init(url: URL) {
        self.url = url
        loadFromDisk()
        startWatching()
    }

    var hasUnsavedChanges: Bool { firstUnsavedAt != nil }

    // MARK: Editing

    func userEdited(_ newText: String, by editor: ObjectIdentifier) {
        guard newText != text else { return }
        text = newText
        lastEditor = editor
        revision += 1
        if firstUnsavedAt == nil { firstUnsavedAt = Date() }
        scheduleSave()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let age = Date().timeIntervalSince(firstUnsavedAt ?? Date())
        let delay = max(0, min(Self.saveDelay, Self.maxUnsavedAge - age))
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Writes immediately if anything is pending. Called on hide, quit and sleep.
    func flush() {
        guard hasUnsavedChanges else { return }
        saveNow()
    }

    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard hasUnsavedChanges else { return }

        // Someone else may have changed the file since we last saw it (event not delivered yet,
        // file re-created). Never write blind over that: route through the conflict path.
        let exists = FileManager.default.fileExists(atPath: url.path)
        let disk = try? Data(contentsOf: url)
        if exists, disk == nil {
            unreadable = true
            log.error("refuse to save over unreadable file \(self.url.path, privacy: .public)")
            notice = String(localized: "Can't read \(url.lastPathComponent) — not saving over it")
            scheduleRetry()
            return
        }
        if let disk, disk != lastDiskData, !(lastDiskData == nil && disk.isEmpty) {
            keepLocalCopyAndLoad(disk)
            return
        }

        let data = encode(text)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Atomic write: a crash mid-write leaves the old file, never a half file.
            try data.write(to: url, options: .atomic)
            lastDiskData = data
            firstUnsavedAt = nil
            missing = false
            unreadable = false
            log.debug("saved \(self.url.lastPathComponent, privacy: .public) bytes=\(data.count)")
            startWatching()   // atomic write swapped the inode; the old watch would go deaf
        } catch {
            log.error("save failed \(self.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            notice = String(localized: "Could not save: \(error.localizedDescription)")
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.hasUnsavedChanges else { return }
            if self.unreadable { self.loadFromDisk() }
            self.saveNow()
        }
    }

    // MARK: Disk → editor

    private func loadFromDisk() {
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard let data = try? Data(contentsOf: url) else {
            missing = !exists
            unreadable = exists
            if unreadable { log.error("cannot read \(self.url.path, privacy: .public)") }
            return
        }
        missing = false
        unreadable = false
        if data == lastDiskData { return }
        guard let decoded = decode(data) else {
            // Most likely caught another app mid-write; look again shortly, keep what we show.
            log.notice("undecodable read, retrying \(self.url.lastPathComponent, privacy: .public)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.handleExternalChange() }
            return
        }
        lastDiskData = data
        if decoded != text {
            text = decoded
            lastEditor = nil
            revision += 1
        }
    }

    private func handleExternalChange() {
        let disk = try? Data(contentsOf: url)
        if let disk, disk == lastDiskData { return }   // our own write echoing back
        guard let disk else {
            if FileManager.default.fileExists(atPath: url.path) {
                unreadable = true
            } else if !missing {
                // Moved/deleted: keep the text in memory; the next save re-creates the file.
                missing = true
                log.notice("file disappeared \(self.url.path, privacy: .public)")
            }
            return
        }
        if hasUnsavedChanges {
            keepLocalCopyAndLoad(disk)
        } else {
            loadFromDisk()
        }
    }

    /// Both sides changed at once: theirs stays in the file, ours goes to a copy next to it.
    private func keepLocalCopyAndLoad(_ disk: Data) {
        guard decode(disk) != nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.handleExternalChange() }
            return
        }
        let copy = conflictCopyURL()
        do {
            try encode(text).write(to: copy, options: .atomic)
            notice = String(localized: "Changed in another app — your version saved as \(copy.lastPathComponent)")
            log.notice("conflict, local copy at \(copy.path, privacy: .public)")
        } catch {
            log.error("conflict copy failed: \(error.localizedDescription, privacy: .public)")
        }
        pendingSave?.cancel()
        pendingSave = nil
        firstUnsavedAt = nil
        loadFromDisk()
    }

    private func conflictCopyURL() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "md" : url.pathExtension
        return url.deletingLastPathComponent().appendingPathComponent("\(base) (Shpora \(f.string(from: Date()))).\(ext)")
    }

    // MARK: Watching

    private func startWatching() {
        watcher?.cancel()
        watcher = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // Not there yet; look again shortly so we notice when it appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.watcher == nil else { return }
                self.startWatching()
            }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let replaced = src.data.contains(.delete) || src.data.contains(.rename)
                // Coalesce bursts of events from one save into a single read.
                self.eventDebounce?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if replaced { self.startWatching() } else { self.handleExternalChange() }
                    }
                }
                self.eventDebounce = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
        // The file may have been replaced between the old watch dying and this one starting.
        handleExternalChange()
    }

    // MARK: Encoding

    private func decode(_ data: Data) -> String? {
        var bytes = data
        let bom = bytes.starts(with: [0xEF, 0xBB, 0xBF])
        if bom { bytes = bytes.dropFirst(3) }
        let s: String
        if let enc = encoding {
            guard let d = String(data: bytes, encoding: enc) else { return nil }
            s = d
        } else if let u = String(data: bytes, encoding: .utf8) {
            encoding = .utf8; hadBOM = bom; s = u
        } else if let w = String(data: bytes, encoding: .windowsCP1251) {
            encoding = .windowsCP1251; s = w
        } else {
            return nil
        }
        if lastDiskData == nil { usesCRLF = s.contains("\r\n") }
        return s.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func encode(_ s: String) -> Data {
        let out = usesCRLF ? s.replacingOccurrences(of: "\n", with: "\r\n") : s
        let enc = encoding ?? .utf8
        var data = out.data(using: enc, allowLossyConversion: false) ?? Data(out.utf8)
        if hadBOM { data = Data([0xEF, 0xBB, 0xBF]) + data }
        return data
    }
}

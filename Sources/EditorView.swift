import AppKit
import SwiftUI

/// Plain-text editor bound to a live document.
///
/// NSTextView instead of SwiftUI TextEditor on purpose: the original app's bug "text box doesn't
/// scroll with the caret" is the TextEditor family's weak spot; NSTextView keeps the caret visible
/// on every keystroke and Enter by itself.
struct EditorView: NSViewRepresentable {
    @ObservedObject var document: TextDocument
    let side: Side
    @EnvironmentObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        // A little air under the last line so the caret never sits on the window edge.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 14, right: 0)

        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        // Names, cities, «400k» typed blind during a call must not be "corrected" silently.
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.textContainerInset = NSSize(width: 18, height: 4)
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.15
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: model.fontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ]
        tv.font = .systemFont(ofSize: model.fontSize)
        tv.textColor = .labelColor
        tv.defaultParagraphStyle = para
        tv.typingAttributes = attrs
        tv.insertionPointColor = .controlAccentColor
        context.coordinator.attrs = attrs
        context.coordinator.textView = tv
        tv.string = document.text
        tv.textStorage?.setAttributes(attrs, range: NSRange(location: 0, length: (tv.string as NSString).length))
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        context.coordinator.shownRevision = document.revision
        model.register(tv, side: side)
        DispatchQueue.main.async { tv.scrollRangeToVisible(tv.selectedRange()) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView else { return }
        model.register(tv, side: side)
        applyFontIfChanged(tv, c)
        if c.document !== document {
            // Pane switched to another file: show it with the caret at the end, where notes grow.
            c.document = document
            tv.string = document.text
            tv.textStorage?.setAttributes(c.attrs, range: NSRange(location: 0, length: (tv.string as NSString).length))
            tv.undoManager?.removeAllActions(withTarget: tv.textStorage as Any)
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            tv.scrollRangeToVisible(tv.selectedRange())
            c.shownRevision = document.revision
            return
        }
        // Refresh only for changes that did not come from this very editor.
        if document.revision != c.shownRevision {
            c.shownRevision = document.revision
            if document.lastEditor != ObjectIdentifier(tv), tv.string != document.text {
                c.applyDiff(to: document.text)
            }
        }
    }

    /// ⌘+ / ⌘− changes the size for every pane; restyle the whole text once when it changes.
    private func applyFontIfChanged(_ tv: NSTextView, _ c: Coordinator) {
        let size = model.fontSize
        guard (c.attrs[.font] as? NSFont)?.pointSize != size else { return }
        c.attrs[.font] = NSFont.systemFont(ofSize: size)
        tv.font = .systemFont(ofSize: size)
        tv.typingAttributes = c.attrs
        tv.textStorage?.addAttribute(.font, value: NSFont.systemFont(ofSize: size), range: NSRange(location: 0, length: (tv.string as NSString).length))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditorView
        var document: TextDocument
        weak var textView: NSTextView?
        var shownRevision = 0
        var attrs: [NSAttributedString.Key: Any] = [:]

        init(_ parent: EditorView) {
            self.parent = parent
            self.document = parent.document
        }

        /// Replace only the changed middle part, so the caret, scroll position and undo survive
        /// an edit made in another app or in the other pane.
        func applyDiff(to new: String) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let old = tv.string as NSString
            let newNS = new as NSString
            var prefix = 0
            let minLen = min(old.length, newNS.length)
            while prefix < minLen, old.character(at: prefix) == newNS.character(at: prefix) { prefix += 1 }
            var suffix = 0
            while suffix < minLen - prefix,
                  old.character(at: old.length - 1 - suffix) == newNS.character(at: newNS.length - 1 - suffix) { suffix += 1 }
            let oldRange = NSRange(location: prefix, length: old.length - prefix - suffix)
            let insert = newNS.substring(with: NSRange(location: prefix, length: newNS.length - prefix - suffix))
            var sel = tv.selectedRange()
            let delta = (insert as NSString).length - oldRange.length
            if sel.location >= NSMaxRange(oldRange) { sel.location += delta }
            else if sel.location > oldRange.location { sel.location = oldRange.location + (insert as NSString).length }
            sel.length = 0
            storage.beginEditing()
            storage.replaceCharacters(in: oldRange, with: NSAttributedString(string: insert, attributes: attrs))
            storage.endEditing()
            tv.setSelectedRange(NSRange(location: min(sel.location, (tv.string as NSString).length), length: 0))
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            MainActor.assumeIsolated {
                document.userEdited(tv.string, by: ObjectIdentifier(tv))
                shownRevision = document.revision
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView, tv.window?.firstResponder === tv else { return }
            MainActor.assumeIsolated {
                if parent.model.activeSide != parent.side { parent.model.activeSide = parent.side }
            }
        }
    }
}

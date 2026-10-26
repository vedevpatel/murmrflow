import AppKit

/// Inserts text into the focused app by pasting, then restores the previous clipboard.
enum TextInserter {
    private typealias Saved = [[(NSPasteboard.PasteboardType, Data)]]
    // Back-to-back inserts must not mistake our own pasted text for the user's clipboard.
    private static var savedClipboard: Saved?
    private static var restore: DispatchWorkItem?

    /// Returns false when Accessibility is missing; the text is then left on the clipboard so it can be pasted by hand.
    /// `rich` adds HTML and RTF versions next to the plain text; the target app picks the one it understands.
    @discardableResult
    static func insert(_ text: String, rich: (html: String, rtf: Data)? = nil) -> Bool {
        let pb = NSPasteboard.general
        guard AXIsProcessTrusted() else {
            write(text, rich: rich, to: pb)
            return false
        }
        restore?.cancel()
        let saved: Saved = savedClipboard ?? (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        savedClipboard = saved

        write(text, rich: rich, to: pb)
        pressCommandV()

        // Give the target app time to read the pasteboard before putting the old contents back.
        let work = DispatchWorkItem {
            pb.clearContents()
            for entry in saved {
                let item = NSPasteboardItem()
                for (type, data) in entry { item.setData(data, forType: type) }
                pb.writeObjects([item])
            }
            savedClipboard = nil
        }
        restore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        return true
    }

    private static func write(_ text: String, rich: (html: String, rtf: Data)?, to pb: NSPasteboard) {
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if let rich {
            item.setString(rich.html, forType: .html)
            item.setData(rich.rtf, forType: .rtf)
        }
        pb.writeObjects([item])
    }

    private static func pressCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }
}

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
        let saved = savedClipboard ?? snapshot(pb)
        savedClipboard = saved

        write(text, rich: rich, to: pb)
        press(key: 9)  // V

        // Give the target app time to read the pasteboard before putting the old contents back.
        let work = DispatchWorkItem {
            put(saved, on: pb)
            savedClipboard = nil
        }
        restore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        return true
    }

    /// The frontmost app's selection, copied with ⌘C, with the clipboard put back afterwards. For apps that do
    /// not expose their selection through Accessibility. Nil when nothing was copied.
    @MainActor
    static func copySelection() async -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let pb = NSPasteboard.general
        // A paste still waiting to restore the clipboard would otherwise be saved as the user's contents.
        if let pending = restore, !pending.isCancelled, savedClipboard != nil {
            pending.perform()
            pending.cancel()
        }
        let saved = snapshot(pb)
        let count = pb.changeCount
        press(key: 8)  // C
        try? await Task.sleep(nanoseconds: 250_000_000)
        let copied = pb.changeCount != count ? pb.string(forType: .string) : nil
        put(saved, on: pb)
        return copied?.isEmpty == false ? copied : nil
    }

    private static func snapshot(_ pb: NSPasteboard) -> Saved {
        (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func put(_ saved: Saved, on pb: NSPasteboard) {
        pb.clearContents()
        for entry in saved {
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            pb.writeObjects([item])
        }
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

    /// ⌘ plus the key. Only Command is set on the event, even while the user holds the dictation hotkey.
    private static func press(key: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }
}

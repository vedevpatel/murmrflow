import AppKit

/// Inserts text into the focused app by pasting, then restores the previous clipboard.
enum TextInserter {
    private typealias Saved = [[(NSPasteboard.PasteboardType, Data)]]
    // Back-to-back inserts must not mistake our own pasted text for the user's clipboard.
    private static var savedClipboard: Saved?
    private static var restore: DispatchWorkItem?

    /// Returns false when Accessibility is missing; the text is then left on the clipboard so it can be pasted by hand.
    @discardableResult
    static func insert(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        guard AXIsProcessTrusted() else {
            pb.clearContents()
            pb.setString(text, forType: .string)
            return false
        }
        restore?.cancel()
        let saved: Saved = savedClipboard ?? (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        savedClipboard = saved

        pb.clearContents()
        pb.setString(text, forType: .string)
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

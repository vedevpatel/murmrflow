import AppKit

/// A click-through floating caption that shows the words being recognised while the hotkey is held.
final class CaptionOverlay {
    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private let width: CGFloat = 560
    private let inset: CGFloat = 14
    /// Shown in front of the caption, e.g. "Command" while an instruction is being spoken.
    var title: String?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        panel.contentView = blur

        label.font = .systemFont(ofSize: 17, weight: .medium)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byTruncatingHead
        label.preferredMaxLayoutWidth = width - inset * 2
        blur.addSubview(label)
    }

    func update(_ text: String) {
        let caption = text.isEmpty ? "Listening…" : text
        label.stringValue = title.map { "\($0) · \(caption)" } ?? caption
        let size = label.sizeThatFits(NSSize(width: width - inset * 2, height: .greatestFiniteMagnitude))
        let height = size.height + inset * 2
        label.frame = NSRect(x: inset, y: inset, width: width - inset * 2, height: size.height)

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: screen.midX - width / 2, y: screen.minY + 80, width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

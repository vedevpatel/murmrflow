import AppKit
import ApplicationServices

/// Push-to-talk on the Right Option key, observed through a listen-only event tap.
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private static let rightOptionKeyCode: Int64 = 61
    private var tap: CFMachPort?
    private var held = false

    /// Returns false while the Input Monitoring / Accessibility permission is missing.
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        // Without Input Monitoring the tap can still be created but only sees events while this app is frontmost,
        // so treat a missing grant as "not started" and ask for it.
        guard CGPreflightListenEventAccess() else {
            CGRequestListenEventAccess()
            return false
        }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == Self.rightOptionKeyCode else { return }
        let down = event.flags.contains(.maskAlternate)
        if down && !held {
            held = true
            DispatchQueue.main.async { self.onPress?() }
        } else if !down && held {
            held = false
            DispatchQueue.main.async { self.onRelease?() }
        }
    }
}

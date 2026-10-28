import AppKit
import ApplicationServices

/// Push-to-talk on the Right Option key, observed through a listen-only event tap.
/// Holding Shift as well asks for Command Mode.
final class HotkeyMonitor {
    /// Whether Shift was down when Right Option was pressed.
    var onPress: ((_ withShift: Bool) -> Void)?
    var onRelease: (() -> Void)?
    /// Shift pressed while Right Option is held.
    var onShift: (() -> Void)?
    /// Any key typed by the user, without saying which; Murmrflow's own simulated paste is left out.
    var onKeyDown: (() -> Void)?

    private static let rightOptionKeyCode: Int64 = 61
    private static let shiftKeyCodes: Set<Int64> = [56, 60]
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
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue | 1 << CGEventType.keyDown.rawValue)
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
        if type == .keyDown {
            // The tap runs on the main run loop, so this is already the main thread.
            if event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) { onKeyDown?() }
            return
        }
        guard type == .flagsChanged else { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if Self.shiftKeyCodes.contains(code) {
            if held, event.flags.contains(.maskShift) { DispatchQueue.main.async { self.onShift?() } }
            return
        }
        guard code == Self.rightOptionKeyCode else { return }
        let down = event.flags.contains(.maskAlternate)
        if down && !held {
            held = true
            let shift = event.flags.contains(.maskShift)
            DispatchQueue.main.async { self.onPress?(shift) }
        } else if !down && held {
            held = false
            DispatchQueue.main.async { self.onRelease?() }
        }
    }
}

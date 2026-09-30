import AppKit
import CoreGraphics

/// Watches the Fn/Globe key system-wide with a CGEvent tap (requires Accessibility access).
@MainActor
final class HotkeyMonitor {
    enum Event {
        case fnDown
        case fnUp
        /// Another key was pressed while Fn was held (an Fn shortcut like Fn+Delete, not dictation).
        case keyWhileFnHeld
        case escape
    }

    /// Return true to swallow the event (only honored for Escape).
    var handler: ((Event) -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var fnIsDown = false

    var isRunning: Bool { tap != nil }

    /// Returns false if the tap couldn't be created (Accessibility not granted yet).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: hotkeyTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        fnIsDown = false
    }

    /// Returns true to swallow the event.
    fileprivate func handle(type: CGEventType, flags: CGEventFlags, keyCode: Int64) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false

        case .flagsChanged:
            let fn = flags.contains(.maskSecondaryFn)
            guard fn != fnIsDown else { return false }
            fnIsDown = fn
            if fn {
                // Fn combined with other modifiers is some other shortcut.
                let others: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
                guard flags.intersection(others).isEmpty else { return false }
                _ = handler?(.fnDown)
            } else {
                _ = handler?(.fnUp)
            }
            return false

        case .keyDown:
            if keyCode == 53 {  // kVK_Escape
                return handler?(.escape) ?? false
            }
            if fnIsDown {
                _ = handler?(.keyWhileFnHeld)
            }
            return false

        default:
            return false
        }
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let flags = event.flags
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    // The tap's run loop source is on the main run loop.
    let swallow = MainActor.assumeIsolated { monitor.handle(type: type, flags: flags, keyCode: keyCode) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

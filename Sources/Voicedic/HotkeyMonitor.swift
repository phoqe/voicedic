import AppKit
import CoreGraphics

/// Watches the dictation shortcut and Esc system-wide with a CGEvent tap (requires Accessibility access).
@MainActor
final class HotkeyMonitor {
    enum Event {
        /// `time` is when the shortcut was pressed or released, in seconds since startup. Use it for
        /// timing gestures: events can be handled late if the main thread was busy.
        case shortcutDown(time: TimeInterval)
        case shortcutUp(time: TimeInterval)
        /// Another key was pressed while the shortcut was held (an Fn shortcut like Fn+Delete, not
        /// dictation).
        case keyWhileHeld
        case escape
    }

    /// Return true to swallow the event (only honored for Escape).
    var handler: ((Event) -> Bool)?

    var shortcut = Shortcut.fn {
        didSet { isDown = false }
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Modifier keys held, as of the last modifier change.
    private var held: Set<ModifierKey> = []
    private var isDown = false

    var isRunning: Bool { tap != nil }

    /// Returns false if the tap couldn't be created (Accessibility not granted yet).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(0) { $0 | (1 << $1.rawValue) }
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
        held = []
        isDown = false
    }

    /// Returns true to swallow the event.
    fileprivate func handle(
        type: CGEventType, flags: CGEventFlags, keyCode: Int64, isRepeat: Bool, time: TimeInterval
    ) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false

        case .flagsChanged:
            let previous = held
            held = ModifierKey.held(inFlags: flags.rawValue)
            guard shortcut.keyCode == nil else { return false }
            if !isDown {
                // Only pressing the last of the keys counts. Letting go of an extra one (⌘ after
                // ⌘-fn) doesn't.
                guard shortcut.matches(held), previous.isStrictSubset(of: held) else { return false }
                isDown = true
                _ = handler?(.shortcutDown(time: time))
            } else if !shortcut.isHeld(in: held) {
                isDown = false
                _ = handler?(.shortcutUp(time: time))
            }
            return false

        case .keyDown:
            if let key = shortcut.keyCode, keyCode == Int64(key) {
                // The shortcut's own key never types, including its auto-repeats.
                if isDown { return true }
                // Key events set fn for arrows and function keys too, so use whether fn is really held.
                var modifiers = ModifierKey.held(inFlags: flags.rawValue)
                modifiers.remove(.fn)
                if held.contains(.fn) { modifiers.insert(.fn) }
                if !isRepeat, shortcut.matches(modifiers) {
                    isDown = true
                    _ = handler?(.shortcutDown(time: time))
                    return true
                }
            }
            if keyCode == Int64(Shortcut.escapeKeyCode) {
                return handler?(.escape) ?? false
            }
            if isDown {
                _ = handler?(.keyWhileHeld)
            }
            return false

        case .keyUp:
            guard isDown, let key = shortcut.keyCode, keyCode == Int64(key) else { return false }
            isDown = false
            _ = handler?(.shortcutUp(time: time))
            return true

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
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    // NSEvent converts the raw timestamp to seconds since startup.
    let isKey = type == .flagsChanged || type == .keyDown || type == .keyUp
    let time = (isKey ? NSEvent(cgEvent: event)?.timestamp : nil) ?? ProcessInfo.processInfo.systemUptime
    // The tap's run loop source is on the main run loop.
    let swallow = MainActor.assumeIsolated {
        monitor.handle(type: type, flags: flags, keyCode: keyCode, isRepeat: isRepeat, time: time)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

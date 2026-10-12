import AppKit

/// Right-⌥ push-to-talk:
/// - hold to record, release to finish
/// - double-tap to lock hands-free; tap again to stop
/// - Right-⌥ combined with another key is treated as a shortcut and cancels
/// - Esc cancels
@MainActor
final class HotkeyMonitor {
    enum Event { case start, stop, lock, cancel, escape }

    var handler: ((Event) -> Void)?
    /// Whether the controller is currently in a locked (hands-free) recording.
    var isLocked: () -> Bool = { false }

    private static let rightOptionKeyCode: UInt16 = 61
    private static let rightOptionDeviceMask: UInt = 0x40  // NX_DEVICERALTKEYMASK
    private static let escapeKeyCode: UInt16 = 53
    private static let tapThreshold: TimeInterval = 0.25
    private static let doubleTapWindow: TimeInterval = 0.3

    private var monitors: [Any] = []
    private var isDown = false
    private var downAt: TimeInterval = 0
    private var comboUsed = false
    private var pendingTap: DispatchWorkItem?
    private var ignoreNextUp = false

    func install() {
        uninstall()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.process(e) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.process(e) }
            return e
        }) {
            monitors.append(local)
        }
    }

    func uninstall() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func process(_ e: NSEvent) {
        switch e.type {
        case .keyDown:
            if e.keyCode == Self.escapeKeyCode {
                handler?(.escape)
            } else if isDown {
                comboUsed = true
                if !isLocked() { handler?(.cancel) }
            }
        case .flagsChanged:
            let rightDown = e.modifierFlags.rawValue & Self.rightOptionDeviceMask != 0
            if e.keyCode == Self.rightOptionKeyCode {
                if rightDown && !isDown { pressed(e) } else if !rightDown && isDown { released() }
            } else if isDown {
                // Another modifier changed while Right-⌥ is held: it's a shortcut.
                comboUsed = true
                if !isLocked() { handler?(.cancel) }
            }
        default:
            break
        }
    }

    private func pressed(_ e: NSEvent) {
        isDown = true
        comboUsed = false
        downAt = e.timestamp
        let others = e.modifierFlags.intersection([.command, .control, .shift])
        if !others.isEmpty {
            comboUsed = true
            return
        }
        if isLocked() {
            ignoreNextUp = true
            handler?(.stop)
            return
        }
        if let pending = pendingTap {
            // Second press inside the double-tap window: lock.
            pending.cancel()
            pendingTap = nil
            ignoreNextUp = true
            handler?(.lock)
            return
        }
        handler?(.start)
    }

    private func released() {
        isDown = false
        if ignoreNextUp {
            ignoreNextUp = false
            return
        }
        if comboUsed { return }
        let held = ProcessInfo.processInfo.systemUptime - downAt
        if held < Self.tapThreshold {
            // Quick tap: wait briefly for a second tap before discarding.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingTap = nil
                self.handler?(.cancel)
            }
            pendingTap = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleTapWindow, execute: work)
        } else {
            handler?(.stop)
        }
    }
}

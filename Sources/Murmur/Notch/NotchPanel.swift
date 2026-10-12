import AppKit
import SwiftUI

/// Borderless, non-activating panel pinned to the bottom-right screen corner. It never takes
/// keyboard focus, so the app you're dictating into keeps its cursor.
final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Positions the panel, tracks hover over the corner notch, and toggles click-through.
@MainActor
final class NotchWindowController {
    private let panel = NotchPanel()
    private let controller: AppController
    private var monitors: [Any] = []
    private var lastMode: NotchMode = .hidden
    private static let panelSize = CGSize(width: 600, height: 380)

    init(controller: AppController) {
        self.controller = controller
        let hosting = FirstMouseHostingView(rootView: NotchView(controller: controller))
        hosting.sizingOptions = []
        panel.contentView = hosting
        reposition()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        installMouseTracking()
        observe()
    }

    /// The primary display (the one with the menu bar).
    private var screen: NSScreen? { NSScreen.screens.first }

    func reposition() {
        guard let frame = screen?.frame else { return }
        let size = Self.panelSize
        panel.setFrame(
            NSRect(x: frame.maxX - size.width, y: frame.minY, width: size.width, height: size.height),
            display: true)
    }

    // MARK: - Hover & click-through

    private func installMouseTracking() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.updateHover() }
            return e
        }) {
            monitors.append(l)
        }
    }

    private func updateHover() {
        guard let frame = screen?.frame else { return }
        let s = NotchLayout.size(controller)
        let margin: CGFloat = 10
        let zone = NSRect(x: frame.maxX - s.width - margin, y: frame.minY, width: s.width + margin, height: s.height + margin)
        let inside = NotchLayout.mode(controller) != .hidden && zone.contains(NSEvent.mouseLocation)
        if controller.hovering != inside { controller.hovering = inside }
        applyClickThrough()
    }

    /// Accept clicks only while the pointer is over the expanded notch so nothing underneath is blocked.
    private func applyClickThrough() {
        let interactive = controller.hovering && NotchLayout.mode(controller) != .hidden
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
    }

    private func observe() {
        withObservationTracking {
            _ = NotchLayout.mode(controller)
            _ = controller.hovering
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.modeChanged()
                self?.updateHover()
                self?.observe()
            }
        }
    }

    /// Swoosh when the notch grows out of the corner, collapse sound when it tucks back in.
    private func modeChanged() {
        let mode = NotchLayout.mode(controller)
        defer { lastMode = mode }
        guard controller.sounds, mode != lastMode else { return }
        if lastMode == .hidden {
            SoundFX.open()
        } else if mode == .hidden {
            SoundFX.close()
        }
    }
}

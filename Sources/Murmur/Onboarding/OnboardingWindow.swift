import AppKit
import SwiftUI

/// Hosts the first-run guide and the Settings window. Murmur is a menu bar app, so these are
/// the only windows it ever shows.
@MainActor
final class Windows: NSObject, NSWindowDelegate {
    private let controller: AppController
    private var onboarding: NSWindow?
    private var settings: NSWindow?

    init(controller: AppController) {
        self.controller = controller
    }

    static var isOnboarded: Bool {
        get { UserDefaults.standard.bool(forKey: "onboarded") }
        set { UserDefaults.standard.set(newValue, forKey: "onboarded") }
    }

    func showOnboarding() {
        if let onboarding {
            present(onboarding)
            return
        }
        let view = OnboardingView(controller: controller) { [weak self] in
            Self.isOnboarded = true
            self?.onboarding?.close()
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: OnboardingView.size),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "Welcome to Murmur"
        window.contentView = NSHostingView(rootView: view)
        window.delegate = self
        window.center()
        onboarding = window
        present(window)
    }

    func showSettings() {
        if let settings {
            present(settings)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Murmur Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(controller: controller, windows: self))
        window.delegate = self
        window.center()
        settings = window
        present(window)
    }

    private func present(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window == onboarding {
            onboarding = nil
            controller.captureDelivery = nil
            controller.stopMicPreview()
            // Closed early: still get dictation working with the recommended model.
            if !controller.modelReady && !controller.isLoadingModel {
                controller.selectModel(SpeechModel.selected ?? DeviceProfile.current.recommended)
            }
        } else if window == settings {
            settings = nil
        }
    }
}

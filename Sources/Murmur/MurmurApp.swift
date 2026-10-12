import AppKit
import FluidAudio
import ServiceManagement

@main
enum Main {
    nonisolated(unsafe) static var delegate: AppDelegate?

    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
            let path = args[i + 1]
            let model = args.firstIndex(of: "--model").flatMap { j in
                j + 1 < args.count ? SpeechModel(rawValue: args[j + 1]) : nil
            }
            Task {
                await CLI.transcribe(path: path, model: model ?? .unified)
                exit(0)
            }
            dispatchMain()
        }
        #if MURMUR_DEBUG_HOOKS
        if let i = args.firstIndex(of: "--render-ui"), i + 1 < args.count {
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.accessory)
                Render.run(to: URL(fileURLWithPath: args[i + 1]))
            }
            exit(0)
        }
        #endif
        if let i = args.firstIndex(of: "--export-sounds"), i + 1 < args.count {
            MainActor.assumeIsolated { SoundFX.export(to: URL(fileURLWithPath: args[i + 1])) }
            exit(0)
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            Main.delegate = delegate
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = AppController()
    private lazy var windows = Windows(controller: controller)
    private var notch: NotchWindowController?
    private var statusItem: NSStatusItem!

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Murmur")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        notch = NotchWindowController(controller: controller)
        _ = Updater.shared
        let firstRun = !Windows.isOnboarded
        controller.bootstrap(firstRun: firstRun)
        if firstRun { windows.showOnboarding() }
        observeUpdates()
    }

    /// Opening Murmur again while it's running (Finder, Spotlight) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Windows.isOnboarded ? windows.showSettings() : windows.showOnboarding() }
        return true
    }

    /// A dot on the menu bar icon while a background update check has found something.
    private func observeUpdates() {
        withObservationTracking {
            let pending = Updater.shared.pendingVersion != nil
            statusItem.button?.image = NSImage(
                systemSymbolName: pending ? "waveform.badge.exclamationmark" : "waveform",
                accessibilityDescription: pending ? "Murmur — update available" : "Murmur")
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeUpdates() }
        }
    }

    /// Development hooks, compiled only into local builds (`scripts/build.sh`). Release builds
    /// ignore `murmur://` URLs entirely, so nothing outside the app can make it record or read files.
    /// - `open -g "murmur://simulate?path=/abs/file.wav"` runs a file through the full pipeline as if spoken
    /// - `open -g "murmur://preview?state=result"` shows a canned notch state
    /// - `open -g "murmur://mictest?seconds=3"` records, transcribes, and logs (no UI, no paste)
    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        #if MURMUR_DEBUG_HOOKS
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let comps = URLComponents(string: s)
        else { return }
        let query = { (name: String) in comps.queryItems?.first(where: { $0.name == name })?.value }
        switch comps.host {
        case "simulate": if let path = query("path") { controller.simulate(file: URL(fileURLWithPath: path)) }
        case "preview": controller.preview(query("state") ?? "idle")
        case "mictest": controller.micTest(seconds: Double(query("seconds") ?? "") ?? 3)
        case "onboarding": windows.showOnboarding()
        default: break
        }
        #endif
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let version = Updater.shared.pendingVersion {
            menu.addItem(item("Update to Murmur \(version)…", #selector(checkForUpdates)))
            menu.addItem(.separator())
        }

        let status: String
        switch controller.phase {
        case .loading(_, let message): status = message
        case .recording: status = "Listening…"
        case .transcribing: status = "Transcribing…"
        default:
            if controller.modelError != nil {
                status = "Model failed to load"
            } else if !controller.modelReady {
                status = Windows.isOnboarded ? "Starting…" : "Finish setup to start dictating"
            } else {
                status = "Ready — hold right ⌥ to dictate"
            }
        }
        menu.addItem(disabled(status))
        menu.addItem(disabled("\(controller.model.name) · Neural Engine"))
        menu.addItem(.separator())

        let pasteLast = item("Paste Last Transcript", #selector(pasteLastAction))
        pasteLast.keyEquivalent = "v"
        pasteLast.keyEquivalentModifierMask = [.command, .control]
        pasteLast.isEnabled = controller.lastTranscript != nil
        menu.addItem(pasteLast)

        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        for entry in controller.history.entries.prefix(12) {
            let title = entry.text.count > 70 ? String(entry.text.prefix(70)) + "…" : entry.text
            let mi = item(title, #selector(copyRecent(_:)))
            mi.representedObject = entry.layout ?? entry.text
            mi.toolTip = entry.layout ?? entry.text
            recentMenu.addItem(mi)
        }
        if recentMenu.items.isEmpty { recentMenu.addItem(disabled("Nothing yet")) }
        recent.submenu = recentMenu
        menu.addItem(recent)
        menu.addItem(.separator())

        let mic = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let micMenu = NSMenu()
        let systemDefault = item("System Default", #selector(selectMic(_:)))
        systemDefault.state = controller.micUID == nil ? .on : .off
        micMenu.addItem(systemDefault)
        micMenu.addItem(.separator())
        for device in AudioDevices.inputDevices() {
            let mi = item(device.name, #selector(selectMic(_:)))
            mi.representedObject = device.uid
            mi.state = controller.micUID == device.uid ? .on : .off
            micMenu.addItem(mi)
        }
        mic.submenu = micMenu
        menu.addItem(mic)

        let sounds = item("Sounds", #selector(toggleSounds))
        sounds.state = controller.sounds ? .on : .off
        menu.addItem(sounds)
        menu.addItem(.separator())

        let settings = item("Settings…", #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        if Updater.shared.isAvailable { menu.addItem(item("Check for Updates…", #selector(checkForUpdates))) }
        if !Windows.isOnboarded { menu.addItem(item("Finish Setup…", #selector(openOnboarding))) }

        if !Permissions.accessibility || Permissions.microphone != .authorized {
            menu.addItem(.separator())
            if !Permissions.accessibility {
                menu.addItem(item("⚠︎ Grant Accessibility Access…", #selector(openAX)))
            }
            if Permissions.microphone != .authorized {
                menu.addItem(item("⚠︎ Grant Microphone Access…", #selector(openMic)))
            }
        }

        menu.addItem(.separator())
        let quit = item("Quit Murmur", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        return mi
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    @objc private func pasteLastAction() {
        // Let the menu close and focus return to the previous app first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [controller] in controller.pasteLast() }
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String { TextInserter.copyToClipboard(text) }
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        controller.micUID = sender.representedObject as? String
    }

    @objc private func toggleSounds() { controller.sounds.toggle() }

    @objc private func openSettings() { windows.showSettings() }

    @objc private func openOnboarding() { windows.showOnboarding() }

    @objc private func checkForUpdates() { Updater.shared.checkForUpdates() }

    @objc private func openAX() {
        Permissions.promptAccessibility()
        Permissions.openAccessibilitySettings()
    }

    @objc private func openMic() {
        if Permissions.microphone == .notDetermined {
            Task { _ = await Permissions.requestMicrophone() }
        } else {
            Permissions.openMicrophoneSettings()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// `Murmur --transcribe <file> [--model unified|phonon2]`: headless check of the model paths
/// (Unified also runs its streaming encoder).
enum CLI {
    static func transcribe(path: String, model: SpeechModel) async {
        let t = Transcriber()
        let start = Date()
        do {
            nonisolated(unsafe) var lastPct = -1
            try await t.load(model, includeStreaming: model == .unified) { p, message in
                if let p {
                    let pct = Int(p * 100)
                    if pct != lastPct, pct % 5 == 0 {
                        lastPct = pct
                        print(message)
                    }
                } else {
                    print(message)
                }
            }
            print(String(format: "models ready in %.1fs", Date().timeIntervalSince(start)))

            let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
            print(String(format: "audio: %.2fs", Double(samples.count) / 16000))

            var t0 = Date()
            if model == .unified {
                let live = try await t.streamWhole(samples)
                print(String(format: "streaming (%.3fs): %@", Date().timeIntervalSince(t0), live))
            }

            t0 = Date()
            let final = await t.finalize(samples: samples)
            print(String(format: "offline   (%.3fs): %@", Date().timeIntervalSince(t0), final.text))

            t0 = Date()
            Layout.trace = { print("  " + $0) }
            let layout = Layout.format(final.text, words: final.words)
            print(String(format: "layout    (%.3fs):", Date().timeIntervalSince(t0)))
            print(layout ?? "(unchanged)")
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }
}

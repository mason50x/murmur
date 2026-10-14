import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let controller: AppController
    let windows: Windows

    @AppStorage("sounds") private var sounds = true
    @AppStorage("muteWhileDictating") private var muteWhileDictating = true
    @AppStorage("micUID") private var micUID = ""
    @AppStorage("keepHistory") private var keepHistory = true
    @AppStorage("keepLastRecording") private var keepLastRecording = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var autoUpdate = Updater.shared.automaticallyChecks
    @State private var devices = AudioDevices.inputDevices()
    @State private var historyCount = 0

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Microphone", selection: $micUID) {
                    Text("System default").tag("")
                    ForEach(devices, id: \.uid) { Text($0.name).tag($0.uid) }
                }
                LabeledContent("Sounds") {
                    HStack {
                        Button("Preview") {
                            SoundFX.open()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { SoundFX.close() }
                        }
                        .controlSize(.small)
                        Toggle("", isOn: $sounds).labelsHidden().toggleStyle(.switch)
                    }
                }
                Toggle("Mute other audio while dictating", isOn: $muteWhileDictating)
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in setLoginItem(on) }
            }

            Section {
                ForEach(SpeechModel.allCases) { model in
                    ModelChoice(model: model, controller: controller)
                }
            } header: {
                Text("Speech model")
            } footer: {
                Text("This Mac: \(DeviceProfile.current.description). Switching downloads the new model, then deletes the old one.")
            }

            Section {
                Toggle("Keep transcript history", isOn: $keepHistory)
                    .onChange(of: keepHistory) { _, _ in controller.history.enabledChanged() }
                LabeledContent("Recent transcripts") {
                    Button("Clear History") {
                        controller.history.clear()
                        historyCount = 0
                    }
                    .disabled(historyCount == 0)
                }
                Toggle("Keep the last recording for troubleshooting", isOn: $keepLastRecording)
                    .onChange(of: keepLastRecording) { _, on in if !on { AppController.deleteLastRecording() } }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Speech is transcribed on this Mac and never leaves it. Murmur only goes online to download its speech model and check for updates. History keeps your last 50 transcripts in a file only you can read.")
            }

            Section {
                Toggle("Check for updates automatically", isOn: $autoUpdate)
                    .onChange(of: autoUpdate) { _, on in Updater.shared.automaticallyChecks = on }
                    .disabled(!Updater.shared.isAvailable)
                LabeledContent("Murmur \(Updater.version)") {
                    Button("Check Now") { Updater.shared.checkForUpdates() }
                        .disabled(!Updater.shared.isAvailable)
                }
            } header: {
                Text("Updates")
            } footer: {
                if !Updater.shared.isAvailable {
                    Text("Updates are off because this copy's updater failed its signature check. Reinstall Murmur from github.com/mason50x/murmur.")
                        .foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("Setup guide") {
                    Button("Show") { windows.showOnboarding() }
                }
                LabeledContent("Accessibility") {
                    if Permissions.accessibility {
                        Text("On").foregroundStyle(.secondary)
                    } else {
                        Button("Open Settings") {
                            Permissions.promptAccessibility()
                            Permissions.openAccessibilitySettings()
                        }
                    }
                }
                LabeledContent("Microphone") {
                    if Permissions.microphone == .authorized {
                        Text("On").foregroundStyle(.secondary)
                    } else {
                        Button("Open Settings") { Permissions.openMicrophoneSettings() }
                    }
                }
                HStack {
                    Link("Source code", destination: URL(string: "https://github.com/mason50x/murmur")!)
                    Spacer()
                    Link("Report a problem", destination: URL(string: "https://github.com/mason50x/murmur/issues/new/choose")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .onAppear {
            devices = AudioDevices.inputDevices()
            historyCount = controller.history.entries.count
            openAtLogin = SMAppService.mainApp.status == .enabled
            autoUpdate = Updater.shared.automaticallyChecks
        }
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.info("login item: \(error)")
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct ModelChoice: View {
    let model: SpeechModel
    let controller: AppController

    private var current: Bool { controller.model == model }
    private var busy: Bool {
        switch controller.phase {
        case .recording, .transcribing: true
        default: controller.isLoadingModel
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name).fontWeight(.medium)
                    if model == DeviceProfile.current.recommended {
                        Text("Recommended for this Mac")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("\(model.summary) \(model.downloadMB) MB, \(model.wordErrorRate) word error rate.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if current { status }
            }
            Spacer(minLength: 8)
            if current && controller.modelError != nil {
                Button("Retry") { controller.selectModel(model) }
            } else if current {
                Image(systemName: "checkmark").foregroundStyle(.tint).padding(.top, 2)
                    .accessibilityLabel("In use")
            } else {
                Button("Use") { controller.selectModel(model) }.disabled(busy)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var status: some View {
        if let error = controller.modelError {
            Text("Couldn't load: \(error)").font(.caption).foregroundStyle(.red)
        } else if controller.isLoadingModel {
            VStack(alignment: .leading, spacing: 3) {
                if let f = controller.loadProgress.fraction {
                    ProgressView(value: f)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(controller.loadProgress.message).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }
}

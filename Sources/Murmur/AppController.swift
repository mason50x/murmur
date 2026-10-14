import AVFoundation
import AppKit
import FluidAudio
import Observation

@MainActor
@Observable
final class AppController {
    enum Phase: Equatable {
        case loading(progress: Double?, message: String)
        case idle
        case recording
        case transcribing
        /// Text with a Copy button: nothing could receive it, or (`pasted`) we pasted blind.
        case result(String, pasted: Bool)
        case message(String)
    }

    // MARK: Observable UI state
    private(set) var phase: Phase = .loading(progress: nil, message: "Starting…")
    private(set) var locked = false
    /// Dictation timer: start, and end once recording stops (freezes the display).
    @ObservationIgnored private(set) var recordingStartedAt = Date()
    private(set) var recordingEndedAt: Date?
    /// Loudness history, one column per 50 ms, newest last.
    private(set) var levels: [Float] = Array(repeating: 0, count: 36)
    /// Recording UI is revealed after a short delay so ⌥-shortcuts don't flash the notch.
    private(set) var showRecording = false
    private(set) var copied = false
    var hovering = false {
        didSet { if oldValue != hovering { hoverChanged() } }
    }
    /// The model loaded (or loading) for dictation.
    private(set) var model: SpeechModel = SpeechModel.selected ?? DeviceProfile.current.recommended
    private(set) var modelReady = false
    /// Why the model couldn't load, until the next attempt.
    private(set) var modelError: String?
    /// The latest download/compile progress while the model loads (nil fraction = indeterminate).
    private(set) var loadProgress: (fraction: Double?, message: String) = (nil, "Starting…")
    /// Onboarding's practice field: while set and Murmur is frontmost, transcripts go here
    /// instead of being pasted.
    @ObservationIgnored var captureDelivery: ((String) -> Void)?
    /// Onboarding's microphone check is metering the mic (nothing is kept or transcribed).
    private(set) var micPreviewing = false

    // MARK: Collaborators
    @ObservationIgnored let history = History()
    @ObservationIgnored private let transcriber = Transcriber()
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let hotkey = HotkeyMonitor()
    @ObservationIgnored private var pasteLastShortcut: GlobalShortcut?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private var muteTask: Task<Void, Never>?
    @ObservationIgnored private var axPoll: Timer?
    @ObservationIgnored private var levelBucket: Float = 0
    @ObservationIgnored private var levelBucketStart = Date()
    @ObservationIgnored private var levelPeak: Float = 0.35

    var sounds: Bool {
        get { UserDefaults.standard.object(forKey: "sounds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sounds") }
    }

    /// Mute the Mac's sound output while dictating.
    var muteWhileDictating: Bool {
        UserDefaults.standard.object(forKey: "muteWhileDictating") as? Bool ?? true
    }

    var micUID: String? {
        get { UserDefaults.standard.string(forKey: "micUID").flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue, forKey: "micUID") }
    }

    /// Troubleshooting only: keep the last recording at ~/Library/Logs/Murmur-last.wav.
    static var keepLastRecording: Bool { UserDefaults.standard.bool(forKey: "keepLastRecording") }

    var lastTranscript: History.Entry? { history.entries.first }

    var isRecording: Bool { phase == .recording }

    // MARK: - Lifecycle

    /// - Parameter firstRun: onboarding is showing. It asks for each permission with an
    ///   explanation (instead of system prompts appearing out of nowhere) and starts the model
    ///   download once a model is picked.
    func bootstrap(firstRun: Bool) {
        hotkey.isLocked = { [weak self] in self?.locked ?? false }
        hotkey.handler = { [weak self] event in self?.handle(event) }
        hotkey.install()
        pasteLastShortcut = GlobalShortcut(
            keyCode: 9 /* V */, modifiers: 0x0100 /* cmdKey */ | 0x1000 /* controlKey */
        ) { [weak self] in self?.pasteLast() }

        if !Self.keepLastRecording { Self.deleteLastRecording() }
        OutputMute.release()  // in case the last run quit mid-dictation
        if !Permissions.accessibility {
            if !firstRun { Permissions.promptAccessibility() }
            // Global key monitors only start delivering once trusted; reinstall when that happens.
            axPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard Permissions.accessibility else { return }
                    timer.invalidate()
                    Log.info("accessibility granted; hotkeys reinstalled")
                    self?.hotkey.install()
                }
            }
        }

        // First run waits for onboarding to pick a model, unless an earlier session already did.
        if firstRun && SpeechModel.selected == nil {
            phase = .idle
            return
        }
        loadTask = Task {
            if !firstRun { _ = await Permissions.requestMicrophone() }
            await loadModel()
        }
    }

    /// Switches dictation to `new` (or retries it after a failure), downloading it if needed.
    /// The previous model's files are removed once the new one is ready.
    func selectModel(_ new: SpeechModel) {
        SpeechModel.selected = new
        if new == model, loadTask != nil, modelError == nil { return }
        let previous = loadTask != nil ? model : nil
        model = new
        let prior = loadTask
        loadTask = Task {
            await prior?.value
            guard self.model == new else { return }
            await loadModel()
            if modelReady, self.model == new, let previous, previous != new { previous.deleteFiles() }
        }
    }

    /// Whether the model is being downloaded or loaded right now.
    var isLoadingModel: Bool { loadTask != nil && !modelReady && modelError == nil }

    private func loadModel() async {
        let model = self.model
        modelReady = false
        modelError = nil
        showLoading(nil, "Starting…")
        do {
            try await transcriber.load(model) { [weak self] progress, message in
                Task { @MainActor in
                    guard let self, !self.modelReady, self.model == model else { return }
                    self.showLoading(progress, message)
                }
            }
            guard self.model == model else { return }
            modelReady = true
            Log.info("model \(model.rawValue) ready; ax=\(Permissions.accessibility) mic=\(Permissions.microphone.rawValue)")
            if case .loading = phase { phase = .idle }
        } catch {
            modelReady = false
            modelError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if case .loading = phase { phase = .idle }
            flash("Model failed to load — open Settings to retry")
            Log.info("model \(model.rawValue) load failed: \(error)")
        }
    }

    private func showLoading(_ fraction: Double?, _ message: String) {
        loadProgress = (fraction, message)
        switch phase {
        case .idle, .loading: phase = .loading(progress: fraction, message: message)
        default: break  // don't interrupt a recording or a card that's showing
        }
    }

    // MARK: - Hotkey events

    private func handle(_ event: HotkeyMonitor.Event) {
        if event != .escape || phase != .idle { Log.info("hotkey \(event) phase=\(phase)") }
        switch event {
        case .start: startRecording()
        case .stop: stopRecording()
        case .lock:
            guard isRecording else { return }
            locked = true
            reveal()
        case .cancel: if isRecording { cancelRecording() }
        case .escape:
            if isRecording {
                cancelRecording()
            } else if case .result = phase {
                collapse()
            }
        }
    }

    // MARK: - Recording

    func startRecording() {
        stopMicPreview()
        switch phase {
        case .idle, .result, .message: break
        default: return
        }
        guard modelReady else {
            flash(modelError == nil ? "Model is still loading…" : "Model failed to load — open Settings to retry")
            return
        }
        guard Permissions.microphone == .authorized else {
            if Permissions.microphone == .notDetermined {
                Task { _ = await Permissions.requestMicrophone() }
            } else {
                flash("Microphone access is off — enable it in Settings")
                Permissions.openMicrophoneSettings()
            }
            return
        }

        collapseTask?.cancel()
        locked = false
        copied = false
        levels = Array(repeating: 0, count: levels.count)
        levelPeak = 0.35

        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.push(level: level) }
        }
        do {
            try recorder.start(deviceUID: micUID)
        } catch {
            flash("Couldn't start microphone: \(error.localizedDescription)")
            return
        }
        recordingStartedAt = Date()
        recordingEndedAt = nil
        phase = .recording
        showRecording = false
        TextInserter.primeFrontmostApp()
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.reveal()
        }
    }

    private func reveal() {
        guard isRecording, !showRecording else { return }
        showRecording = true
        muteOutput()
    }

    /// Mutes once the notch is up, so ⌥-shortcuts never blip the sound. Waits out the open
    /// sound first, which muting would cut off.
    private func muteOutput() {
        guard muteWhileDictating else { return }
        let delay = sounds ? 200 : 0
        muteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self, !Task.isCancelled, self.isRecording else { return }
            OutputMute.engage()
        }
    }

    private func unmuteOutput() {
        muteTask?.cancel()
        OutputMute.release()
    }

    func stopRecording() {
        guard isRecording else { return }
        revealTask?.cancel()
        unmuteOutput()
        let samples = recorder.stop()
        recordingEndedAt = Date()
        locked = false
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        Log.info(String(format: "stop: %.2fs peak=%.4f", Double(samples.count) / 16000, peak))
        if Self.keepLastRecording { Self.saveLastRecording(samples) }
        if Double(samples.count) / 16000 < 0.3 {
            discardSession()
            return
        }
        phase = .transcribing
        Task {
            let transcript = await transcriber.finalize(samples: samples)
            deliver(transcript.text, layout: await Layout.formatInBackground(transcript))
        }
    }

    /// Onboarding: drive `levels` from the mic so you can see Murmur hear you. Audio is discarded.
    func startMicPreview() {
        guard !micPreviewing, !isRecording, phase != .transcribing, Permissions.microphone == .authorized
        else { return }
        levels = Array(repeating: 0, count: levels.count)
        levelPeak = 0.35
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.push(level: level) }
        }
        do {
            try recorder.start(deviceUID: micUID)
            micPreviewing = true
        } catch {
            Log.info("mic preview failed: \(error)")
        }
    }

    func stopMicPreview() {
        guard micPreviewing else { return }
        micPreviewing = false
        _ = recorder.stop()
    }

    func cancelRecording() {
        guard isRecording else { return }
        revealTask?.cancel()
        unmuteOutput()
        _ = recorder.stop()
        locked = false
        discardSession()
    }

    private func discardSession() {
        showRecording = false
        phase = .idle
    }

    /// Buckets per-buffer levels into 40 ms steps with automatic gain, so quiet voices still
    /// drive the pixel wave across its full range.
    private func push(level: Float) {
        guard isRecording || micPreviewing else { return }
        levelBucket = max(levelBucket, level)
        let now = Date()
        guard now.timeIntervalSince(levelBucketStart) >= 0.04 else { return }
        levelPeak = max(levelBucket, levelPeak * 0.985, 0.3)
        levels.removeFirst()
        levels.append(min(1, levelBucket / levelPeak))
        levelBucket = 0
        levelBucketStart = now
    }

    #if MURMUR_DEBUG_HOOKS
    /// Debug/verification: run an audio file through the same pipeline as live dictation.
    func simulate(file: URL) {
        switch phase {
        case .idle, .result, .message: break
        default: return
        }
        guard modelReady, let samples = try? AudioConverter().resampleAudioFile(file) else {
            flash("Can't simulate \(file.lastPathComponent)")
            return
        }
        collapseTask?.cancel()
        locked = false
        recordingStartedAt = Date()
        recordingEndedAt = nil
        phase = .recording
        showRecording = true
        Task {
            let chunk = 1600  // 100 ms, fed at ~4x real time
            var i = 0
            while i < samples.count, isRecording {
                let slice = Array(samples[i..<min(i + chunk, samples.count)])
                let rms = sqrt(slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count))
                push(level: min(max((20 * log10(max(rms, 1e-7)) + 55) / 45, 0), 1))
                i += chunk
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard isRecording else { return }
            recordingEndedAt = Date()
            phase = .transcribing
            let transcript = await transcriber.finalize(samples: samples)
            deliver(transcript.text, layout: await Layout.formatInBackground(transcript))
        }
    }

    /// Debug: show a canned UI state (`open -g "murmur://preview?state=result"`). No audio, no paste.
    func preview(_ state: String) {
        collapseTask?.cancel()
        let sample = "Okay so for the launch next week, let's move the demo to Thursday and make sure the onboarding flow is finished before then."
        levels = (0..<levels.count).map { _ in Float.random(in: 0.2...0.9) }
        showRecording = false
        locked = false
        recordingStartedAt = Date().addingTimeInterval(state == "transcribing" ? -7 : -55)
        recordingEndedAt = state == "transcribing" ? Date() : nil
        switch state {
        case "recording": phase = .recording; showRecording = true; fakeVoice()
        case "locked": phase = .recording; showRecording = true; locked = true; fakeVoice()
        case "transcribing": phase = .transcribing
        case "result": phase = .result(sample + " Also remind me to email the design team about the new icons.", pasted: false)
        case "pasted": phase = .result(sample, pasted: true)
        case "message": phase = .message("Speak louder")
        case "loading": phase = .loading(progress: 0.42, message: "Downloading model 42%")
        case "preparing": phase = .loading(progress: nil, message: "Preparing model…")
        default: phase = .idle; hovering = false
        }
    }

    /// Debug: record the mic for `seconds`, transcribe offline, and log it. No UI, no paste.
    func micTest(seconds: Double) {
        guard modelReady, phase == .idle else { return }
        do {
            recorder.onLevel = nil
            try recorder.start(deviceUID: micUID)
        } catch {
            Log.info("mictest: start failed \(error)")
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            let samples = recorder.stop()
            Self.saveLastRecording(samples)
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            let text = (try? await transcriber.transcribeOffline(samples)) ?? "<error>"
            Log.info(String(format: "mictest: %.2fs peak=%.4f → ", Double(samples.count) / 16000, peak) + text)
        }
    }

    #endif

    nonisolated private static var lastRecordingURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Murmur-last.wav")
    }

    nonisolated static func deleteLastRecording() {
        try? FileManager.default.removeItem(at: lastRecordingURL)
    }

    /// Keeps the most recent recording at ~/Library/Logs/Murmur-last.wav for troubleshooting
    /// (only when enabled in Settings).
    nonisolated static func saveLastRecording(_ samples: [Float]) {
        let url = lastRecordingURL
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { buffer.floatChannelData![0].update(from: base, count: samples.count) }
        }
        try? FileManager.default.removeItem(at: url)
        if let file = try? AVAudioFile(forWriting: url, settings: format.settings) { try? file.write(from: buffer) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    #if MURMUR_DEBUG_HOOKS
    /// Preview only: syllable-ish loudness so the pixel wave has something to chew on.
    private func fakeVoice() {
        Task {
            var t = 0.0
            while phase == .recording || phase == .transcribing {
                let syllable = max(0, sin(t * 9) * sin(t * 2.3 + 1)) * 0.85
                levels.removeFirst()
                levels.append(Float(syllable + Double.random(in: 0...0.12)))
                t += 0.05
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
    #endif

    // MARK: - Delivery

    private func deliver(_ text: String, layout: String?) {
        Log.info("deliver: \(text.count) chars, frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
        showRecording = false
        guard !text.isEmpty else {
            flash("Speak louder", for: 1.3)
            return
        }
        if let capture = captureDelivery, NSApp.isActive {
            phase = .idle
            capture(SmartFormat.apply(layout ?? text, before: nil, after: nil))
            return
        }
        history.add(text, layout: layout)
        let standalone = SmartFormat.apply(layout ?? text, before: nil, after: nil)
        switch TextInserter.delivery() {
        case .paste(let target):
            TextInserter.paste(text, layout: layout, into: target)
            phase = .idle
        case .pasteAndShow(let target):
            TextInserter.paste(text, layout: layout, into: target)
            phase = .result(standalone, pasted: true)
            scheduleCollapse(after: 5)
        case .show:
            phase = .result(standalone, pasted: false)
            scheduleCollapse(after: 15)
        }
    }

    func pasteLast() {
        guard let entry = lastTranscript, !isRecording else { return }
        switch TextInserter.delivery() {
        case .paste(let target), .pasteAndShow(let target):
            TextInserter.paste(entry.text, layout: entry.layout, into: target)
        case .show:
            phase = .result(SmartFormat.apply(entry.layout ?? entry.text, before: nil, after: nil), pasted: false)
            scheduleCollapse(after: 15)
        }
    }

    func copy(_ text: String) {
        TextInserter.copyToClipboard(text)
        copied = true
        scheduleCollapse(after: 0.9)
    }

    // MARK: - Collapse / hover

    func collapse() {
        collapseTask?.cancel()
        copied = false
        guard !isRecording && phase != .transcribing else { return }
        phase = isLoadingModel ? .loading(progress: loadProgress.fraction, message: loadProgress.message) : .idle
    }

    private func flash(_ message: String, for seconds: Double = 2.2) {
        phase = .message(message)
        scheduleCollapse(after: seconds)
    }

    private func scheduleCollapse(after seconds: Double) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            if self.hovering { return }  // re-armed when the pointer leaves
            self.collapse()
        }
    }

    private func hoverChanged() {
        guard !hovering else {
            collapseTask?.cancel()
            return
        }
        switch phase {
        case .result, .message: scheduleCollapse(after: 1.2)
        default: break
        }
    }
}

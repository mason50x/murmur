import AVFoundation
import ServiceManagement
import SwiftUI

/// A cool sheet of paper with Murmur's notch as the only black thing on it. The notch grows out
/// of the window's bottom-right corner, where it lives on screen, and stages each step: a demo,
/// the model download, your live microphone level, and finally your own words.
enum Ink {
    static let paper = Color(light: 0xF3F4F6, dark: 0x1A1B1E)
    static let text = Color(light: 0x000000, dark: 0xF4F5F7)
    static let secondary = Color(light: 0x5C6068, dark: 0xA3A7AE)
    static let hairline = Color(light: 0xD9DCE1, dark: 0x34363B)
    static let key = Color(light: 0xFFFFFF, dark: 0x2A2C30)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            })
    }
}

struct OnboardingView: View {
    static let size = CGSize(width: 620, height: 460)

    let controller: AppController
    let finish: () -> Void

    enum Step: Int, CaseIterable {
        case welcome, model, microphone, accessibility, practice, done
    }

    @State private var step: Step
    @State private var choice = SpeechModel.selected ?? DeviceProfile.current.recommended
    @State private var mic = Permissions.microphone
    @State private var axTrusted = Permissions.accessibility
    @State private var askedForAX = false
    @State private var practiceText: String?
    @State private var openAtLogin = true
    @State private var autoUpdate = true
    @State private var demoLevels = [Float](repeating: 0, count: 36)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(controller: AppController, step: Step = .welcome, practiceText: String? = nil, finish: @escaping () -> Void) {
        self.controller = controller
        self.finish = finish
        _step = State(initialValue: step)
        _practiceText = State(initialValue: practiceText)
        #if MURMUR_DEBUG_HOOKS
        if let demo = Render.demoLevels { _demoLevels = State(initialValue: demo) }
        #endif
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Ink.paper.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                page
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: reduceMotion ? 0 : 14)),
                        removal: .opacity))
                Spacer(minLength: 0)
                footer
            }
            .padding(.leading, 48)
            .padding(.top, 60)
            .padding(.bottom, 32)
            .frame(width: 400, alignment: .leading)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .overlay(alignment: .topTrailing) { stepDots.padding(.top, 21).padding(.trailing, 24) }
        .overlay(alignment: .bottomTrailing) { stage }
        .animation(.smooth(duration: 0.3), value: step)
        .task(id: step) { await watch() }
        .onChange(of: step) { old, new in stepChanged(from: old, to: new) }
        .onDisappear { controller.captureDelivery = nil }
    }

    // MARK: - Pages

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome:
            Page(
                title: "Talk instead\nof type.",
                text: "Hold the right Option key, say what you want to write, and let go. Murmur puts the words wherever your cursor is."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Point("lock", "Transcribed on this Mac. Audio never leaves it.")
                    Point("character.cursor.ibeam", "Works in any app you can type in.")
                    Point("bolt", "Text appears about a second after you let go.")
                }
            }
        case .model:
            Page(
                title: "A speech model\nfor this Mac",
                text: "Murmur runs one speech model on your Mac's Neural Engine, fully offline. For your \(DeviceProfile.current.description), this is the best fit:"
            ) {
                VStack(spacing: 8) {
                    ForEach(modelOrder) { model in
                        ModelRow(
                            model: model, selected: choice == model,
                            recommended: model == DeviceProfile.current.recommended
                        ) { choice = model }
                    }
                }
            }
        case .microphone:
            Page(
                title: "Let Murmur\nhear you",
                text: "Murmur listens only while you hold the key. Your audio is transcribed on this Mac and then discarded. It's never saved or sent anywhere."
            ) {
                switch mic {
                case .authorized:
                    Status(done: true, "Microphone on. Say something and watch the corner.")
                case .notDetermined:
                    EmptyView()
                default:
                    Status(done: false, "Microphone access is off for Murmur. Turn it on in Privacy & Security › Microphone.")
                }
            }
        case .accessibility:
            Page(
                title: "Let Murmur\ntype for you",
                text: "Murmur needs Accessibility access to notice the right Option key from any app, read the text around your cursor so punctuation fits, and paste what you said."
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsRowMock(on: axTrusted)
                    if axTrusted {
                        Status(done: true, "Access granted.")
                    } else if askedForAX {
                        Text("Turn on Murmur in the list that opened. If it isn't there, click + and choose Murmur from Applications.")
                            .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .practice:
            Page(
                title: practiceText == nil ? "Try it" : "That's all\nthere is to it.",
                text: practiceText == nil
                    ? "Hold the right Option key, say a sentence, then let go."
                    : "It works the same way in every app you type in."
            ) {
                if practiceText == nil {
                    VStack(alignment: .leading, spacing: 14) {
                        KeyRow(pressed: controller.phase == .recording, dim: !controller.modelReady)
                        if let error = controller.modelError {
                            Status(done: false, "The speech model didn't load: \(error)")
                        } else if !controller.modelReady {
                            LoadingBar(progress: controller.loadProgress)
                        }
                    }
                }
            }
        case .done:
            Page(
                title: "You're set",
                text: "Murmur waits in the menu bar. Hold the right Option key whenever you'd rather say it than type it."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                        Shortcut("Hold right ⌥", "Dictate, then let go to insert")
                        Shortcut("Double-tap right ⌥", "Hands-free; tap again to stop")
                        Shortcut("Esc", "Cancel")
                        Shortcut("⌃⌘V", "Paste the last transcript again")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Open Murmur when you log in", isOn: $openAtLogin)
                        Toggle("Check for updates automatically", isOn: $autoUpdate)
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ink.text)
                }
            }
        }
    }

    private var modelOrder: [SpeechModel] {
        let rec = DeviceProfile.current.recommended
        return [rec] + SpeechModel.allCases.filter { $0 != rec }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            primaryButton
            if let secondary = secondaryAction {
                Button(secondary.title, action: secondary.run)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Ink.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 34)
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule()
                    .fill(s == step ? Ink.text : Ink.hairline)
                    .frame(width: s == step ? 14 : 6, height: 6)
            }
        }
        .animation(.smooth(duration: 0.3), value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    @ViewBuilder private var primaryButton: some View {
        switch step {
        case .welcome:
            PrimaryButton("Get started") { advance() }
        case .model:
            PrimaryButton(choice.isDownloaded ? "Use \(choice.name)" : "Download \(choice.name)") {
                controller.selectModel(choice)
                advance()
            }
        case .microphone:
            switch mic {
            case .notDetermined:
                PrimaryButton("Allow microphone") {
                    Task {
                        _ = await Permissions.requestMicrophone()
                        mic = Permissions.microphone
                        if mic == .authorized { controller.startMicPreview() }
                    }
                }
            case .authorized:
                PrimaryButton("Continue") { advance() }
            default:
                PrimaryButton("Open Privacy settings") { Permissions.openMicrophoneSettings() }
            }
        case .accessibility:
            if axTrusted {
                PrimaryButton("Continue") { advance() }
            } else {
                PrimaryButton("Open Accessibility settings") {
                    askedForAX = true
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            }
        case .practice:
            PrimaryButton(practiceText == nil ? "Skip" : "Continue", quiet: practiceText == nil) { advance() }
        case .done:
            PrimaryButton("Start dictating") { complete() }
        }
    }

    private var secondaryAction: (title: String, run: () -> Void)? {
        switch step {
        case .microphone where mic != .authorized && mic != .notDetermined:
            return ("Skip for now", { advance() })
        case .accessibility where !axTrusted:
            return ("Skip for now", { advance() })
        case .practice where controller.modelError != nil:
            return ("Try again", { controller.selectModel(controller.model) })
        default:
            return nil
        }
    }

    // MARK: - Stage (the notch in the corner)

    private var stageSize: CGSize {
        switch step {
        case .welcome, .model, .microphone: return CGSize(width: 206, height: 60)
        case .accessibility: return CGSize(width: 220, height: 60)
        case .practice:
            guard let practiceText else { return CGSize(width: 232, height: 60) }
            let lines = min(6, max(1, Int(ceil(Double(practiceText.count) / 36))))
            return CGSize(width: 300, height: CGFloat(lines) * 19 + 78)
        case .done: return .zero
        }
    }

    private var stage: some View {
        ZStack(alignment: .topLeading) {
            CornerNotchShape(flare: NotchLayout.flare, radius: 22).fill(Color.black)
            stageContent
                .padding(.leading, NotchLayout.flare + 18)
                .padding(.top, NotchLayout.flare + 12)
                .padding(.trailing, 18)
                .padding(.bottom, 14)
                .frame(width: stageSize.width, height: stageSize.height, alignment: .topLeading)
        }
        .frame(width: stageSize.width, height: stageSize.height)
        .clipShape(CornerNotchShape(flare: NotchLayout.flare, radius: 22))
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? .none : .spring(response: 0.45, dampingFraction: 0.8), value: stageSize)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var stageContent: some View {
        switch step {
        case .welcome:
            StageRow {
                DriftWave(levels: demoLevels, locked: false, processing: false)
                Text("0:04").font(.system(size: 13.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
            }
        case .model:
            StageRow {
                Image(systemName: choice.isDownloaded ? "checkmark" : "arrow.down")
                    .font(.system(size: 12, weight: .bold))
                StageLabel(choice.isDownloaded ? "On this Mac" : "\(choice.downloadMB) MB, one time")
            }
        case .microphone:
            if mic == .authorized {
                StageRow {
                    DriftWave(levels: controller.levels, locked: false, processing: false)
                    StageLabel("Listening")
                }
            } else {
                StageRow {
                    Image(systemName: "mic.slash").font(.system(size: 12, weight: .semibold))
                    StageLabel("Microphone off")
                }
            }
        case .accessibility:
            StageRow {
                if axTrusted {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                    StageLabel("Access granted")
                } else {
                    ProgressView().controlSize(.small).tint(.white)
                    StageLabel("Waiting for access")
                }
            }
        case .practice:
            if let practiceText {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "text.quote").font(.system(size: 12, weight: .semibold))
                        StageLabel("You said", dim: true)
                    }
                    ScrollView {
                        Text(practiceText).font(.system(size: 13.5)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .scrollIndicators(.never)
                }
            } else {
                StageRow {
                    switch controller.phase {
                    case .recording:
                        DriftWave(levels: controller.levels, locked: controller.locked, processing: false)
                    case .transcribing:
                        DriftWave(levels: controller.levels, locked: false, processing: true)
                    default:
                        if controller.modelReady {
                            StageLabel("Hold right ⌥ and speak")
                        } else if controller.modelError != nil {
                            StageLabel("Model didn't load")
                        } else {
                            ProgressView().controlSize(.small).tint(.white)
                            StageLabel(controller.loadProgress.fraction.map { "Downloading \(Int($0 * 100))%" } ?? "Preparing model")
                        }
                    }
                }
            }
        case .done:
            EmptyView()
        }
    }

    // MARK: - Flow

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    private func stepChanged(from old: Step, to new: Step) {
        if old == .microphone { controller.stopMicPreview() }
        if new == .microphone, mic == .authorized { controller.startMicPreview() }
        if new == .practice {
            controller.captureDelivery = { text in practiceText = text }
        } else if old == .practice {
            controller.captureDelivery = nil
        }
    }

    /// Per-step background work: the welcome demo's fake voice, and permission polling
    /// (macOS doesn't notify apps when you flip a switch in System Settings).
    private func watch() async {
        var t = 0.0
        while !Task.isCancelled {
            switch step {
            case .welcome:
                let syllable = max(0, sin(t * 9) * sin(t * 2.3 + 1)) * 0.85
                demoLevels.removeFirst()
                demoLevels.append(Float(syllable + Double.random(in: 0...0.1)))
                t += 0.04
                try? await Task.sleep(for: .milliseconds(40))
                continue
            case .microphone:
                let now = Permissions.microphone
                if now != mic {
                    mic = now
                    if now == .authorized { controller.startMicPreview() }
                }
            case .accessibility:
                if !axTrusted, Permissions.accessibility {
                    axTrusted = true
                    // Come back from System Settings once access is on.
                    NSApp.activate()
                }
            default:
                break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func complete() {
        do {
            if openAtLogin, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !openAtLogin, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.info("login item: \(error)")
        }
        Updater.shared.automaticallyChecks = autoUpdate
        if !controller.modelReady && !controller.isLoadingModel { controller.selectModel(choice) }
        finish()
    }
}

// MARK: - Pieces

private struct Page<Extra: View>: View {
    let title: String
    let text: String
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 32, weight: .semibold))
                .fontWidth(.expanded)
                .kerning(-0.6)
                .lineSpacing(2)
                .foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.system(size: 14))
                .lineSpacing(3.5)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            extra.padding(.top, 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Point: View {
    let symbol: String
    let text: String

    init(_ symbol: String, _ text: String) {
        self.symbol = symbol
        self.text = text
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .frame(width: 16)
            Text(text).font(.system(size: 13)).foregroundStyle(Ink.text)
        }
    }
}

private struct Status: View {
    let done: Bool
    let text: String

    init(done: Bool, _ text: String) {
        self.done = done
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(Ink.text)
            Text(text).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
    }
}

private struct PrimaryButton: View {
    let title: String
    var quiet = false
    let action: () -> Void

    init(_ title: String, quiet: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.quiet = quiet
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(quiet ? Ink.text : Ink.paper)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(Capsule().fill(quiet ? Ink.hairline.opacity(0.7) : Ink.text))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }
}

private struct ModelRow: View {
    let model: SpeechModel
    let selected: Bool
    let recommended: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Ink.text : Ink.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(model.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Ink.text)
                        if recommended {
                            Text("Recommended")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Ink.paper)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Ink.text))
                        }
                    }
                    Text("\(model.tier), \(model.downloadMB) MB download")
                        .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Ink.key.opacity(selected ? 1 : 0.5))
                    .strokeBorder(selected ? Ink.text : Ink.hairline, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(model.summary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The Accessibility list row you're looking for in System Settings.
private struct SettingsRowMock: View {
    let on: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
            Text("Murmur").font(.system(size: 13)).foregroundStyle(Ink.text)
            Spacer()
            Capsule()
                .fill(on ? Color.accentColor : Ink.hairline)
                .frame(width: 32, height: 19)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: on)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.key)
                .strokeBorder(Ink.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(on ? "Murmur is turned on in Accessibility settings" : "Murmur is off in Accessibility settings")
    }
}

/// The bottom-right corner of a Mac keyboard, with the right Option key lit while you hold it.
private struct KeyRow: View {
    let pressed: Bool
    let dim: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            Keycap(symbol: "⌘", word: "command", width: 70, faded: true)
            Keycap(symbol: "⌥", word: "option", width: 62, pressed: pressed, faded: dim)
            HStack(alignment: .bottom, spacing: 3) {
                Keycap(symbol: "◀︎", word: nil, width: 26, height: 22, faded: true)
                VStack(spacing: 2) {
                    Keycap(symbol: "▲", word: nil, width: 26, height: 22, faded: true)
                    Keycap(symbol: "▼", word: nil, width: 26, height: 22, faded: true)
                }
                Keycap(symbol: "▶︎", word: nil, width: 26, height: 22, faded: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pressed ? "Right Option key held, listening" : "Hold the right Option key, next to the right Command key")
    }
}

private struct Keycap: View {
    let symbol: String
    let word: String?
    var width: CGFloat
    var height: CGFloat = 46
    var pressed = false
    var faded = false

    var body: some View {
        ZStack {
            VStack(alignment: .trailing, spacing: 0) {
                Text(symbol).font(.system(size: word == nil ? 8 : 12, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: word == nil ? .center : .trailing)
                if let word {
                    Spacer(minLength: 0)
                    Text(word).font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, word == nil ? 0 : 7)
            .padding(.vertical, word == nil ? 0 : 6)
            .foregroundStyle(pressed ? Ink.paper : Ink.text)
        }
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(pressed ? Ink.text : Ink.key)
                .shadow(color: .black.opacity(pressed ? 0 : 0.18), radius: 0, y: pressed ? 0 : 1.5))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Ink.hairline.opacity(pressed ? 0 : 1)))
        .offset(y: pressed ? 1.5 : 0)
        .opacity(faded ? 0.4 : 1)
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: pressed)
    }
}

private struct LoadingBar: View {
    let progress: (fraction: Double?, message: String)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).tint(Ink.text)
            } else {
                ProgressView().progressViewStyle(.linear).tint(Ink.text)
            }
            Text(progress.message == "Starting…" ? "Getting the speech model ready…" : progress.message)
                .font(.system(size: 12)).foregroundStyle(Ink.secondary)
        }
        .frame(width: 260)
    }
}

private struct Shortcut: View {
    let keys: String
    let meaning: String

    init(_ keys: String, _ meaning: String) {
        self.keys = keys
        self.meaning = meaning
    }

    var body: some View {
        GridRow {
            Text(keys).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.text)
            Text(meaning).font(.system(size: 12.5)).foregroundStyle(Ink.secondary)
        }
    }
}

private struct StageRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            content
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .frame(height: 30)
    }
}

private struct StageLabel: View {
    let text: String
    var dim = false

    init(_ text: String, dim: Bool = false) {
        self.text = text
        self.dim = dim
    }

    var body: some View {
        Text(text).font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white.opacity(dim ? 0.55 : 0.9))
            .lineLimit(1)
    }
}

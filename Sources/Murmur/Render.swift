#if MURMUR_DEBUG_HOOKS
import AppKit
import SwiftUI

/// `Murmur --render-ui <dir>`: renders the onboarding steps, Settings, and notch states to PNGs
/// (2×, light and dark) for design review and the README. Development builds only.
@MainActor
enum Render {
    /// Fixed loudness history so rendered waves look like speech.
    static var demoLevels: [Float]?

    static func run(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        demoLevels = (0..<36).map { i in
            let t = Double(i) * 0.04
            return Float(max(0, sin(t * 9 + 1) * sin(t * 2.3 + 2)) * 0.85 + 0.08)
        }
        let controller = AppController()
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            for step in OnboardingView.Step.allCases {
                let text: String? = step == .practice
                    ? "Okay, so for the launch next week let's move the demo to Thursday." : nil
                let view = OnboardingView(controller: controller, step: step, practiceText: text) {}
                snapshot(view, size: OnboardingView.size, scheme: scheme,
                         to: dir.appendingPathComponent("onboarding-\(step.rawValue)-\(step)-\(suffix).png"))
                if step == .practice {
                    let waiting = OnboardingView(controller: controller, step: step) {}
                    snapshot(waiting, size: OnboardingView.size, scheme: scheme,
                             to: dir.appendingPathComponent("onboarding-4-practice-waiting-\(suffix).png"))
                }
            }
            snapshot(SettingsView(controller: controller, windows: Windows(controller: controller)),
                     size: CGSize(width: 520, height: 640), scheme: scheme,
                     to: dir.appendingPathComponent("settings-\(suffix).png"))
        }
        for state in ["recording", "locked", "transcribing", "result", "pasted"] {
            controller.preview(state)
            snapshot(HeroCorner(controller: controller), size: CGSize(width: 720, height: 360), scheme: .dark,
                     to: dir.appendingPathComponent("notch-\(state).png"))
        }
    }

    private static func snapshot<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, to url: URL) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        // cacheDisplay renders at 1×; redraw into a 2× bitmap for crisp images.
        let scale: CGFloat = 2
        guard let hi = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        hi.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: hi)
        host.displayIgnoringOpacity(host.bounds, in: NSGraphicsContext.current!)
        NSGraphicsContext.restoreGraphicsState()
        try? hi.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.lastPathComponent)")
        window.close()
    }
}

/// The bottom-right corner of a screen: a document being written, and the notch.
private struct HeroCorner: View {
    let controller: AppController

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(
                colors: [Color(red: 0.36, green: 0.40, blue: 0.47), Color(red: 0.16, green: 0.18, blue: 0.22)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    ForEach(0..<3) { _ in Circle().fill(.white.opacity(0.25)).frame(width: 11, height: 11) }
                }
                Text("Launch plan").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                Text("Demo moves to Thursday so the onboarding flow is done first.")
                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.75))
                Rectangle().fill(.white.opacity(0.9)).frame(width: 2, height: 18)
            }
            .padding(22)
            .frame(width: 420, height: 240, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.12)))
            .padding(.trailing, 250)
            .padding(.bottom, 70)
            NotchView(controller: controller)
                .frame(width: 600, height: 380)
        }
    }
}
#endif

import AppKit
import CoreAudio

/// Procedurally synthesized UI sounds, panned slightly toward the bottom-right notch.
/// - open: two tiny tactile ticks, the second brighter
/// - close: the same ticks falling back down
@MainActor
enum SoundFX {
    nonisolated private static let sampleRate = 48_000.0

    private static let openData = render(duration: 0.14, peak: 0.84, voice: ticks([
        Tick(start: 0.006, fc: 2800, gain: 0.8), Tick(start: 0.066, fc: 3800, gain: 1),
    ]))
    private static let closeData = render(duration: 0.14, peak: 0.84, voice: ticks([
        Tick(start: 0.006, fc: 3600, gain: 1), Tick(start: 0.056, fc: 2400, gain: 0.6),
    ]))
    private static let openSound = openData.flatMap { NSSound(data: $0) }
    private static let closeSound = closeData.flatMap { NSSound(data: $0) }

    static func open() { play(openSound) }

    /// Writes open.wav / close.wav (for `Murmur --export-sounds <dir>`).
    static func export(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = openData { try? d.write(to: dir.appendingPathComponent("open.wav")) }
        if let d = closeData { try? d.write(to: dir.appendingPathComponent("close.wav")) }
    }
    static func close() { play(closeSound) }

    private static func play(_ sound: NSSound?) {
        guard let sound, let volume = FixedLevel.playbackVolume() else { return }
        sound.stop()
        sound.volume = volume
        sound.play()
    }

    // MARK: - Voices

    /// Returns (left, right) for sample n.
    private typealias Renderer = (_ n: Int, _ count: Int, _ state: inout DSP) -> (Float, Float)

    private struct Tick {
        let start: Double
        let fc: Double
        let gain: Double
    }

    /// Haptic ticks: a resonant band-passed noise click over a tiny falling thump, like a trackpad click.
    private static func ticks(_ ticks: [Tick]) -> Renderer {
        { n, _, s in
            let t = Double(n) / sampleRate
            let noise = s.noise()
            var x = 0.0
            for (i, tick) in ticks.enumerated() {
                let tt = t - tick.start
                let excite = tt >= 0 ? noise * softEnv(tt, attack: 0.0004, decay: 0.0025) : 0
                x += tick.gain * 0.8 * s.filters[i].process(excite, fc: tick.fc, q: 2.5)
                if tt >= 0 {
                    let thump = sin(sweepPhase(tt, from: 220, to: 120, over: 0.012))
                    x += tick.gain * 0.5 * thump * softEnv(tt, attack: 0.0008, decay: 0.01)
                }
            }
            return pan(x, x, 0.25)
        }
    }

    /// Phase of an exponential sweep from `f0` to `f1` over `duration`, then holding at `f1`.
    private static func sweepPhase(_ t: Double, from f0: Double, to f1: Double, over duration: Double) -> Double {
        let lk = log(f1 / f0)
        if t < duration { return 2 * .pi * f0 * duration * (exp(lk * t / duration) - 1) / lk }
        return 2 * .pi * (f0 * duration * (f1 / f0 - 1) / lk + f1 * (t - duration))
    }

    /// Raised-cosine attack into an exponential decay: no clicks, no edge.
    private static func softEnv(_ t: Double, attack: Double, decay: Double) -> Double {
        guard t >= 0 else { return 0 }
        let a = t < attack ? 0.5 - 0.5 * cos(.pi * t / attack) : 1
        return a * exp(-max(0, t - attack) / decay)
    }

    // MARK: - Rendering

    private static func render(duration: Double, peak: Float, voice: Renderer) -> Data? {
        let count = Int(duration * sampleRate)
        var state = DSP()
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        var maxAmp: Float = 0
        for n in 0..<count {
            let (l, r) = voice(n, count, &state)
            left[n] = l
            right[n] = r
            maxAmp = max(maxAmp, abs(l), abs(r))
        }
        // Normalize, with a 4 ms fade at both ends to avoid clicks.
        let gain = maxAmp > 0 ? peak / maxAmp : 1
        let fade = Int(0.004 * sampleRate)
        var pcm = Data(capacity: count * 4)
        for n in 0..<count {
            let edge = Float(min(n, count - 1 - n, fade)) / Float(fade)
            for v in [left[n], right[n]] {
                let s = Int16(max(-1, min(1, v * gain * edge)) * Float(Int16.max))
                withUnsafeBytes(of: s.littleEndian) { pcm.append(contentsOf: $0) }
            }
        }
        return wav(pcm)
    }

    private static func wav(_ pcm: Data) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + UInt32(pcm.count))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }

    /// Equal-power pan of a stereo pair; position 0 = center, 1 = hard right.
    private static func pan(_ l: Double, _ r: Double, _ position: Double) -> (Float, Float) {
        let a = (position + 1) * .pi / 4
        return (Float(l * cos(a) * 1.414), Float(r * sin(a) * 1.414))
    }

    private static func smoothstep(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    // MARK: - DSP state

    private struct DSP {
        var seed: UInt32 = 0xC0FFEE
        var filters = [BandPass(), BandPass()]

        mutating func noise() -> Double {
            seed ^= seed << 13
            seed ^= seed >> 17
            seed ^= seed << 5
            return Double(seed) / Double(UInt32.max) * 2 - 1
        }
    }

    /// Topology-preserving state-variable band-pass (unity peak gain).
    private struct BandPass {
        var ic1 = 0.0
        var ic2 = 0.0

        mutating func process(_ x: Double, fc: Double, q: Double) -> Double {
            let g = tan(.pi * min(fc, sampleRate * 0.45) / sampleRate)
            let k = 1 / q
            let a1 = 1 / (1 + g * (g + k))
            let a2 = g * a1
            let a3 = g * a2
            let v3 = x - ic2
            let v1 = a1 * ic1 + a2 * v3
            let v2 = ic2 + a2 * ic1 + a3 * v3
            ic1 = 2 * v1 - ic1
            ic2 = 2 * v2 - ic2
            return v1 * k
        }
    }
}

/// Keeps UI sounds at one faint absolute loudness no matter where the system volume slider is:
/// reads the output device's current attenuation and scales playback to cancel it out.
private enum FixedLevel {
    /// Target level below the device's full output, in dB. Lower = fainter.
    static let targetDecibels: Float = -40

    /// nil when the output is muted.
    static func playbackVolume() -> Float? {
        guard let device = defaultOutputDevice() else { return 0.2 }
        if isMuted(device) { return nil }
        let deviceDB = volumeDecibels(device) ?? virtualVolume(device).map { 40 * log10(max($0, 0.001)) }
        guard let deviceDB else { return 0.2 }
        return min(1, pow(10, (targetDecibels - deviceDB) / 20))
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let ok = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return ok == noErr && id != 0 ? id : nil
    }

    private static func isMuted(_ device: AudioDeviceID) -> Bool {
        var muted: UInt32 = 0
        return read(device, kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain, into: &muted) && muted != 0
    }

    /// Main (or loudest channel) attenuation in dB; 0 = full volume.
    private static func volumeDecibels(_ device: AudioDeviceID) -> Float? {
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var db: Float32 = 0
            if read(device, kAudioDevicePropertyVolumeDecibels, element: element, into: &db) { return db }
        }
        return nil
    }

    /// Fallback for devices without dB controls (e.g. some Bluetooth): the 0...1 slider value.
    private static func virtualVolume(_ device: AudioDeviceID) -> Float? {
        var v: Float32 = 0
        let selector = AudioObjectPropertySelector(0x766D_7663)  // 'vmvc' VirtualMainVolume
        return read(device, selector, element: kAudioObjectPropertyElementMain, into: &v) ? v : nil
    }

    private static func read<T: BitwiseCopyable>(
        _ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, element: UInt32, into value: inout T
    ) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr
    }
}

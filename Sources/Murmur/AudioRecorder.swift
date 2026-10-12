import AVFoundation
import CoreAudio
import Foundation
import os

/// Captures the microphone, converts to 16 kHz mono Float32, and hands chunks to the
/// transcriber while keeping the full recording for the final pass.
final class AudioRecorder: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let lock = OSAllocatedUnfairLock(initialState: [Float]())

    /// Called on the audio thread with a 0...1 loudness value per buffer.
    var onLevel: (@Sendable (Float) -> Void)?

    var isRunning: Bool { engine?.isRunning ?? false }
    private var engineDeviceUID: String?
    private var needsRebuild = false
    private var configObserver: NSObjectProtocol?
    private var startedAt = Date()
    private var sawFirstBuffer = false

    /// Starts capture. The engine is built once and paused between dictations so restarts are fast.
    func start(deviceUID: String?) throws {
        lock.withLock { $0.removeAll(keepingCapacity: true) }
        startedAt = Date()
        sawFirstBuffer = false

        if engine == nil || needsRebuild || engineDeviceUID != deviceUID {
            try buildEngine(deviceUID: deviceUID)
        }
        converter?.reset()
        do {
            try engine?.start()
        } catch {
            // Device went away or changed under us: rebuild once and retry.
            try buildEngine(deviceUID: deviceUID)
            try engine?.start()
        }
    }

    /// Stops capture and returns the whole recording at 16 kHz.
    func stop() -> [Float] {
        engine?.pause()
        return lock.withLock { samples in
            defer { samples.removeAll() }
            return samples
        }
    }

    private func buildEngine(deviceUID: String?) throws {
        teardown()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid = deviceUID, let id = AudioDevices.deviceID(forUID: uid), let unit = input.audioUnit {
            var deviceID = id
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
            let converter = AVAudioConverter(from: inputFormat, to: target)
        else {
            throw RecorderError.noInput
        }
        self.converter = converter

        let ratio = target.sampleRate / inputFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer, ratio: ratio)
        }
        engine.prepare()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.needsRebuild = true
        }
        self.engine = engine
        engineDeviceUID = deviceUID
        needsRebuild = false
    }

    private func teardown() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        converter = nil
    }

    private func handle(_ buffer: AVAudioPCMBuffer, ratio: Double) {
        if !sawFirstBuffer {
            sawFirstBuffer = true
            Log.info(String(format: "mic: first buffer after %.0f ms", Date().timeIntervalSince(startedAt) * 1000))
        }
        onLevel?(Self.level(of: buffer))

        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let data = out.floatChannelData else { return }
        let chunk = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        lock.withLock { $0.append(contentsOf: chunk) }
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        let ch = data[0]
        for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = sqrt(sum / Float(n))
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db + 62) / 42, 0), 1)
    }

    enum RecorderError: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone input available" }
    }
}

/// Input-device enumeration for the microphone picker.
enum AudioDevices {
    struct Device: Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    static func inputDevices() -> [Device] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                let name = string(id, kAudioObjectPropertyName)
            else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.uid == uid }?.id
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

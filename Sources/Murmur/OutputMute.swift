import CoreAudio
import Foundation

/// Silences the Mac's sound output while you dictate, then puts it back the way it was.
/// Uses the output device's mute switch, or its volume on devices without one (some HDMI and
/// Bluetooth outputs). What to restore is saved before anything changes, so if Murmur quits
/// mid-dictation the next launch undoes it.
@MainActor
enum OutputMute {
    private static let restoreKey = "outputMuteRestore"

    /// Mutes the current output device, unless it's already silent.
    static func engage() {
        guard UserDefaults.standard.dictionary(forKey: restoreKey) == nil,
            let device = OutputDevice.current(),
            let uid = AudioDevices.string(device, kAudioDevicePropertyDeviceUID)
        else { return }
        if OutputDevice.isSettable(device, kAudioDevicePropertyMute) {
            let muted: UInt32? = OutputDevice.read(device, kAudioDevicePropertyMute)
            guard muted == 0 else { return }
            UserDefaults.standard.set(["uid": uid], forKey: restoreKey)
            if !OutputDevice.write(device, kAudioDevicePropertyMute, UInt32(1)) { forget() }
        } else if OutputDevice.isSettable(device, OutputDevice.virtualMainVolume) {
            let volume: Float32? = OutputDevice.read(device, OutputDevice.virtualMainVolume)
            guard let volume, volume > 0 else { return }
            UserDefaults.standard.set(["uid": uid, "volume": volume], forKey: restoreKey)
            if !OutputDevice.write(device, OutputDevice.virtualMainVolume, Float32(0)) { forget() }
        }
    }

    /// Undoes `engage()`, including one left over from a previous run.
    static func release() {
        guard let saved = UserDefaults.standard.dictionary(forKey: restoreKey) else { return }
        forget()
        guard let uid = saved["uid"] as? String, let device = OutputDevice.withUID(uid) else { return }
        if let volume = (saved["volume"] as? NSNumber)?.floatValue {
            // Leave it alone if the volume was turned up in the meantime.
            let current: Float32? = OutputDevice.read(device, OutputDevice.virtualMainVolume)
            if current == 0 { OutputDevice.write(device, OutputDevice.virtualMainVolume, volume) }
        } else {
            OutputDevice.write(device, kAudioDevicePropertyMute, UInt32(0))
        }
    }

    private static func forget() { UserDefaults.standard.removeObject(forKey: restoreKey) }
}

/// Main-element properties of sound output devices.
enum OutputDevice {
    /// 'vmvc' VirtualMainVolume: the 0...1 volume slider, also on devices without dB or mute controls.
    static let virtualMainVolume = AudioObjectPropertySelector(0x766D_7663)

    /// The system's default output device.
    static func current() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let ok = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return ok == noErr && id != 0 ? id : nil
    }

    static func withUID(_ uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let ok = withUnsafePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), qualifier,
                &size, &id)
        }
        return ok == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func read<T: BitwiseCopyable & Numeric>(
        _ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
        element: UInt32 = kAudioObjectPropertyElementMain
    ) -> T? {
        var addr = address(selector, element)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func isSettable(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Bool {
        var addr = address(selector, kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &addr)
            && AudioObjectIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue
    }

    @discardableResult
    static func write<T: BitwiseCopyable>(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ value: T)
        -> Bool
    {
        var addr = address(selector, kAudioObjectPropertyElementMain)
        var value = value
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }
}

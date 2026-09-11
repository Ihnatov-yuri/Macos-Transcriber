import Foundation
@preconcurrency import AVFoundation
import CoreAudio

/// Enumerate and resolve microphones, so capture doesn't have to mean
/// "whatever macOS currently calls the default input".
///
/// The app had no say in this before: `AVAudioEngine.inputNode` and
/// `MeetingRecorder`'s aggregate both took the system default. That is fine
/// until the default is a Bluetooth headset or soundbar — opening its
/// microphone drops the link from A2DP to the hands-free profile, and the
/// device's OUTPUT collapses to mono at 16 kHz along with it, for everything
/// the Mac is playing, for as long as the input stays open. That is a
/// property of Bluetooth, not a bug we can code around: A2DP is one-way, so
/// a headset cannot send a microphone stream and receive stereo at once.
/// The only real fix is to capture from something else — which needs a way
/// to say so.
enum AudioInputDevices {

    struct Device: Identifiable, Hashable, Sendable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        /// Bluetooth devices are listed, and pickable — someone on AirPods
        /// with nothing else to hand still needs to dictate — but the UI
        /// marks them, because choosing one costs that device's playback
        /// quality for as long as capture is open.
        let isBluetooth: Bool
        /// A loopback / virtual driver (BlackHole, a conferencing app's audio
        /// device) rather than a microphone. These expose input channels, so
        /// they turn up in any naive scan, but nobody means them when they
        /// pick "which mic". Kept in the model — silently hiding a device
        /// somebody deliberately installed, and then failing to resolve their
        /// stored choice, is worse — but listed apart from real hardware.
        let isVirtual: Bool
        /// Whether the device also has output channels. Decides which of the
        /// two routes in `apply` is available — and so whether selecting it
        /// can avoid opening the system default input at all.
        let hasOutput: Bool
    }

    // MARK: - Enumeration

    /// Every device with at least one input channel, in CoreAudio's order.
    static func available() -> [Device] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { device(for: $0) }.filter { $0.inputChannels > 0 }.map(\.device)
    }

    /// Real microphones: hardware that captures sound. What a "which mic"
    /// picker should offer.
    static func microphones() -> [Device] { available().filter { !$0.isVirtual } }

    /// Loopback and virtual drivers with input channels. Selectable, but
    /// listed separately — picking one records what the Mac is playing, not
    /// a room.
    static func loopbacks() -> [Device] { available().filter(\.isVirtual) }

    /// The device a stored UID refers to, or nil when it has been unplugged.
    static func resolve(uid: String?) -> Device? {
        guard let uid, !uid.isEmpty else { return nil }
        return available().first { $0.uid == uid }
    }

    /// The current system default input.
    static func systemDefault() -> Device? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &id) == noErr,
              id != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device(for: id)?.device
    }

    /// The device capture will actually use: the stored choice when it is
    /// still present, otherwise the system default. A device that vanished
    /// (headset switched off, dock unplugged) silently falls back rather than
    /// failing to record — losing a recording is worse than using a
    /// different mic.
    static func effective(uid: String?) -> Device? {
        resolve(uid: uid) ?? systemDefault()
    }

    /// Point an engine at the chosen microphone. Call BEFORE anything else
    /// touches `engine.inputNode`.
    ///
    /// Two routes, because AVAudioEngine gives us no good one. On macOS a
    /// single audio unit is shared between an engine's input and output
    /// nodes, and it starts out pointed at the default OUTPUT device, which
    /// is harmless. Reaching for `inputNode` is what binds and OPENS the
    /// current default input — measured: a Soundcore Motion+ dropped from
    /// 44.1 kHz stereo to 16 kHz mono on the `engine.inputNode` line itself,
    /// before any device could be chosen, and setting the device afterwards
    /// did not hand the profile back.
    ///
    /// So try `outputNode` first, which reaches the same audio unit without
    /// opening any input. That only works for devices that also have output
    /// channels — an input-only device (the built-in mic, most USB mics)
    /// answers -10851. For those there is no way around binding `inputNode`
    /// first and accepting that the default input is opened in passing;
    /// `Capture` keeps that window as short as it can.
    @discardableResult
    static func apply(uid: String?, to engine: AVAudioEngine) -> Device? {
        guard let device = resolve(uid: uid) else { return systemDefault() }
        if (try? engine.outputNode.auAudioUnit.setDeviceID(device.id)) != nil {
            AppLog.info("audio", "capturing from '\(device.name)' (no default input opened)")
            return device
        }
        do {
            try engine.inputNode.auAudioUnit.setDeviceID(device.id)
            AppLog.info("audio", "capturing from '\(device.name)' (input-only device — the system default was opened in passing)")
            return device
        } catch {
            AppLog.warn("audio", "could not select input '\(device.name)': \(error.localizedDescription) — falling back to the system default")
            return systemDefault()
        }
    }

    /// Whether opening capture right now would drag a Bluetooth link into
    /// hands-free mode: either the chosen microphone is Bluetooth, or it is
    /// input-only and the system default — which gets opened on the way past
    /// — is Bluetooth.
    static func captureWouldDisturbBluetooth(uid: String?) -> Bool {
        guard let device = effective(uid: uid) else { return false }
        if device.isBluetooth { return true }
        // A device with output channels can be selected through `outputNode`,
        // which never opens the default input — so what the default happens
        // to be doesn't matter.
        if device.hasOutput { return false }
        return systemDefault()?.isBluetooth == true
    }

    /// Watches CoreAudio's device list so a settings picker reflects a
    /// headset switching off, or a dock being plugged in, without the user
    /// having to reopen the window.
    @MainActor
    final class Watcher {
        private var block: AudioObjectPropertyListenerBlock?
        private var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        func start(_ onChange: @escaping @MainActor () -> Void) {
            guard block == nil else { return }
            let handler: AudioObjectPropertyListenerBlock = { _, _ in
                Task { @MainActor in onChange() }
            }
            block = handler
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, handler)
        }

        func stop() {
            guard let block else { return }
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
            self.block = nil
        }
    }

    // MARK: - Per-device properties

    private static func device(for id: AudioDeviceID) -> (device: Device, inputChannels: Int)? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = string(id, kAudioObjectPropertyName) ?? uid
        let transport = transportType(id)
        return (Device(id: id, uid: uid, name: name,
                       isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                                 || transport == kAudioDeviceTransportTypeBluetoothLE,
                       isVirtual: transport == kAudioDeviceTransportTypeVirtual
                               || transport == kAudioDeviceTransportTypeAggregate,
                       hasOutput: channels(id, scope: kAudioDevicePropertyScopeOutput) > 0),
                channels(id, scope: kAudioDevicePropertyScopeInput))
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport) == noErr
        else { return 0 }
        return transport
    }

    private static func channels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let lists = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return lists.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value as String
    }
}

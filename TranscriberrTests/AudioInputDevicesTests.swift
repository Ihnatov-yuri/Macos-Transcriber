import XCTest
@testable import Transcriberr

/// Which microphone capture ends up on, decided from made-up device lists:
/// no test machine has a USB mic, a Bluetooth headset, a loopback driver and
/// the Transcriberr Microphone plugged in at once. No audio device is opened.
final class AudioInputDevicesTests: XCTestCase {

    private typealias Device = AudioInputDevices.Device

    private func device(_ id: UInt32, _ name: String, bluetooth: Bool = false,
                        virtual: Bool = false, output: Bool = false, uid: String? = nil) -> Device {
        Device(id: id, uid: uid ?? "uid-\(id)", name: name,
               isBluetooth: bluetooth, isVirtual: virtual, hasOutput: output)
    }

    private var builtIn: Device { device(1, "MacBook Pro Microphone") }
    private var usbMic: Device { device(2, "Anker PowerConf CN") }
    private var speakerphone: Device { device(3, "Jabra Speak", output: true) }
    private var airpods: Device { device(4, "AirPods", bluetooth: true, output: true) }
    private var loopback: Device { device(5, "BlackHole 2ch", virtual: true, output: true) }

    // MARK: - Routes (v5.7.2)

    /// v5.7.2: an input-only microphone offered to the output side answered
    /// -10851 and left the audio unit bound to no device, so the input side
    /// failed too and capture delivered no audio.
    func testInputOnlyDeviceIsNeverTriedOnTheOutputSide() {
        XCTAssertEqual(AudioInputDevices.routes(for: builtIn), [.input])
        XCTAssertEqual(AudioInputDevices.routes(for: usbMic), [.input])
    }

    /// The output side first for a device that has one: it does not open the
    /// system default input (a Bluetooth default would drop to hands-free).
    func testDeviceWithOutputTriesTheOutputSideFirstThenTheInputSide() {
        XCTAssertEqual(AudioInputDevices.routes(for: speakerphone), [.output, .input])
        XCTAssertEqual(AudioInputDevices.routes(for: airpods), [.output, .input])
    }

    /// Every device has a route, and the input side is always the last one.
    func testEveryDeviceEndsOnTheInputSide() {
        for d in [builtIn, usbMic, speakerphone, airpods, loopback] {
            XCTAssertEqual(AudioInputDevices.routes(for: d).last, .input, d.name)
        }
    }

    // MARK: - What a picker offers

    func testSelectableLeavesOutOutputOnlyDevicesOurOwnMicAndTheSystemAggregate() {
        let speakers = device(10, "MacBook Pro Speakers", output: true)
        let ours = device(11, "Transcriberr Microphone", virtual: true, uid: VirtualMicrophone.micUID)
        let aggregate = device(12, "CADefaultDeviceAggregate-1234-0", virtual: true)
        let found = AudioInputDevices.selectable([
            (speakers, 0), (builtIn, 1), (ours, 1), (aggregate, 2), (loopback, 2), (airpods, 1),
        ])
        XCTAssertEqual(found, [builtIn, loopback, airpods], "CoreAudio's order is kept")
    }

    // MARK: - Stored choice

    func testResolveFindsTheStoredDeviceByUID() {
        XCTAssertEqual(AudioInputDevices.resolve(uid: "uid-2", in: [builtIn, usbMic]), usbMic)
    }

    func testResolveIsNilForNoChoiceAnEmptyChoiceAndAnUnpluggedDevice() {
        XCTAssertNil(AudioInputDevices.resolve(uid: nil, in: [builtIn]))
        XCTAssertNil(AudioInputDevices.resolve(uid: "", in: [builtIn]))
        XCTAssertNil(AudioInputDevices.resolve(uid: "uid-2", in: [builtIn]), "the USB mic was unplugged")
        XCTAssertNil(AudioInputDevices.resolve(uid: "uid-1", in: []))
    }

    /// Two units of one model show the same name; the UID tells them apart.
    func testResolveTellsTwoDevicesWithOneNameApart() {
        let first = device(20, "USB Audio Device", uid: "usb-A")
        let second = device(21, "USB Audio Device", uid: "usb-B")
        XCTAssertEqual(AudioInputDevices.resolve(uid: "usb-B", in: [first, second]), second)
    }

    // MARK: - The mic behind the Transcriberr Microphone

    func testMicBehindOursPrefersTheBuiltInOne() {
        let found = AudioInputDevices.micBehindOurs([usbMic, builtIn]) { $0.id == 1 }
        XCTAssertEqual(found, builtIn)
    }

    func testMicBehindOursTakesTheFirstMicWhenThereIsNoBuiltInOne() {
        XCTAssertEqual(AudioInputDevices.micBehindOurs([usbMic, speakerphone]) { _ in false }, usbMic)
    }

    func testMicBehindOursIsNilWithNoMicrophones() {
        XCTAssertNil(AudioInputDevices.micBehindOurs([]) { _ in true })
    }

    // MARK: - Bluetooth

    func testABluetoothMicAlwaysDisturbsItsOwnLink() {
        XCTAssertTrue(AudioInputDevices.wouldDisturbBluetooth(effective: airpods, systemDefault: builtIn))
    }

    /// An input-only mic is bound through the input side, which opens the
    /// system default in passing.
    func testAnInputOnlyMicDisturbsABluetoothDefault() {
        XCTAssertTrue(AudioInputDevices.wouldDisturbBluetooth(effective: usbMic, systemDefault: airpods))
        XCTAssertFalse(AudioInputDevices.wouldDisturbBluetooth(effective: usbMic, systemDefault: builtIn))
        XCTAssertFalse(AudioInputDevices.wouldDisturbBluetooth(effective: usbMic, systemDefault: nil))
    }

    func testADeviceWithOutputLeavesABluetoothDefaultAlone() {
        XCTAssertFalse(AudioInputDevices.wouldDisturbBluetooth(effective: speakerphone, systemDefault: airpods))
    }

    func testNoDeviceDisturbsNothing() {
        XCTAssertFalse(AudioInputDevices.wouldDisturbBluetooth(effective: nil, systemDefault: airpods))
    }
}

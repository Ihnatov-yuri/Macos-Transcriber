import Foundation
import IOKit.pwr_mgt

/// macOS equivalent of `WakeLockHelper.kt`. While the assertion is held the
/// system does not idle-sleep; the display may still dim and sleep, which is
/// right for a long transcription nobody is watching. `JobManager` holds it
/// while its queue has work.
@MainActor
final class IdleAssertion {
    private var assertionID: IOPMAssertionID = 0
    private var held = false

    func acquire(reason: String) {
        guard !held else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        held = (result == kIOReturnSuccess)
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(assertionID)
        held = false
    }

    deinit { if held { IOPMAssertionRelease(assertionID) } }
}

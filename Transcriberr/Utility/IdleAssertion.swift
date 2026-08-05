import Foundation
import IOKit.pwr_mgt

/// macOS equivalent of `KeepScreenOn.kt` + `WakeLockHelper.kt`.
/// While the assertion is held, the system won't dim the display or sleep.
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

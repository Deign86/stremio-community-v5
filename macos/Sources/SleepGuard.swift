import Foundation
import IOKit.pwr_mgt

/// Keeps the display and the Mac awake while a video plays. With vo=libmpv, mpv's
/// own stop-screensaver does nothing, so without this macOS dims and sleeps mid-video.
final class SleepGuard {
    private var assertions: [IOPMAssertionID] = []

    func set(active: Bool) {
        if active == !assertions.isEmpty { return }
        if active {
            // Display: no dimming, display sleep or screensaver. System: no idle sleep.
            for type in [kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionTypePreventUserIdleSystemSleep] {
                var id = IOPMAssertionID(0)
                let rc = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "\(AppInfo.name) is playing video" as CFString, &id)
                if rc == kIOReturnSuccess {
                    assertions.append(id)
                } else {
                    Log.error("[APP]: Could not create \(type) assertion (\(rc))")
                }
            }
        } else {
            assertions.forEach { IOPMAssertionRelease($0) }
            assertions.removeAll()
        }
    }
}

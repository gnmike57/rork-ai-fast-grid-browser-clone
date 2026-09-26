import Foundation
import Testing
@testable import FastBrowserv4

/// Regression suite for the run cockpit: speed-math bounds, pause/freeze
/// state, site-pacing learning caps, and the cross-credential guard.
struct CockpitRegressionTests {

    // MARK: - Speed math stays inside watchdog bounds

    @Test
    func watchdogNeverShrinksAtAnyProfile() {
        let base = Duration.seconds(12)
        for profile in SpeedProfile.allCases {
            let effective = SpeedProfile.effectiveWatchdog(base, profile: profile)
            #expect(effective >= base, "\(profile.label) shrunk the watchdog")
        }
    }

    @Test
    func slowProfileStretchesWatchdog() {
        let base = Duration.seconds(12)
        let slow = SpeedProfile.effectiveWatchdog(base, profile: .slow)
        #expect(slow > base)
        let turbo = SpeedProfile.effectiveWatchdog(base, profile: .turbo)
        #expect(turbo == base)
    }

    @Test
    func scaledSettleStaysPositiveAndOrdered() {
        let base = 2.0
        let slow = SpeedProfile.scaledSettle(baseSeconds: base, profile: .slow)
        let normal = SpeedProfile.scaledSettle(baseSeconds: base, profile: .normal)
        let fast = SpeedProfile.scaledSettle(baseSeconds: base, profile: .fast)
        let turbo = SpeedProfile.scaledSettle(baseSeconds: base, profile: .turbo)
        #expect(slow > normal)
        #expect(normal == base)
        #expect(fast < normal)
        #expect(turbo < fast)
        #expect(turbo > 0)
    }

    @Test
    func submitGapMultiplierOrdering() {
        #expect(SpeedProfile.slow.submitGapMultiplier > 1)
        #expect(SpeedProfile.normal.submitGapMultiplier == 1)
        #expect(SpeedProfile.fast.submitGapMultiplier < 1)
        #expect(SpeedProfile.turbo.submitGapMultiplier < SpeedProfile.fast.submitGapMultiplier)
        #expect(SpeedProfile.turbo.submitGapMultiplier > 0.1)
    }

    // MARK: - Site-pacing learning caps

    @Test
    func pacingLearningCapsAtBounds() {
        // A pathological current value clamps into the learnable range.
        let fromZero = SitePacingStore.learnedEstimate(current: 0, observed: 0.01)
        #expect(fromZero >= SitePacingStore.minSettleSeconds)
        // A pathological observed value (huge) can never blow past the cap.
        let fromHuge = SitePacingStore.learnedEstimate(current: 12, observed: 10_000)
        #expect(fromHuge <= SitePacingStore.maxSettleSeconds)
        // Normal EMA math: 2 + 0.3 * (4 - 2) = 2.6
        let learned = SitePacingStore.learnedEstimate(current: 2, observed: 4)
        #expect(abs(learned - 2.6) < 0.000_1)
    }

    @Test
    func clampHelperBounds() {
        #expect(SitePacingStore.clamp(-5, 0, 1) == 0)
        #expect(SitePacingStore.clamp(0.5, 0, 1) == 0.5)
        #expect(SitePacingStore.clamp(9, 0, 1) == 1)
    }

    // MARK: - Cross-credential guard

    @Test
    func passwordListBelongsOnlyWhenIDsMatch() {
        #expect(BrowserViewModel.passwordListBelongs(to: "cred-A", listCredentialID: "cred-A"))
        #expect(!BrowserViewModel.passwordListBelongs(to: "cred-A", listCredentialID: "cred-B"))
        #expect(!BrowserViewModel.passwordListBelongs(to: "cred-A", listCredentialID: ""))
        #expect(!BrowserViewModel.passwordListBelongs(to: "", listCredentialID: "cred-A"))
    }

    // MARK: - Freeze / pause state

    @Test @MainActor
    func freezeTogglesPerWindow() {
        let controller = QuadController()
        let session = controller.sessions[0]
        #expect(!session.isRCRFrozen)
        controller.setSessionFrozen(session, true)
        #expect(session.isRCRFrozen)
        controller.setSessionFrozen(session, false)
        #expect(!session.isRCRFrozen)
    }

    @Test @MainActor
    func stopClearsFrozenWindows() {
        let controller = QuadController()
        let session = controller.sessions[0]
        controller.setSessionFrozen(session, true)
        controller.stopQuadRCR()
        #expect(!session.isRCRFrozen)
    }

    @Test
    func speedProfilePersists() {
        SpeedProfile.saved = .turbo
        #expect(SpeedProfile.saved == .turbo)
        SpeedProfile.saved = .normal
        #expect(SpeedProfile.saved == .normal)
    }
}

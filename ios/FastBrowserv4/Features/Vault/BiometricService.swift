import LocalAuthentication
import Foundation

@Observable
@MainActor
class BiometricService {
    var isUnlocked: Bool = false
    var biometricType: LABiometryType = .none

    func checkBiometricAvailability() {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            biometricType = context.biometryType
        } else {
            biometricType = .none
        }
    }

    func authenticate() async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Use Passcode"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No biometric AND no device passcode configured — there is no
            // stronger lock available on this device. Permanently stranding
            // the user outside their own vault with no way back in would be
            // strictly worse than proceeding unlocked, so let them in.
            isUnlocked = true
            return true
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock Sitch AI Browser to access your credentials"
            )
            isUnlocked = success
            return success
        } catch {
            isUnlocked = false
            return false
        }
    }

    func lock() {
        isUnlocked = false
    }

    var biometricName: String {
        switch biometricType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        case .none: return "Device Passcode"
        @unknown default: return "Biometrics"
        }
    }
}

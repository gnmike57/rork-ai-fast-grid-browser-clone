import SwiftUI
import LocalAuthentication

struct LockScreenView: View {
    let biometricService: BiometricService
    @State private var isAuthenticating: Bool = false
    @State private var showError: Bool = false
    @State private var pulseCount: Int = 0

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "bolt.shield.fill")
                .font(.system(size: 72))
                .foregroundStyle(.linearGradient(
                    colors: [Cockpit.live, Cockpit.live.opacity(0.5)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .symbolEffect(.bounce, value: pulseCount)

            VStack(spacing: 8) {
                Text("Sitch AI Browser")
                    .font(.title.bold())

                Text("Unlock to access your credentials")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                authenticate()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: biometricIcon)
                    Text("Unlock with \(biometricService.biometricName)")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(Cockpit.live)
            .padding(.horizontal, 32)
            .disabled(isAuthenticating)

            if showError {
                Text("Authentication failed. Try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }

            Spacer()
                .frame(height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .task {
            biometricService.checkBiometricAvailability()
            authenticate()
        }
    }

    private var biometricIcon: String {
        switch biometricService.biometricType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        case .none: return "lock"
        @unknown default: return "lock"
        }
    }

    private func authenticate() {
        isAuthenticating = true
        showError = false
        pulseCount += 1

        Task {
            let success = await biometricService.authenticate()
            isAuthenticating = false
            if !success {
                withAnimation { showError = true }
            }
        }
    }
}

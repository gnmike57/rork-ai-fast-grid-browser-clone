import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var biometricService = BiometricService()

    var body: some View {
        // BrowserView stays in the hierarchy at all times so locking never
        // destroys its @State (tabs, web views, in-flight RCR runs). When
        // locked, an opaque cover blocks interaction and visibility instead.
        ZStack {
            BrowserView()

            if !biometricService.isUnlocked {
                LockScreenView(biometricService: biometricService)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: biometricService.isUnlocked)
        .onChange(of: scenePhase) { _, newPhase in
            // Lock only on a real background transition. `.inactive` fires
            // for Control Center / notification peeks and must not nuke
            // the session.
            if newPhase == .background {
                biometricService.lock()
            }
            // Diagnostics polling has no value while nobody can see the
            // overlay — pause it the moment the app leaves the foreground.
            WindowDiagnosticsService.shared.setAppActive(newPhase == .active)
        }
    }
}

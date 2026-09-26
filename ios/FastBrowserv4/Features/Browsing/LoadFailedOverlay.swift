import SwiftUI

/// Shown over a tab or grid cell whose last navigation failed (offline,
/// DNS, dead host) instead of leaving it blank forever. Tapping anywhere
/// on the overlay retries the load.
struct LoadFailedOverlay: View {
    var compact: Bool = false
    let onRetry: () -> Void

    var body: some View {
        Button(action: onRetry) {
            VStack(spacing: compact ? 4 : 8) {
                Image(systemName: "wifi.exclamationmark")
                    .font(compact ? .title3 : .largeTitle)
                Text("Couldn't load — tap to retry")
                    .font(compact ? .system(size: 9, weight: .semibold) : .subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .padding(compact ? 10 : 20)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: compact ? 10 : 16))
        }
        .buttonStyle(.plain)
    }
}

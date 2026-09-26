import SwiftUI

/// Shown once on launch when a layout was saved before the app last left
/// the foreground. Accepting restores the exact grid size, windows and
/// pages; dismissing starts clean and clears the offer either way.
struct RestoreSessionCard: View {
    let snapshot: LastSessionSnapshot
    let onRestore: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title3)
                    .foregroundStyle(Cockpit.live)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restore last session?")
                        .font(.subheadline.weight(.bold))
                    Text(snapshot.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button("Start Fresh", action: onDismiss)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                Button("Restore", action: onRestore)
                    .buttonStyle(.borderedProminent)
                    .tint(Cockpit.live)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }
}

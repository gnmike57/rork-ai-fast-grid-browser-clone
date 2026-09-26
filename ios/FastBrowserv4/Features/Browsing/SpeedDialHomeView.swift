import SwiftUI

/// The browser home page: a speed-dial grid of shortcuts plus an edit tile.
struct SpeedDialHomeView: View {
    let onOpen: (SpeedDialEntry) -> Void

    private let store = SpeedDialStore.shared
    @State private var isEditing = false

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    private static let palette: [Color] = [Cockpit.live, .indigo, .orange, .mint, .pink, .purple, .teal, .blue]

    var body: some View {
        ZStack {
            background
            ScrollView {
                VStack(spacing: 32) {
                    header
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                            SpeedDialTile(
                                entry: entry,
                                accent: Self.palette[index % Self.palette.count],
                                action: { onOpen(entry) }
                            )
                        }
                        editTile
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.top, 48)
                .padding(.bottom, 40)
            }
        }
        .sheet(isPresented: $isEditing) {
            SpeedDialEditView()
        }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            Color(.systemBackground)
            RadialGradient(
                colors: [Cockpit.live.opacity(0.18), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 440
            )
            RadialGradient(
                colors: [.blue.opacity(0.15), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 480
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.shield.fill")
                .font(.system(size: 46))
                .foregroundStyle(.linearGradient(
                    colors: [Cockpit.live, Cockpit.live.opacity(0.5)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .shadow(color: Cockpit.live.opacity(0.4), radius: 12, y: 4)

            Text("Sitch")
                .font(.system(.largeTitle, design: .rounded).weight(.heavy))

            Text("Tap a shortcut to get started")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Edit tile

    private var editTile: some View {
        Button {
            isEditing = true
        } label: {
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
                    .foregroundStyle(.secondary.opacity(0.55))
                    .frame(width: 64, height: 64)
                    .overlay {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                Text("Edit")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SpeedDialTileButtonStyle())
    }
}

// MARK: - Tile

private struct SpeedDialTile: View {
    let entry: SpeedDialEntry
    let accent: Color
    let action: () -> Void

    @State private var tapTrigger = 0

    var body: some View {
        Button {
            tapTrigger &+= 1
            action()
        } label: {
            VStack(spacing: 10) {
                badge
                Text(entry.title.isEmpty ? entry.displayHost : entry.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SpeedDialTileButtonStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: tapTrigger)
    }

    private var badge: some View {
        monogram
            .frame(width: 64, height: 64)
            .glassEffect(
                .regular.tint(accent.opacity(0.3)).interactive(),
                in: .rect(cornerRadius: 18, style: .continuous)
            )
    }

    private var monogram: some View {
        Circle()
            .fill(.linearGradient(
                colors: [accent, accent.opacity(0.6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .frame(width: 42, height: 42)
            .overlay {
                Text(entry.monogram)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
    }
}

// MARK: - Button style

private struct SpeedDialTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

import SwiftUI

/// Compact per-window HUD: estimated memory plus the latest leak-check.
struct WindowDiagnosticsBadge: View {
    let title: String
    let snapshot: WindowMemorySnapshot?
    let report: WindowLeakCheckReport
    let compact: Bool
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: compact ? 4 : 6) {
                    Circle()
                        .fill(verdictColor)
                        .frame(width: compact ? 5 : 6, height: compact ? 5 : 6)
                    Text(memoryLabel)
                        .font(.system(size: compact ? 8 : 10, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white)
                    Text(verdictLabel)
                        .font(.system(size: compact ? 7 : 8, weight: .black, design: .rounded))
                        .foregroundStyle(verdictColor)
                }
                .padding(.horizontal, compact ? 5 : 7)
                .padding(.vertical, compact ? 3 : 4)
                .background(Color.black.opacity(0.62), in: .rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) memory \(memoryLabel), leak check \(verdictLabel)")

            if isExpanded {
                expandedCard
            }
        }
    }

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
            if let snapshot {
                Text("est. \(ProcessMemorySampler.formatBytes(snapshot.attributedBytes))")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("store \(snapshot.storeRecordCount) · cookies \(snapshot.cookieCount) · nodes \(snapshot.page.nodeCount)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                Text("Sampling…")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            ForEach(report.items) { item in
                HStack(alignment: .top, spacing: 4) {
                    Text(shortVerdict(item.verdict))
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .foregroundStyle(color(for: item.verdict))
                        .frame(width: 28, alignment: .leading)
                    Text(item.detail)
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: 210, alignment: .leading)
        .background(Color.black.opacity(0.78), in: .rect(cornerRadius: 10))
    }

    private var memoryLabel: String {
        guard let snapshot else { return "—" }
        return compact
            ? ProcessMemorySampler.compactBytes(snapshot.attributedBytes)
            : ProcessMemorySampler.formatBytes(snapshot.attributedBytes)
    }

    private var verdictLabel: String {
        switch report.verdict {
        case .idle: return "IDLE"
        case .running: return "RUN"
        case .pass: return "PASS"
        case .warn: return "WARN"
        case .fail: return "FAIL"
        }
    }

    private var verdictColor: Color { color(for: report.verdict) }

    private func color(for verdict: LeakCheckVerdict) -> Color {
        switch verdict {
        case .idle: return .white.opacity(0.45)
        case .running: return Cockpit.live
        case .pass: return Color(red: 0.35, green: 0.92, blue: 0.55)
        case .warn: return Color(red: 1.0, green: 0.78, blue: 0.18)
        case .fail: return Color(red: 1.0, green: 0.32, blue: 0.32)
        }
    }

    private func shortVerdict(_ verdict: LeakCheckVerdict) -> String {
        switch verdict {
        case .idle: return "IDLE"
        case .running: return "RUN"
        case .pass: return "PASS"
        case .warn: return "WARN"
        case .fail: return "FAIL"
        }
    }
}

struct ProcessMemoryStrip: View {
    let sample: ProcessMemorySample
    let windowCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "memorychip")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.18))
            Text("APP \(ProcessMemorySampler.formatBytes(sample.usedBytes))")
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
            Text("FREE \(ProcessMemorySampler.formatBytes(sample.availableBytes))")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            Text("· \(windowCount) WIN")
                .font(.system(size: 8, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.58), in: .capsule)
        .allowsHitTesting(false)
    }
}

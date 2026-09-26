import SwiftUI

struct ResultDetailView: View {
    let record: AttemptRecord
    @Environment(\.dismiss) private var dismiss
    @State private var screenshot: UIImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let screenshot {
                    Image(uiImage: screenshot)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 12))
                        .frame(maxWidth: .infinity)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.tertiarySystemFill))
                        .frame(height: 220)
                        .overlay {
                            VStack(spacing: 6) {
                                Image(systemName: "photo")
                                    .font(.title)
                                Text("No screenshot captured")
                                    .font(.caption)
                            }
                            .foregroundStyle(.tertiary)
                        }
                }

                VStack(alignment: .leading, spacing: 12) {
                    detailRow("Email", record.username)
                    detailRow("Domain", record.targetDomain)
                    detailRow("Password", "\(record.passwordIndex) of \(record.passwordTotal)")
                    detailRow("Session", record.sessionTag.uppercased())
                    detailRow("Status", record.status.label, valueColor: record.status.color)
                    if let verdict = record.judgeVerdict, !verdict.isEmpty {
                        detailRow("Judge", verdict.capitalized, valueColor: JudgeBadge(verdict: verdict).color)
                    }
                    if record.judgeConfidence > 0 {
                        detailRow("Confidence", "\(Int((record.judgeConfidence * 100).rounded()))%")
                    }
                    if let reason = record.judgeReason, !reason.isEmpty {
                        detailRow("Reason", reason)
                    }
                    if let brain = record.judgeBrain, !brain.isEmpty, brain != "—" {
                        detailRow("Brain", brain)
                    }
                    detailRow("When", record.timestamp.formatted(date: .abbreviated, time: .standard))
                    if let title = record.resultPageTitle, !title.isEmpty {
                        detailRow("Page Title", title)
                    }
                    if let url = record.resultURL {
                        detailRow("Final URL", url)
                    }
                }
                .padding()
                .background(.thinMaterial, in: .rect(cornerRadius: 12))
            }
            .padding()
        }
        .navigationTitle("Attempt")
        .navigationBarTitleDisplayMode(.inline)
        // Decode off the main thread instead of synchronously in body.
        .task(id: record.screenshotFilename) {
            guard let filename = record.screenshotFilename else { return }
            screenshot = await ScreenshotStorage.loadImageAsync(filename)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func detailRow(_ label: String, _ value: String, valueColor: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .kerning(0.5)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
        }
    }
}

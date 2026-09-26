import SwiftUI
import SwiftData

struct HistoryView: View {
    let viewModel: BrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BrowsingHistoryEntry.visitedAt, order: .reverse) private var history: [BrowsingHistoryEntry]
    @State private var searchText: String = ""

    private var filteredHistory: [BrowsingHistoryEntry] {
        guard !searchText.isEmpty else { return history }
        let search = searchText.lowercased()
        return history.filter {
            $0.title.localizedStandardContains(search) ||
            $0.domain.localizedStandardContains(search)
        }
    }

    private var groupedHistory: [(String, [BrowsingHistoryEntry])] {
        let grouped = Dictionary(grouping: filteredHistory) { entry in
            entry.visitedAt.formatted(date: .abbreviated, time: .omitted)
        }
        return grouped.sorted { $0.value.first?.visitedAt ?? .distantPast > $1.value.first?.visitedAt ?? .distantPast }
    }

    var body: some View {
        List {
            ForEach(groupedHistory, id: \.0) { date, entries in
                Section(date) {
                    ForEach(entries) { entry in
                        Button {
                            viewModel.navigateTo(entry.url)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                HStack {
                                    Text(entry.domain)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Spacer()

                                    Text(entry.visitedAt, format: .dateTime.hour().minute())
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .overlay {
            if history.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock", description: Text("Browsing history will appear here"))
            }
        }
        .searchable(text: $searchText, prompt: "Search history")
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear All", role: .destructive) {
                    clearAll()
                }
                .disabled(history.isEmpty)
            }
        }
    }

    private func clearAll() {
        for entry in history {
            modelContext.delete(entry)
        }
    }
}

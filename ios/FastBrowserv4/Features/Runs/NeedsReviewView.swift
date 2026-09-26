import SwiftUI
import SwiftData

/// Credentials flagged "disabled" mid-run land here instead of being
/// deleted immediately. Nothing is removed from the vault or the keychain
/// until you explicitly confirm Delete for a row (or Delete All) — Keep
/// clears the flag and lets a future run try the account again.
struct NeedsReviewView: View {
    /// True when hosted by the Automation tab rather than presented as a
    /// sheet — the tab supplies the navigation and the way back out.
    var isEmbedded: Bool = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allCredentials: [Credential]
    private var store = NeedsReviewStore.shared
    @State private var pendingDelete: NeedsReviewStore.Entry?
    @State private var showDeleteAllConfirmation: Bool = false

    /// Written out rather than left to the compiler: the private `store`
    /// property makes the synthesised memberwise initialiser private too, so
    /// the Automation tab could not construct one.
    init(isEmbedded: Bool = false) {
        self.isEmbedded = isEmbedded
    }

    private var sortedEntries: [NeedsReviewStore.Entry] {
        store.entries.sorted { $0.flaggedAt > $1.flaggedAt }
    }

    private func credential(for entry: NeedsReviewStore.Entry) -> Credential? {
        allCredentials.first { $0.id == entry.id }
    }

    var body: some View {
        NavigationStack {
            List {
                if store.entries.isEmpty {
                    ContentUnavailableView(
                        "Nothing to Review",
                        systemImage: "checkmark.shield",
                        description: Text("Accounts that show a \u{201C}disabled\u{201D} message during a run are held here \u{2014} nothing is deleted until you say so.")
                    )
                } else {
                    Section {
                        ForEach(sortedEntries) { entry in
                            row(entry)
                        }
                    } footer: {
                        Text("Keep lets a future run try the account again. Delete permanently removes it and its stored password.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Needs Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isEmbedded {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }
                if !store.entries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Keep All", systemImage: "checkmark.shield") {
                                for entry in store.entries { store.keep(credentialID: entry.id) }
                            }
                            Button("Delete All", systemImage: "trash", role: .destructive) {
                                showDeleteAllConfirmation = true
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete \(store.entries.count) flagged credential(s)?",
                isPresented: $showDeleteAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) { deleteAll() }
            } message: {
                Text("This permanently removes their stored passwords. This can't be undone.")
            }
            .confirmationDialog(
                "Delete this credential?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { deleteOne(pendingDelete) }
            } message: {
                Text("This permanently removes \(pendingDelete?.username ?? "this credential") and its stored password.")
            }
        }
    }

    private func row(_ entry: NeedsReviewStore.Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.username)
                    .font(.body.weight(.medium))
                Text(entry.domain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(entry.reason)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text(entry.flaggedAt, format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                pendingDelete = entry
            }
            Button("Keep", systemImage: "checkmark.shield") {
                store.keep(credentialID: entry.id)
            }
            .tint(.green)
        }
    }

    private func deleteOne(_ entry: NeedsReviewStore.Entry?) {
        guard let entry else { return }
        if let credential = credential(for: entry) {
            store.confirmDelete(credential, context: modelContext)
        } else {
            store.remove(credentialID: entry.id)
        }
        pendingDelete = nil
    }

    private func deleteAll() {
        for entry in store.entries {
            if let credential = credential(for: entry) {
                store.confirmDelete(credential, context: modelContext)
            } else {
                store.remove(credentialID: entry.id)
            }
        }
    }
}

import SwiftUI

/// Editor for the speed-dial shortcuts. Reorder, rename, re-point, add, delete,
/// or reset to the built-in defaults. All changes save immediately.
struct SpeedDialEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var store = SpeedDialStore.shared
    @State private var showResetConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($store.entries) { $entry in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Name", text: $entry.title)
                                .font(.body.weight(.medium))
                                .textInputAutocapitalization(.words)

                            HStack(spacing: 8) {
                                Image(systemName: "link")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("example.com", text: $entry.urlString)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.URL)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { store.removeEntries(at: $0) }
                    .onMove { store.moveEntries(from: $0, to: $1) }
                } header: {
                    Text("Shortcuts")
                } footer: {
                    Text("Drag to reorder. These appear on your home page.")
                }

                Section {
                    Button {
                        withAnimation { store.addEntry() }
                    } label: {
                        Label("Add Shortcut", systemImage: "plus.circle.fill")
                    }

                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .navigationTitle("Edit Speed Dial")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Reset speed dial to the default shortcuts?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    withAnimation { store.resetToDefaults() }
                }
            } message: {
                Text("This replaces your current shortcuts with the original set.")
            }
        }
    }
}

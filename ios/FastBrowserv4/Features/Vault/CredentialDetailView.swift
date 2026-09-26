import SwiftUI
import SwiftData

struct CredentialDetailView: View {
    let credential: Credential
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var passwords: [String] = []
    @State private var visibleIndices: Set<Int> = []
    @State private var isEditing: Bool = false
    @State private var editUsername: String = ""
    @State private var editPasswords: [String] = []
    @State private var editNotes: String = ""
    @State private var showDeleteConfirmation: Bool = false
    @State private var showExcludeConfirmation: Bool = false
    @State private var operationErrorMessage: String?

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Domain", value: credential.domain)

                if isEditing {
                    TextField("Username", text: $editUsername)
                } else {
                    HStack {
                        LabeledContent("Username", value: credential.username)
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = credential.username
                        }
                        .labelStyle(.iconOnly)
                        .font(.caption)
                    }
                }
            }

            Section {
                if isEditing {
                    ForEach(editPasswords.indices, id: \.self) { index in
                        HStack {
                            SecureField(
                                index == 0 ? "Primary password" : "Password \(index + 1)",
                                text: $editPasswords[index]
                            )
                            if editPasswords.count > 1 {
                                Button {
                                    editPasswords.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .onMove { from, to in
                        editPasswords.move(fromOffsets: from, toOffset: to)
                    }
                    Button {
                        editPasswords.append("")
                    } label: {
                        Label("Add another password", systemImage: "plus.circle.fill")
                    }
                    .foregroundStyle(Cockpit.live)
                } else {
                    if passwords.isEmpty {
                        Text("No password stored")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(passwords.indices, id: \.self) { index in
                            passwordRow(index: index)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Passwords")
                    if !isEditing && passwords.count > 1 {
                        Text("· \(passwords.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                if !isEditing && passwords.count > 1 {
                    Text("RCR tries each password in order if a login is rejected.")
                }
            }

            Section("Notes") {
                if isEditing {
                    TextField("Notes", text: $editNotes, axis: .vertical)
                        .lineLimit(3...6)
                } else {
                    if let notes = credential.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.body)
                    } else {
                        Text("No notes")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Info") {
                LabeledContent("Created", value: credential.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Updated", value: credential.updatedAt.formatted(date: .abbreviated, time: .shortened))
                if let lastUsed = credential.lastUsedAt {
                    LabeledContent("Last Used", value: lastUsed.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Times Used", value: "\(credential.usageCount)")
            }

            if !isEditing {
                Section {
                    Button("Move to Exclude List", systemImage: "nosign") {
                        showExcludeConfirmation = true
                    }
                    .tint(.orange)

                    Button("Delete Credential", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
            }
        }
        .navigationTitle(credential.displayDomain)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(isEditing ? "Cancel" : "Done") {
                    if isEditing {
                        isEditing = false
                    } else {
                        dismiss()
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditing ? "Save" : "Edit") {
                    if isEditing {
                        saveChanges()
                    } else {
                        startEditing()
                    }
                }
            }
        }
        .task {
            passwords = KeychainService.shared.getPasswords(for: credential.id)
        }
        .confirmationDialog("Delete Credential?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                deleteCredential()
            }
        } message: {
            Text("This will permanently delete the credential for \(credential.username)")
        }
        .confirmationDialog(
            "Move to Exclude List?",
            isPresented: $showExcludeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Exclude List", role: .destructive) {
                moveToExcludeList()
            }
        } message: {
            Text("\(credential.displayDomain) will be skipped for auto-fill and save prompts, and this credential will be removed.")
        }
        .alert("Unable to Save Changes", isPresented: operationErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationErrorMessage ?? "The operation could not be completed.")
        }
    }

    @ViewBuilder
    private func passwordRow(index: Int) -> some View {
        let visible = visibleIndices.contains(index)
        let value = passwords[index]
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)

            if visible {
                Text(value)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(String(repeating: "•", count: max(8, min(value.count, 14))))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                if visible {
                    visibleIndices.remove(index)
                } else {
                    visibleIndices.insert(index)
                }
            } label: {
                Image(systemName: visible ? "eye.slash" : "eye")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button {
                UIPasteboard.general.string = value
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func startEditing() {
        editUsername = credential.username
        editPasswords = passwords.isEmpty ? [""] : passwords
        editNotes = credential.notes ?? ""
        isEditing = true
    }

    private var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { operationErrorMessage != nil },
            set: { isPresented in
                if !isPresented { operationErrorMessage = nil }
            }
        )
    }

    private func saveChanges() {
        let cleaned = editPasswords.filter { !$0.isEmpty }
        if cleaned != passwords {
            guard KeychainService.shared.savePasswords(cleaned, for: credential.id) else {
                operationErrorMessage = "The password could not be stored securely. Your previous password remains unchanged."
                return
            }
        }

        credential.username = editUsername
        credential.notes = editNotes.isEmpty ? nil : editNotes
        credential.updatedAt = Date()
        do {
            try modelContext.save()
            passwords = cleaned
            visibleIndices.removeAll()
            isEditing = false
        } catch {
            modelContext.rollback()
            operationErrorMessage = "The credential details could not be saved. Please try again."
        }
    }

    private func deleteCredential() {
        let vaultViewModel = VaultViewModel()
        guard vaultViewModel.deleteCredential(credential, context: modelContext) else {
            operationErrorMessage = "The credential could not be deleted. Its saved data was left in place."
            return
        }
        dismiss()
    }

    private func moveToExcludeList() {
        let vaultViewModel = VaultViewModel()
        let result = vaultViewModel.bulkMoveToExcludeList([credential], context: modelContext)
        guard result.failedCredentialIDs.isEmpty else {
            operationErrorMessage = "The credential could not be removed. Its saved data was left in place."
            return
        }
        dismiss()
    }
}

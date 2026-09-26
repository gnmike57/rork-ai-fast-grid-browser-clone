import SwiftUI
import SwiftData

struct CredentialFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var domain: String = ""
    @State private var username: String = ""
    @State private var passwords: [String] = [""]
    @State private var notes: String = ""
    @State private var isShowingGenerator: Bool = false
    @State private var generatorTargetIndex: Int = 0

    var body: some View {
        Form {
            Section("Website") {
                TextField("Domain (e.g. google.com)", text: $domain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
            }

            Section("Username") {
                TextField("Username or Email", text: $username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .textContentType(.username)
            }

            Section {
                ForEach(passwords.indices, id: \.self) { index in
                    HStack {
                        SecureField(
                            index == 0 ? "Primary password" : "Password \(index + 1)",
                            text: $passwords[index]
                        )
                        .textContentType(.password)

                        Button {
                            generatorTargetIndex = index
                            isShowingGenerator = true
                        } label: {
                            Image(systemName: "dice")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        if passwords.count > 1 {
                            Button {
                                passwords.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .onMove { from, to in
                    passwords.move(fromOffsets: from, toOffset: to)
                }

                Button {
                    passwords.append("")
                } label: {
                    Label("Add another password", systemImage: "plus.circle.fill")
                }
                .foregroundStyle(Cockpit.live)
            } header: {
                Text("Passwords")
            } footer: {
                if passwords.count > 1 {
                    Text("RCR will try each password in order if a login is rejected.")
                }
            }

            Section("Notes (Optional)") {
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(3...6)
            }
        }
        .navigationTitle("Add Credential")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!isValid)
            }
        }
        .sheet(isPresented: $isShowingGenerator) {
            NavigationStack {
                PasswordGeneratorView(onSelect: { generated in
                    if passwords.indices.contains(generatorTargetIndex) {
                        passwords[generatorTargetIndex] = generated
                    }
                })
            }
        }
    }

    private var isValid: Bool {
        !domain.isEmpty
            && !username.isEmpty
            && passwords.contains(where: { !$0.isEmpty })
    }

    private func save() {
        let cleanDomain = CredentialImportService.extractDomain(from: domain)
        let credential = Credential(
            domain: cleanDomain.isEmpty ? domain.lowercased() : cleanDomain,
            username: username,
            notes: notes.isEmpty ? nil : notes
        )
        modelContext.insert(credential)
        let cleaned = passwords.filter { !$0.isEmpty }
        _ = KeychainService.shared.savePasswords(cleaned, for: credential.id)
        try? modelContext.save()
        dismiss()
    }
}

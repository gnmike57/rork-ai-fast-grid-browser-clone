import SwiftUI
import SwiftData

/// Edit one provider: connection details, enable toggle, key slots with
/// add/remove (keys stored in the Keychain, shown masked), model fetch,
/// connection test, and a destructive delete that also purges keys.
struct EditAIProviderView: View {
    @Bindable var config: AIProviderConfig
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var newKey: String = ""
    @State private var isTesting: Bool = false
    @State private var fetchedModels: [String] = []
    @State private var isFetchingModels: Bool = false
    @State private var modelFetchError: String?
    @State private var showDeleteConfirm: Bool = false

    var body: some View {
        Form {
            Section {
                TextField("Display name", text: $config.displayName)
                TextField("Base URL", text: $config.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Model", text: $config.modelName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("Enabled", isOn: $config.isEnabled)
            } header: {
                Text("Provider")
            }

            Section {
                if config.keyCount == 0 {
                    Text("No keys yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(0..<config.keyCount, id: \.self) { slot in
                        HStack {
                            Text(LLMKeyVault.shared.maskedKey(providerID: config.id, slot: slot) ?? "—")
                                .font(.body.monospaced())
                            Spacer()
                            Text("Key \(slot + 1)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete(perform: deleteKeys)
                }

                HStack {
                    SecureField("Add another key", text: $newKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Add") {
                        guard LLMKeyVault.shared.setKey(newKey, providerID: config.id, slot: config.keyCount) else { return }
                        config.keyCount += 1
                        newKey = ""
                        persist()
                    }
                    .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("API Keys")
            } footer: {
                Text("Keys rotate automatically — a rate-limited key cools off while the next one serves. Deleting a key renumbers the rest.")
            }

            Section {
                Button {
                    fetchModels()
                } label: {
                    HStack {
                        if isFetchingModels { ProgressView().controlSize(.small) }
                        Label(isFetchingModels ? "Fetching models…" : "Fetch available models", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(firstAvailableKey() == nil || isFetchingModels)

                if let modelFetchError {
                    Text(modelFetchError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if !fetchedModels.isEmpty {
                    ForEach(fetchedModels.prefix(30), id: \.self) { model in
                        Button(model) {
                            config.modelName = model
                            persist()
                        }
                        .foregroundStyle(.primary)
                        .font(.caption.monospaced())
                    }
                }
            } header: {
                Text("Model")
            }

            Section {
                Button {
                    runTest()
                } label: {
                    HStack {
                        if isTesting { ProgressView().controlSize(.small) }
                        Text(isTesting ? "Testing…" : "Test Connection")
                    }
                }
                .disabled(firstAvailableKey() == nil || isTesting)

                if let summary = config.lastTestSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(config.lastTestOK ? .green : .orange)
                }
            } header: {
                Text("Verify")
            }

            Section {
                Button("Delete Provider", role: .destructive) {
                    showDeleteConfirm = true
                }
            }
        }
        .navigationTitle(config.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: persist)
        .confirmationDialog(
            "Delete \"\(config.displayName)\" and all of its keys?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                LLMKeyVault.shared.deleteAllKeys(providerID: config.id)
                modelContext.delete(config)
                try? modelContext.save()
                IntelligenceCenter.shared.refreshProviders()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func firstAvailableKey() -> String? {
        for slot in 0..<config.keyCount {
            if let key = LLMKeyVault.shared.key(providerID: config.id, slot: slot) {
                return key
            }
        }
        return nil
    }

    private func deleteKeys(at offsets: IndexSet) {
        // Read surviving keys first, then rewrite slots 0..<n so numbering
        // stays dense (rotation assumes contiguous slots).
        var surviving: [String] = []
        for slot in 0..<config.keyCount where !offsets.contains(slot) {
            if let key = LLMKeyVault.shared.key(providerID: config.id, slot: slot) {
                surviving.append(key)
            }
        }
        LLMKeyVault.shared.deleteAllKeys(providerID: config.id)
        for (index, key) in surviving.enumerated() {
            _ = LLMKeyVault.shared.setKey(key, providerID: config.id, slot: index)
        }
        config.keyCount = surviving.count
        config.rotationIndex = 0
        persist()
    }

    private func runTest() {
        guard let key = firstAvailableKey() else { return }
        isTesting = true
        let endpoint = OpenAIChatClient.Endpoint(baseURL: config.baseURL, apiKey: key, model: config.modelName)
        Task {
            let result = await OpenAIChatClient().testConnection(endpoint: endpoint)
            isTesting = false
            config.lastTestSummary = result
            config.lastTestOK = result.hasPrefix("Connected")
            persist()
        }
    }

    private func fetchModels() {
        guard let key = firstAvailableKey() else { return }
        modelFetchError = nil
        isFetchingModels = true
        let endpoint = OpenAIChatClient.Endpoint(baseURL: config.baseURL, apiKey: key, model: config.modelName)
        Task {
            let models = await OpenAIChatClient().fetchModels(endpoint: endpoint)
            isFetchingModels = false
            fetchedModels = models
            if models.isEmpty {
                modelFetchError = "Couldn't fetch models — check the base URL and API key, or this provider may not support model listing."
            }
        }
    }

    private func persist() {
        try? modelContext.save()
        IntelligenceCenter.shared.refreshProviders()
    }
}

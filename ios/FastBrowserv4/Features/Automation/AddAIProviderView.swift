import SwiftUI
import SwiftData

/// Sheet for adding a new OpenAI-compatible provider with its first key.
/// Save is gated on a successful Test of the key so dead keys never enter
/// rotation. Keys land in the Keychain; only connection details hit SwiftData.
struct AddAIProviderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\AIProviderConfig.sortOrder)]) private var existing: [AIProviderConfig]

    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var modelName: String = ""
    @State private var firstKey: String = ""
    @State private var presetIndex: Int = 0
    @State private var isTesting: Bool = false
    @State private var testSummary: String?
    @State private var testOK: Bool = false
    @State private var fetchedModels: [String] = []

    private struct Preset: Identifiable {
        let id: String
        let name: String
        let baseURL: String
        let model: String
    }

    private static let presets: [Preset] = [
        .init(id: "custom", name: "Custom…", baseURL: "", model: ""),
        .init(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini"),
        .init(id: "anthropic", name: "Anthropic", baseURL: "https://api.anthropic.com/v1", model: "claude-sonnet-4-5"),
        .init(id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", model: "gemini-2.0-flash"),
        .init(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile"),
        .init(id: "xai", name: "xAI", baseURL: "https://api.x.ai/v1", model: "grok-3-mini"),
        .init(id: "lan", name: "Local (Ollama / LM Studio)", baseURL: "http://192.168.1.100:11434/v1", model: "llama3.1")
    ]

    private static func makeClient() -> OpenAIChatClient { OpenAIChatClient() }

    var body: some View {
        Form {
            Section {
                Picker("Preset", selection: $presetIndex) {
                    ForEach(Array(Self.presets.enumerated()), id: \.element.id) { index, preset in
                        Text(preset.name).tag(index)
                    }
                }
                .onChange(of: presetIndex) { _, newIndex in
                    let preset = Self.presets[newIndex]
                    if preset.id != "custom" {
                        name = preset.name
                        baseURL = preset.baseURL
                        modelName = preset.model
                    }
                }

                TextField("Name", text: $name)
                TextField("Base URL", text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !fetchedModels.isEmpty {
                    Picker("Model", selection: $modelName) {
                        ForEach(fetchedModels, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    TextField("Model (e.g. gpt-4o-mini)", text: $modelName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Button("Fetch Models") { fetchModels() }
                    .disabled(baseURL.isEmpty || firstKey.isEmpty)
            } header: {
                Text("Provider")
            }

            Section {
                SecureField("API Key", text: $firstKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("First Key")
            } footer: {
                Text("Stored in the iOS Keychain and never shown in full again. You can add more keys after saving — they rotate automatically.")
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
                .disabled(!canTest)
                if let testSummary {
                    Text(testSummary)
                        .font(.caption)
                        .foregroundStyle(testOK ? .green : .orange)
                }
            } header: {
                Text("Verify")
            } footer: {
                Text("A successful test is required to save. This is the only way to catch a typo'd key before it pollutes rotation.")
            }
        }
        .navigationTitle("Add Provider")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .disabled(!testOK)
                    .fontWeight(.bold)
            }
        }
    }

    private var canTest: Bool {
        !isTesting && !baseURL.isEmpty && !modelName.isEmpty && !firstKey.isEmpty
    }

    private func runTest() {
        isTesting = true
        testSummary = nil
        testOK = false
        let client = Self.makeClient()
        let endpoint = OpenAIChatClient.Endpoint(baseURL: baseURL, apiKey: firstKey, model: modelName)
        Task {
            let result = await client.testConnection(endpoint: endpoint)
            await MainActor.run {
                isTesting = false
                testSummary = result
                testOK = result.hasPrefix("Connected")
            }
        }
    }

    private func fetchModels() {
        let client = Self.makeClient()
        let endpoint = OpenAIChatClient.Endpoint(baseURL: baseURL, apiKey: firstKey, model: modelName)
        Task {
            let models = await client.fetchModels(endpoint: endpoint)
            await MainActor.run {
                fetchedModels = models
                if !models.contains(modelName), let first = models.first {
                    modelName = first
                }
            }
        }
    }

    private func save() {
        let config = AIProviderConfig(
            displayName: name.isEmpty ? "Provider" : name,
            baseURL: baseURL,
            modelName: modelName,
            sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1
        )
        if LLMKeyVault.shared.setKey(firstKey, providerID: config.id, slot: 0) {
            config.keyCount = 1
        }
        config.lastTestOK = true
        config.lastTestSummary = testSummary
        modelContext.insert(config)
        try? modelContext.save()
        IntelligenceCenter.shared.refreshProviders()
        dismiss()
    }
}

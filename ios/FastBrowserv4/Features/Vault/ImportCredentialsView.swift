import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportCredentialsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var importTab: ImportTab
    @State private var selectedFormat: ImportFormat = .chromeCSV
    @State private var isShowingFilePicker: Bool = false
    @State private var importResult: String?
    @State private var isImporting: Bool = false

    // Paste / combo-list state
    @State private var pasteText: String = ""
    @State private var comboSeparator: ComboListSeparator = .auto
    @State private var comboFormat: ComboListFormat = .email
    /// Debounced parse result for the paste preview — re-parsing a huge
    /// paste synchronously on every keystroke freezes typing.
    @State private var comboPreview = ComboListPreview(credentialCount: 0, passwordCount: 0, skippedCount: 0, mergedCount: 0)

    enum ImportTab: String, CaseIterable, Identifiable {
        case file = "File"
        case paste = "Paste"
        var id: String { rawValue }
    }

    init(initialTab: ImportTab = .file) {
        _importTab = State(initialValue: initialTab)
    }

    var body: some View {
        Form {
            Section {
                Picker("", selection: $importTab) {
                    ForEach(ImportTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

            if importTab == .file {
                fileTab
            } else {
                pasteTab
            }
        }
        .navigationTitle("Import Credentials")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .task(id: ComboPreviewInput(text: pasteText, separator: comboSeparator, format: comboFormat)) {
            // Debounce: wait for a typing pause, then parse off the main
            // thread so a 10k-line paste doesn't hitch every keystroke.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let text = pasteText
            let separator = comboSeparator
            let format = comboFormat
            let result = await Task.detached {
                CredentialImportService.comboListPreview(text, separator: separator, format: format)
            }.value
            guard !Task.isCancelled else { return }
            comboPreview = result
        }
    }

    // MARK: - File tab

    @ViewBuilder
    private var fileTab: some View {
        Section("Format") {
            Picker("Import Format", selection: $selectedFormat) {
                ForEach(ImportFormat.allCases, id: \.self) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.segmented)

            Text(selectedFormat.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            Button {
                isShowingFilePicker = true
            } label: {
                Label("Select File", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity)
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isImporting)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }

        if let result = importResult {
            Section("Result") {
                Label(result, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }

        Section("Instructions") {
            VStack(alignment: .leading, spacing: 8) {
                instructionRow(number: "1", text: "Export passwords from your browser as CSV or a combo-list .txt")
                instructionRow(number: "2", text: "Select the matching format above")
                instructionRow(number: "3", text: "Tap \"Select File\" and choose the export")
                instructionRow(number: "4", text: "Credentials will be imported to your vault")
            }
        }
    }

    // MARK: - Paste tab

    @ViewBuilder
    private var pasteTab: some View {
        Section {
            Picker("Separator", selection: $comboSeparator) {
                ForEach(ComboListSeparator.allCases, id: \.self) { sep in
                    Text(sep.label).tag(sep)
                }
            }
            .pickerStyle(.segmented)

            Picker("Login Type", selection: $comboFormat) {
                ForEach(ComboListFormat.allCases, id: \.self) { fmt in
                    Text(fmt.rawValue).tag(fmt)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Combo List Options")
        } footer: {
            Text("Each line: login\u{2009}\u{2022}password. Extra fields become extra passwords for that login.")
                .font(.caption2)
        }

        Section("Combo List") {
            ZStack(alignment: .topLeading) {
                if pasteText.isEmpty {
                    Text("email:password\nusername:password\nlogin;pass\none,two")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                        .padding(.top, 8)
                        .padding(.leading, 6)
                }
                TextEditor(text: $pasteText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
            }

            Button {
                if let clipboard = UIPasteboard.general.string {
                    pasteText = clipboard
                }
            } label: {
                Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
        }

        let preview = comboPreview

        if !pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Section("Preview") {
                HStack(spacing: 16) {
                    statPill(
                        value: preview.credentialCount,
                        label: "credentials",
                        color: Cockpit.live
                    )
                    statPill(
                        value: preview.passwordCount,
                        label: "passwords",
                        color: .blue
                    )
                    if preview.skippedCount > 0 {
                        statPill(
                            value: preview.skippedCount,
                            label: "skipped",
                            color: .orange
                        )
                    }
                    if preview.mergedCount > 0 {
                        statPill(
                            value: preview.mergedCount,
                            label: "merged",
                            color: .purple
                        )
                    }
                }
            }

            Section {
                Button {
                    performComboImport()
                } label: {
                    HStack {
                        if isImporting {
                            ProgressView()
                                .tint(.white)
                        }
                        Text("Import \(preview.credentialCount) Credential\(preview.credentialCount == 1 ? "" : "s")")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isImporting || preview.isEmpty)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }

        if let result = importResult, importTab == .paste {
            Section("Result") {
                Label(result, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }

        Section {
            VStack(alignment: .leading, spacing: 8) {
                instructionRow(number: "1", text: "Copy a combo list — one login\u{2009}:password per line")
                instructionRow(number: "2", text: "Pick the separator (or leave on Auto) and login type")
                instructionRow(number: "3", text: "Paste into the box or use \"Paste from Clipboard\"")
                instructionRow(number: "4", text: "Review the preview count and tap Import")
            }
        } header: {
            Text("Instructions")
        }
    }

    // MARK: - Helpers

    private func statPill(value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func instructionRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Cockpit.live, in: Circle())

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Import actions

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        isImporting = true
        importResult = nil

        guard url.startAccessingSecurityScopedResource() else {
            importResult = "Could not access file"
            isImporting = false
            return
        }

        // Read and parse off the main thread — large imports otherwise
        // freeze the UI for the whole parse.
        let format = selectedFormat
        let combo = comboFormat
        Task {
            let parsed: Result<[ImportedCredential], Error> = await Task.detached {
                do {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    if format == .comboList {
                        let sep = CredentialImportService.detectSeparator(in: content)
                        return .success(
                            CredentialImportService.parseComboList(
                                content,
                                separator: sep,
                                format: combo
                            )
                        )
                    }
                    return .success(CredentialImportService.parseCSV(content, format: format))
                } catch {
                    return .failure(error)
                }
            }.value
            url.stopAccessingSecurityScopedResource()
            switch parsed {
            case .success(let imported):
                importResult = persistImported(imported)
            case .failure(let error):
                importResult = "Error reading file: \(error.localizedDescription)"
            }
            isImporting = false
        }
    }

    private func performComboImport() {
        isImporting = true
        let text = pasteText
        let separator = comboSeparator
        let format = comboFormat
        Task {
            let imported = await Task.detached {
                CredentialImportService.parseComboList(
                    text,
                    separator: separator,
                    format: format
                )
            }.value
            let summary = persistImported(imported)
            importResult = summary
            if !imported.isEmpty {
                pasteText = ""
            }
            isImporting = false
        }
    }

    /// Inserts the parsed credentials into SwiftData + Keychain and returns a
    /// human-readable summary string. Re-importing a login that already
    /// exists merges its passwords into the existing credential instead of
    /// creating a duplicate row (which would split the vault entry from its
    /// keychain payload).
    @discardableResult
    private func persistImported(_ imported: [ImportedCredential]) -> String {
        guard !imported.isEmpty else {
            return "No valid credentials found"
        }

        var newCount = 0
        var mergedCount = 0
        var passwordTotal = 0

        for item in imported {
            let domainLower = item.domain.lowercased()
            let username = item.username
            let descriptor = FetchDescriptor<Credential>(
                predicate: #Predicate<Credential> {
                    $0.domain == domainLower && $0.username == username
                }
            )
            if let existing = try? modelContext.fetch(descriptor).first {
                // Merge into the existing credential's keychain entry.
                let current = KeychainService.shared.getPasswords(for: existing.id)
                let merged = CredentialImportService.mergePasswords(
                    existing: current,
                    new: item.passwords
                )
                if KeychainService.shared.savePasswords(merged, for: existing.id) {
                    mergedCount += 1
                    passwordTotal += item.passwords.count
                }
            } else {
                let credential = Credential(domain: item.domain, username: item.username, notes: item.notes)
                modelContext.insert(credential)
                if KeychainService.shared.savePasswords(item.passwords, for: credential.id) {
                    newCount += 1
                    passwordTotal += item.passwords.count
                }
            }
        }

        try? modelContext.save()
        if mergedCount > 0 {
            return "Imported \(newCount) credentials, merged \(mergedCount) (\(passwordTotal) passwords)"
        }
        return "Imported \(newCount) credentials (\(passwordTotal) passwords)"
    }
}

/// Identity for the debounced combo-list preview parse. Changes whenever
/// the text, separator, or format changes; `.task(id:)` cancels the
/// previous parse automatically.
private struct ComboPreviewInput: Equatable {
    let text: String
    let separator: ComboListSeparator
    let format: ComboListFormat
}

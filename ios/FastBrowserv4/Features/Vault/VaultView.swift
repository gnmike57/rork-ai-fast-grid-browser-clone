import SwiftUI
import SwiftData

struct VaultView: View {
    /// True when hosted by the tab bar rather than presented as a sheet, in
    /// which case there is no Done button because there is nothing to dismiss.
    var isEmbedded: Bool = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Credential.domain) private var credentials: [Credential]
    @Query(sort: \ExcludedDomain.domain) private var excludedDomains: [ExcludedDomain]
    @State private var viewModel = VaultViewModel()
    @State private var showDeleteAllConfirmation: Bool = false
    @State private var showBulkDeleteConfirmation: Bool = false
    @State private var showBulkExcludeConfirmation: Bool = false
    @State private var showResults: Bool = false
    @State private var isShowingNeedsReview: Bool = false
    @State private var attemptCounts: [String: Int] = [:]
    @State private var passwordCounts: [String: Int] = [:] // cached keychain counts
    @State private var operationErrorMessage: String?
    @State private var pendingDeleteCredential: Credential?
    private let needsReviewStore = NeedsReviewStore.shared
    // Filtering, sorting and grouping the whole vault used to be computed
    // properties re-run on every body evaluation (any toast, any unrelated
    // state change) instead of only when something relevant changed. These
    // cache the result and only recompute on an explicit trigger below, and
    // the search box is debounced so fast typing doesn't re-sort mid-word.
    @State private var displayGroups: [(String, [Credential])] = []
    @State private var isSearchEmpty: Bool = true
    @State private var searchDebounceTask: Task<Void, Never>?

    private var excludedDomainSet: Set<String> {
        Set(excludedDomains.map { $0.domain })
    }

    private func recomputeDisplayGroups() {
        let base = credentials.filter {
            !excludedDomainSet.contains(ExcludedDomain.canonicalize($0.domain))
        }
        let search = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered: [Credential] = search.isEmpty ? base : base.filter {
            $0.domain.localizedStandardContains(search) ||
            $0.username.localizedStandardContains(search)
        }
        isSearchEmpty = search.isEmpty

        // Display order only — RCR runs keep their own fixed queue order.
        let sorted = VaultViewModel.sortCredentials(filtered, by: viewModel.sortOption)
        var order: [String] = []
        var groups: [String: [Credential]] = [:]
        for credential in sorted {
            let key = credential.displayDomain
            if groups[key] == nil {
                order.append(key)
                groups[key] = []
            }
            groups[key, default: []].append(credential)
        }
        displayGroups = order.map { ($0, groups[$0] ?? []) }
    }

    private func scheduleSearchRecompute() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            recomputeDisplayGroups()
        }
    }

    var body: some View {
        vaultList
            .navigationTitle("Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task { recomputeDisplayGroups() }
            .onChange(of: viewModel.searchText) { _, _ in scheduleSearchRecompute() }
            .onChange(of: viewModel.sortOption) { _, _ in recomputeDisplayGroups() }
            .onChange(of: credentials) { _, _ in recomputeDisplayGroups() }
            .onChange(of: excludedDomains) { _, _ in recomputeDisplayGroups() }
            .safeAreaInset(edge: .bottom) {
                if viewModel.isEditMode {
                    bulkActionBar
                }
            }
            .sheet(isPresented: $viewModel.isShowingAddCredential) {
                NavigationStack { CredentialFormView() }
            }
            .sheet(item: $viewModel.selectedCredential) { credential in
                NavigationStack { CredentialDetailView(credential: credential) }
            }
            .sheet(isPresented: $viewModel.isShowingImport) {
                NavigationStack { ImportCredentialsView() }
            }
            .sheet(isPresented: $viewModel.isShowingPasteImport) {
                NavigationStack { ImportCredentialsView(initialTab: .paste) }
            }
            .sheet(isPresented: $viewModel.isShowingPasswordGenerator) {
                NavigationStack { PasswordGeneratorView() }
            }
            .sheet(isPresented: $viewModel.isShowingExcludedDomains) {
                NavigationStack { ExcludedDomainsView() }
            }
            .sheet(isPresented: $showResults) {
                NavigationStack { ResultsView() }
            }
            .sheet(isPresented: $isShowingNeedsReview) {
                NavigationStack { NeedsReviewView() }
            }
            .task {
                attemptCounts = AttemptTrackingService.shared.attemptedPasswordCounts(context: modelContext)
                await refreshPasswordCounts()
            }
            .onChange(of: showResults) { _, newValue in
                if !newValue {
                    attemptCounts = AttemptTrackingService.shared.attemptedPasswordCounts(context: modelContext)
                    Task { await refreshPasswordCounts() }
                }
            }
            .confirmationDialog(
                "Delete \(viewModel.selectedIDs.count) credential(s)?",
                isPresented: $showBulkDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    let toDelete = credentials.filter { viewModel.selectedIDs.contains($0.id) }
                    let failedIDs = viewModel.bulkDelete(toDelete, context: modelContext)
                    handleDeletionResult(failedIDs, operation: "delete")
                }
            } message: {
                Text("This permanently removes the selected credentials and their stored passwords.")
            }
            .confirmationDialog(
                "Move \(viewModel.selectedIDs.count) credential(s) to the exclude list?",
                isPresented: $showBulkExcludeConfirmation,
                titleVisibility: .visible
            ) {
                Button("Move to Exclude List", role: .destructive) {
                    let toMove = credentials.filter { viewModel.selectedIDs.contains($0.id) }
                    let result = viewModel.bulkMoveToExcludeList(toMove, context: modelContext)
                    handleDeletionResult(result.failedCredentialIDs, operation: "move")
                }
            } message: {
                Text("Their domains will be skipped for auto-fill and save prompts, and the credentials will be removed.")
            }
            .confirmationDialog(
                "Clear all credentials?",
                isPresented: $showDeleteAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear All", role: .destructive) {
                    let failedIDs = viewModel.bulkDelete(Array(credentials), context: modelContext)
                    handleDeletionResult(failedIDs, operation: "delete")
                }
            } message: {
                Text("This permanently removes every saved credential and its stored password.")
            }
            .alert("Vault Operation Incomplete", isPresented: operationErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(operationErrorMessage ?? "The operation could not be completed.")
            }
            .confirmationDialog(
                "Delete this credential?",
                isPresented: Binding(
                    get: { pendingDeleteCredential != nil },
                    set: { if !$0 { pendingDeleteCredential = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let credential = pendingDeleteCredential {
                        if !viewModel.deleteCredential(credential, context: modelContext) {
                            operationErrorMessage = "The credential could not be deleted. Its saved data was left in place."
                        }
                    }
                    pendingDeleteCredential = nil
                }
            } message: {
                Text("This permanently removes \(pendingDeleteCredential?.username ?? "this credential") and its stored password.")
            }
    }

    /// Isolated from the modifier chain in `body` so the type checker
    /// doesn't have to solve the list's nested conditional sections and a
    /// long modifier/sheet chain as a single expression.
    private var vaultList: some View {
        List {
            if !viewModel.isEditMode && isSearchEmpty {
                Section {
                    Button {
                        showResults = true
                    } label: {
                        HStack {
                            Image(systemName: "photo.on.rectangle.angled")
                                .foregroundStyle(Cockpit.live)
                            Text("Results")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if !viewModel.isEditMode && isSearchEmpty && !needsReviewStore.isEmpty {
                Section {
                    Button {
                        isShowingNeedsReview = true
                    } label: {
                        HStack {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundStyle(.orange)
                            Text("Needs Review")
                            Spacer()
                            Text("\(needsReviewStore.count)")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if !viewModel.isEditMode && isSearchEmpty && !excludedDomains.isEmpty {
                Section {
                    Button {
                        viewModel.isShowingExcludedDomains = true
                    } label: {
                        HStack {
                            Image(systemName: "nosign")
                                .foregroundStyle(.orange)
                            Text("Excluded Domains")
                            Spacer()
                            Text("\(excludedDomains.count)")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            ForEach(displayGroups, id: \.0) { domain, creds in
                Section(domain) {
                    ForEach(creds) { credential in
                        credentialRowButton(credential)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, editModeBinding)
        .overlay {
            if credentials.isEmpty && excludedDomains.isEmpty {
                ContentUnavailableView(
                    "No Saved Credentials",
                    systemImage: "lock.shield",
                    description: Text("Add credentials manually or import from another browser")
                )
            } else if displayGroups.isEmpty && !isSearchEmpty {
                ContentUnavailableView.search(text: viewModel.searchText)
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search credentials")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if viewModel.isEditMode {
                Button("Done") {
                    viewModel.isEditMode = false
                    viewModel.clearSelection()
                }
            } else if !isEmbedded {
                // Inside the tab bar there is nothing to dismiss — the tab
                // bar itself is the way back out.
                Button("Done") { dismiss() }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                ForEach(VaultSortOption.allCases) { option in
                    Button {
                        viewModel.sortOption = option
                    } label: {
                        if viewModel.sortOption == option {
                            Label(option.rawValue, systemImage: "checkmark")
                        } else {
                            Label(option.rawValue, systemImage: option.systemImage)
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Select", systemImage: "checkmark.circle") {
                    viewModel.isEditMode = true
                }
                .disabled(displayGroups.isEmpty)
                Divider()
                Button("Add Credential", systemImage: "plus") {
                    viewModel.isShowingAddCredential = true
                }
                Button("Import File", systemImage: "square.and.arrow.down") {
                    viewModel.isShowingImport = true
                }
                Button("Paste Credentials", systemImage: "doc.on.clipboard") {
                    viewModel.isShowingPasteImport = true
                }
                Button("Password Generator", systemImage: "dice") {
                    viewModel.isShowingPasswordGenerator = true
                }
                Divider()
                Button("Excluded Domains", systemImage: "nosign") {
                    viewModel.isShowingExcludedDomains = true
                }
                Button("Clear All Credentials", systemImage: "trash", role: .destructive) {
                    showDeleteAllConfirmation = true
                }
                .disabled(credentials.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Bulk action bar

    private var bulkActionBar: some View {
        HStack(spacing: 16) {
            Button {
                showBulkExcludeConfirmation = true
            } label: {
                Label("Exclude", systemImage: "nosign")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(viewModel.selectedIDs.isEmpty)

            Button(role: .destructive) {
                showBulkDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(viewModel.selectedIDs.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Rows

    @ViewBuilder
    private func credentialRowButton(_ credential: Credential) -> some View {
        if viewModel.isEditMode {
            Button {
                viewModel.toggleSelection(credential)
            } label: {
                HStack {
                    Image(systemName: viewModel.selectedIDs.contains(credential.id)
                          ? "checkmark.circle.fill"
                          : "circle")
                        .font(.title3)
                        .foregroundStyle(viewModel.selectedIDs.contains(credential.id) ? Cockpit.live : .secondary)
                    credentialRow(credential)
                }
            }
            .buttonStyle(.plain)
        } else {
            Button {
                viewModel.selectedCredential = credential
            } label: {
                credentialRow(credential)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    pendingDeleteCredential = credential
                }
                Button("Exclude", systemImage: "nosign") {
                    let result = viewModel.bulkMoveToExcludeList([credential], context: modelContext)
                    handleDeletionResult(result.failedCredentialIDs, operation: "move")
                }
                .tint(.orange)
            }
        }
    }

    private func credentialRow(_ credential: Credential) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.linearGradient(
                        colors: [Cockpit.live.opacity(0.3), Cockpit.live.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 40, height: 40)

                Text(String(credential.username.prefix(1)).uppercased())
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Cockpit.live)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(credential.username)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    if let attempted = attemptCounts[credential.id], attempted > 0 {
                        let total = max(attempted, passwordCounts[credential.id] ?? 0)
                        Text("\(attempted)/\(total) tried")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(Cockpit.live)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Cockpit.live.opacity(0.15)))
                    }
                    if credential.usageCount > 0 {
                        Text("Used \(credential.usageCount)×")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let notes = credential.notes, !notes.isEmpty {
                        Image(systemName: "note.text")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            if !viewModel.isEditMode {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
            }
        }
    }

    // MARK: - Edit-mode glue

    private var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { operationErrorMessage != nil },
            set: { isPresented in
                if !isPresented { operationErrorMessage = nil }
            }
        )
    }

    private func handleDeletionResult(_ failedIDs: [String], operation: String) {
        guard !failedIDs.isEmpty else {
            viewModel.isEditMode = false
            viewModel.clearSelection()
            return
        }
        let noun = failedIDs.count == 1 ? "credential" : "credentials"
        operationErrorMessage = "Could not \(operation) \(failedIDs.count) \(noun). The affected saved data was left in place."
    }

    private func refreshPasswordCounts() async {
        let ids = credentials.map { $0.id }
        let counts = await Task.detached {
            Dictionary(uniqueKeysWithValues: ids.map { ($0, KeychainService.shared.getPasswords(for: $0).count) })
        }.value
        passwordCounts = counts
    }

    private var editModeBinding: Binding<EditMode> {
        Binding(
            get: { viewModel.isEditMode ? .active : .inactive },
            set: { viewModel.isEditMode = ($0 == .active) }
        )
    }
}

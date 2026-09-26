import SwiftUI
import SwiftData

/// One home for everything the app does on its own.
///
/// Until now this was scattered: run results behind a pill button, flagged
/// logins behind a vault menu, the AI brains three levels deep in Settings,
/// and the page scripts themselves nowhere at all. Three segments, one tab.
struct AutomationView: View {
    let viewModel: BrowserViewModel

    enum Segment: String, CaseIterable, Identifiable {
        case runs = "Runs"
        case flagged = "Flagged"
        case brains = "Brains"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .runs: return "list.bullet.rectangle"
            case .flagged: return "exclamationmark.triangle"
            case .brains: return "brain"
            }
        }
    }

    @State private var segment: Segment = .runs
    private let needsReview = NeedsReviewStore.shared

    var body: some View {
        VStack(spacing: 0) {
            picker
            Divider().overlay(Cockpit.hairline)
            content
        }
        .background(Cockpit.canvas.ignoresSafeArea())
        .navigationTitle("Automation")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var picker: some View {
        Picker("Section", selection: $segment) {
            ForEach(Segment.allCases) { seg in
                let count = seg == .flagged ? needsReview.entries.count : 0
                Text(count > 0 ? "\(seg.rawValue) (\(count))" : seg.rawValue)
                    .tag(seg)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Cockpit.Space.base)
        .padding(.vertical, Cockpit.Space.tight)
    }

    @ViewBuilder
    private var content: some View {
        switch segment {
        case .runs:
            ResultsView(isEmbedded: true)
        case .flagged:
            NeedsReviewView(isEmbedded: true)
        case .brains:
            BrainsAndScriptsView(viewModel: viewModel)
        }
    }
}

/// The brains that make decisions, and the scripts that touch the page.
///
/// The routines list at the top is the part that did not exist before: the
/// app injects a lot of behaviour into every page it loads and none of it was
/// visible anywhere, so there was no way to answer "what is this doing, and
/// how do I stop it".
struct BrainsAndScriptsView: View {
    let viewModel: BrowserViewModel

    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\AIProviderConfig.sortOrder)]) private var providers: [AIProviderConfig]
    @Query(sort: [SortDescriptor(\AIRepairEvent.timestamp, order: .reverse)]) private var events: [AIRepairEvent]

    @State private var center = IntelligenceCenter.shared
    @State private var parked = ParkedSessionStore.shared
    @State private var isAddingProvider: Bool = false
    @State private var routeTick: Int = 0
    @State private var expandedRoutine: String?
    @State private var showAdvancedKeys: Bool = false
    @State private var showClearParked: Bool = false
    @State private var showClearLogConfirmation: Bool = false
    @State private var isShowingLedger: Bool = false
    @AppStorage("aiSuccessDetectionMode") private var detectionModeRaw: String = SuccessJudgeEngine.DetectionMode.localAndAI.rawValue

    var body: some View {
        Form {
            routinesSection
            brainsSection
            routingSection
            advancedKeysSection
            activitySection
            parkedSection
        }
        .cockpitScreen()
        .onAppear {
            center.attach(context: modelContext)
            center.refreshProviders()
            center.refreshAvailability()
        }
        .sheet(isPresented: $isAddingProvider) {
            NavigationStack { AddAIProviderView() }
        }
        .sheet(isPresented: $isShowingLedger) {
            NavigationStack {
                FollowLeaderLedgerView(controller: viewModel.quadController)
            }
        }
        .confirmationDialog(
            "Clear all parked sessions?",
            isPresented: $showClearParked,
            titleVisibility: .visible
        ) {
            Button("Clear All Parked", role: .destructive) {
                Task { await parked.clearAll() }
            }
        } message: {
            Text("Closes every parked login and wipes that session's cookies. This cannot be undone.")
        }
    }

    // MARK: - Routines

    private var routinesSection: some View {
        Section {
            ForEach(PageRoutine.all) { routine in
                routineRow(routine)
            }
        } header: {
            Text("What runs on a page")
        } footer: {
            Text("Everything the app does to a page by itself. Tap a row to see when it fires and what it touches.")
        }
    }

    private func routineRow(_ routine: PageRoutine) -> some View {
        let isExpanded = expandedRoutine == routine.id
        return VStack(alignment: .leading, spacing: Cockpit.Space.tight) {
            Button {
                withAnimation(Cockpit.Motion.quick) {
                    expandedRoutine = isExpanded ? nil : routine.id
                }
            } label: {
                HStack(spacing: Cockpit.Space.snug) {
                    Image(systemName: routine.icon)
                        .font(.callout)
                        .foregroundStyle(routine.tint)
                        .frame(width: 24)
                    Text(routine.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Cockpit.textPrimary)
                    Spacer(minLength: Cockpit.Space.tight)
                    statusChip(for: routine)
                    Image(systemName: "chevron.down")
                        .font(.caption2.bold())
                        .foregroundStyle(Cockpit.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: Cockpit.Space.tight) {
                    Text(routine.what)
                        .font(.caption)
                        .foregroundStyle(Cockpit.textSecondary)
                    Label(routine.when, systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(Cockpit.textTertiary)
                    routineControl(routine)
                }
                .padding(.leading, 36)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 2)
    }

    /// Whether the routine is currently live, as a chip rather than buried in
    /// the expanded detail — the list is meant to answer "what is on" at a
    /// glance.
    @ViewBuilder
    private func statusChip(for routine: PageRoutine) -> some View {
        switch routine.control {
        case .toggle(let key, let defaultOn):
            chip(isOn(key: key, defaultOn: defaultOn) ? "On" : "Off",
                 tint: isOn(key: key, defaultOn: defaultOn) ? routine.tint : Cockpit.textTertiary)
        case .cardAutoFill:
            chip(CardVault.shared.isAutoFillArmed ? "Armed" : "On tap",
                 tint: CardVault.shared.isAutoFillArmed ? Cockpit.card : Cockpit.textTertiary)
        case .successDetection:
            chip(SuccessJudgeEngine.DetectionMode(rawValue: detectionModeRaw)?.label ?? "On",
                 tint: Cockpit.success)
        case .followLeaderMode:
            let mode = viewModel.quadController.followLeaderMode
            chip(mode.label, tint: mode.isStrict ? Cockpit.live : Cockpit.textTertiary)
        case .core:
            chip("Core", tint: Cockpit.textTertiary)
        }
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.16)))
    }

    /// The routine's off switch, shown right next to its description so the
    /// control and the explanation are never in two different screens again.
    @ViewBuilder
    private func routineControl(_ routine: PageRoutine) -> some View {
        switch routine.control {
        case .toggle(let key, let defaultOn):
            Toggle(isOn: defaultsBinding(key: key, defaultOn: defaultOn)) {
                Text("Let this run")
                    .font(.caption.weight(.semibold))
            }
        case .cardAutoFill:
            Toggle(isOn: Binding(
                get: { CardVault.shared.isAutoFillArmed },
                set: { CardVault.shared.isAutoFillArmed = $0 }
            )) {
                Text("Fill by itself on checkout pages")
                    .font(.caption.weight(.semibold))
            }
        case .successDetection:
            Picker("How", selection: $detectionModeRaw) {
                ForEach(SuccessJudgeEngine.DetectionMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .pickerStyle(.menu)
            .font(.caption)
        case .followLeaderMode:
            followLeaderModeControl
        case .core(let note):
            Text(note)
                .font(.caption2)
                .foregroundStyle(Cockpit.textTertiary)
        }
    }

    /// How faithfully the leader is copied, plus the way into the ledger.
    ///
    /// The picker writes through the controller rather than straight to
    /// defaults on purpose: switching mid-flow has to be refused while windows
    /// are still catching up, and only the controller knows that.
    @ViewBuilder
    private var followLeaderModeControl: some View {
        let controller = viewModel.quadController
        VStack(alignment: .leading, spacing: Cockpit.Space.tight) {
            Picker("How exactly", selection: Binding(
                get: { controller.followLeaderMode },
                set: { controller.setFollowLeaderMode($0) }
            )) {
                ForEach(FollowLeaderSyncMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(controller.followLeaderMode.blurb)
                .font(.caption2)
                .foregroundStyle(Cockpit.textTertiary)
            Button {
                isShowingLedger = true
            } label: {
                Label("Sync Ledger", systemImage: "list.bullet.rectangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Cockpit.live)
            }
            .buttonStyle(.plain)
            Text("Switched on and off from the address bar menu.")
                .font(.caption2)
                .foregroundStyle(Cockpit.textTertiary)
        }
    }

    private func isOn(key: String, defaultOn: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultOn
    }

    private func defaultsBinding(key: String, defaultOn: Bool) -> Binding<Bool> {
        Binding(
            get: { isOn(key: key, defaultOn: defaultOn) },
            set: { UserDefaults.standard.set($0, forKey: key) }
        )
    }

    // MARK: - Brains

    private var brainsSection: some View {
        Section {
            brainRow(
                icon: "cloud.fill",
                tint: Cockpit.live,
                title: "Rork AI Cloud",
                note: center.rorkCloudNote,
                isReady: center.rorkCloudAvailable
            )
            brainRow(
                icon: "iphone",
                tint: Cockpit.live,
                title: "Apple on-device",
                note: center.onDeviceNote,
                isReady: center.onDeviceAvailable
            )
            brainRow(
                icon: "icloud",
                tint: Cockpit.laneA,
                title: "Apple Private Cloud",
                note: center.appleCloudNote,
                isReady: center.appleCloudAvailable
            )
        } header: {
            Text("Brains")
        } footer: {
            Text("Jobs use Rork AI Cloud first (built in — no setup), then Apple's on-device model when offline. Apple Private Cloud needs iOS 27 and Apple's signing entitlement — it is not available on this build. Passwords and field contents are never sent to any AI — only page structure and visible text.")
        }
    }

    private func brainRow(icon: String, tint: Color, title: String, note: String, isReady: Bool) -> some View {
        HStack(spacing: Cockpit.Space.snug) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Cockpit.textSecondary)
            }
            Spacer()
            Circle()
                .fill(isReady ? Cockpit.success : Cockpit.textTertiary)
                .frame(width: 8, height: 8)
        }
    }

    private var routingSection: some View {
        Section {
            ForEach(IntelligenceCenter.AIJob.allCases) { job in
                Picker(job.label, selection: routeBinding(for: job)) {
                    ForEach(IntelligenceCenter.AIBrain.allCases) { brain in
                        Text(brain.label).tag(brain)
                    }
                }
            }
            .id(routeTick)
        } header: {
            Text("Which brain does what")
        } footer: {
            Text("Every job defaults to Rork AI Cloud and falls over automatically. Choose \"On-device\" everywhere for fully local-only AI.")
        }
    }

    private var advancedKeysSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showAdvancedKeys) {
                brainRow(
                    icon: "key.fill",
                    tint: Cockpit.attention,
                    title: "Your API keys",
                    note: center.hasUsableKeys
                        ? "\(center.providers.filter { $0.keyCount > 0 }.count) provider(s) configured"
                        : "No keys yet — add a provider below",
                    isReady: center.hasUsableKeys
                )
                if providers.isEmpty {
                    Text("No providers yet")
                        .foregroundStyle(Cockpit.textSecondary)
                }
                ForEach(providers) { provider in
                    NavigationLink {
                        EditAIProviderView(config: provider)
                    } label: {
                        providerRow(provider)
                    }
                }
                .onDelete(perform: deleteProviders)
                .onMove(perform: moveProviders)

                Button {
                    isAddingProvider = true
                } label: {
                    Label("Add Provider…", systemImage: "plus.circle.fill")
                        .foregroundStyle(Cockpit.live)
                }
            } label: {
                Label("Advanced — your own API keys", systemImage: "key.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Cockpit.textPrimary)
            }
        } footer: {
            Text("Bring your own OpenAI-compatible provider if you prefer it over the built-in cloud. Providers are tried in the order shown; keys inside a provider rotate automatically when one is rate-limited.")
        }
    }

    private func providerRow(_ provider: AIProviderConfig) -> some View {
        VStack(alignment: .leading, spacing: Cockpit.Space.hair) {
            HStack(spacing: Cockpit.Space.tight) {
                Text(provider.displayName)
                    .font(.body.weight(.semibold))
                if !provider.isEnabled {
                    Text("OFF")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Cockpit.attention)
                }
                if provider.lastTestOK {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Cockpit.success)
                        .font(.caption)
                }
            }
            Text("\(provider.modelName) · \(provider.keyCount) key\(provider.keyCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(Cockpit.textSecondary)
        }
    }

    private var activitySection: some View {
        Section {
            if events.isEmpty {
                Text("No AI activity yet")
                    .foregroundStyle(Cockpit.textSecondary)
            } else {
                ForEach(events.prefix(20)) { event in
                    HStack(alignment: .top, spacing: Cockpit.Space.tight + 2) {
                        Image(systemName: icon(for: event.kind))
                            .foregroundStyle(color(for: event.kind))
                            .font(.callout)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.summary)
                                .font(.caption)
                            Text("\(event.brain) · \(event.timestamp.formatted(.relative(presentation: .named)))")
                                .font(.caption2)
                                .foregroundStyle(Cockpit.textSecondary)
                        }
                    }
                }
                Button("Clear Log", role: .destructive) {
                    showClearLogConfirmation = true
                }
                .confirmationDialog(
                    "Clear the AI activity log?",
                    isPresented: $showClearLogConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Clear Log", role: .destructive) {
                        for event in events { modelContext.delete(event) }
                        try? modelContext.save()
                    }
                } message: {
                    Text("Removes every repair and verdict entry. This can't be undone.")
                }
            }
        } header: {
            Text("What the AI actually did")
        } footer: {
            Text("Every repair and verdict the AI makes, in plain English.")
        }
    }

    private var parkedSection: some View {
        Section {
            LabeledContent("Parked sessions", value: "\(parked.sessions.count)")
            Button("Clear All Parked", role: .destructive) {
                showClearParked = true
            }
            .disabled(parked.sessions.isEmpty)
        } header: {
            Text("Parked Sessions")
        } footer: {
            Text("Clearing parked sessions closes them and wipes each isolated cookie store. The vault is not touched.")
        }
    }

    // MARK: - Actions

    private func routeBinding(for job: IntelligenceCenter.AIJob) -> Binding<IntelligenceCenter.AIBrain> {
        Binding(
            get: { center.preferredBrain(for: job) },
            set: { newValue in
                UserDefaults.standard.set(newValue.rawValue, forKey: job.settingsKey)
                routeTick &+= 1
            }
        )
    }

    private func deleteProviders(at offsets: IndexSet) {
        for index in offsets where providers.indices.contains(index) {
            let provider = providers[index]
            LLMKeyVault.shared.deleteAllKeys(providerID: provider.id)
            modelContext.delete(provider)
        }
        try? modelContext.save()
        center.refreshProviders()
    }

    private func moveProviders(from source: IndexSet, to destination: Int) {
        var reordered = providers
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, provider) in reordered.enumerated() {
            provider.sortOrder = index
        }
        try? modelContext.save()
        center.refreshProviders()
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "heal": return "wrench.and.screwdriver"
        case "judge": return "checkmark.shield"
        default: return "info.circle"
        }
    }

    private func color(for kind: String) -> Color {
        switch kind {
        case "heal": return Cockpit.live
        case "judge": return Cockpit.success
        default: return Cockpit.textSecondary
        }
    }
}

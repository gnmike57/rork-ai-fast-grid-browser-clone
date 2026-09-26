import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import WebKit

struct BrowserView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State var viewModel = BrowserViewModel()
    @FocusState var isURLBarFocused: Bool
    @FocusState var isURLBarBFocused: Bool

    // Swipe-to-hide state for the live RCR queue pill(s).
    @State var singlePillHidden: Bool = false
    @State private var singlePillDrag: CGFloat = 0
    @State var quadPillsHidden: [Bool] = Array(repeating: false, count: QuadDataStore.maxSessionCount)
    @State var quadPillsDrag: [CGFloat] = Array(repeating: 0, count: QuadDataStore.maxSessionCount)
    // Larger grids show a compact summary bar instead of a wall of per-window
    // cards; tapping it expands to the same detailed view.
    @State var isQuadDetailExpanded: Bool = false
    @State var showBurnConfirmation: Bool = false
    /// Which destination the tab bar is showing. Browse stays mounted
    /// underneath every other tab, so switching never tears down a web view.
    @State private var selectedTab: CockpitTab = .browse
    @State private var isBottomChromeVisible: Bool = true
    // Card fill button feedback — a press should register instantly, well
    // before the injected fill has had time to report back.
    @State private var cardFillPulse: Int = 0
    @State private var cardPressed: Bool = false
    let diagnostics = WindowDiagnosticsService.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            // Browse is always mounted. Every other destination draws on top
            // of it rather than replacing it, so changing tabs mid-run can
            // never kill a web view or lose a queue.
            browseLayer

            if selectedTab != .browse {
                destinationLayer
                    .transition(.opacity)
                    .zIndex(50)
            }

            if selectedTab == .browse {
                runOverlays
                    .zIndex(99)
            }

            if viewModel.toastVisible, let message = viewModel.toastMessage {
                ToastView(message: message)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(100)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomChrome
        }
        .animation(Cockpit.Motion.panel, value: selectedTab)
        .onChange(of: viewModel.quadMode) { _, _ in
            isQuadDetailExpanded = false
            quadPillsHidden = Array(repeating: false, count: QuadDataStore.maxSessionCount)
            quadPillsDrag = Array(repeating: 0, count: QuadDataStore.maxSessionCount)
        }
        .onChange(of: viewModel.quadController.focusedIndex) { _, _ in
            if viewModel.isQuadMode, !viewModel.isURLBarEditing {
                viewModel.updateURLBar()
            }
        }
        .onChange(of: viewModel.isRCRRunning) { _, running in
            if running { isURLBarFocused = false; isURLBarBFocused = false; dismissKeyboard() }
        }
        .onChange(of: viewModel.quadController.anyRCRRunning) { _, running in
            if running { isURLBarFocused = false; isURLBarBFocused = false; dismissKeyboard() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Save as soon as the app starts leaving the foreground —
            // waiting for full backgrounding risks missing the write if
            // the process is terminated quickly.
            if phase != .active { viewModel.saveSessionSnapshot() }
        }
        .overlay(alignment: .top) {
            if let snapshot = viewModel.pendingRestoreSnapshot {
                RestoreSessionCard(
                    snapshot: snapshot,
                    onRestore: { viewModel.restorePendingSession() },
                    onDismiss: { viewModel.dismissPendingSession() }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.pendingRestoreSnapshot)
        .task {
            viewModel.setup(modelContext: modelContext)
            CardVault.shared.attach(modelContext: modelContext)
            await WebViewConfigurationFactory.shared.prepare()
            // Pre-connecting pings the user's most-visited sites at launch —
            // opt-in only (Settings → Browser).
            if UserDefaults.standard.bool(forKey: "dnsPrewarmEnabled") {
                DNSPrewarmService.shared.prewarmTopDomains(modelContext: modelContext)
            }
        }
        .sheet(item: $viewModel.presentedSheet, onDismiss: {
            viewModel.reloadExcludedDomains()
        }) { sheet in
            sheetContent(for: sheet)
        }
        .alert("Save Login?", isPresented: $viewModel.isShowingSaveCredentialAlert) {
            Button("Save") { viewModel.saveDetectedCredential() }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Save credentials for \(viewModel.detectedDomain.isEmpty ? (viewModel.activeTab?.domain ?? "this site") : viewModel.detectedDomain)?\nUsername: \(viewModel.detectedUsername)")
        }
        .fileExporter(
            isPresented: $viewModel.isExportingSession,
            document: viewModel.sessionExportDocument,
            contentType: .json,
            defaultFilename: viewModel.sessionExportDefaultName
        ) { result in
            viewModel.finishSessionExport(result)
        }
        .fileImporter(
            isPresented: $viewModel.isImportingSession,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            viewModel.handleSessionImport(result)
        }
        .confirmationDialog(
            "Burn this session?",
            isPresented: $showBurnConfirmation,
            titleVisibility: .visible
        ) {
            Button("Burn", role: .destructive) {
                viewModel.burnCurrentTab()
            }
        } message: {
            Text("Wipes cookies and cached data for this session and reloads it. This can't be undone.")
        }
    }

    /// Carries the current URL into quad mode without toggling (used when
    /// onChange fires from external sources).
    @ViewBuilder
    private func sheetContent(for sheet: PresentedSheet) -> some View {
        switch sheet {
        case .tabs:
            TabManagerView(viewModel: viewModel)
        case .vault:
            NavigationStack { VaultView() }
        case .cards:
            NavigationStack { CardsView(viewModel: viewModel) }
        case .siteSettings(let domain):
            NavigationStack { SiteSettingsView(domain: domain, viewModel: viewModel) }
        case .settings:
            NavigationStack { AppSettingsView() }
        case .bookmarks:
            NavigationStack { BookmarksView(viewModel: viewModel) }
        case .history:
            NavigationStack { HistoryView(viewModel: viewModel) }
        case .results:
            NavigationStack { ResultsView() }
        case .needsReview:
            NavigationStack { NeedsReviewView() }
        }
    }


    // MARK: - Layers

    /// Browse: address bars, progress and the page itself.
    private var browseLayer: some View {
        VStack(spacing: 0) {
            urlBar
            if viewModel.isDualQuadMode {
                urlBarB
            }
            progressBar
            webContent
        }
    }

    /// Whichever destination the tab bar has selected, drawn over the browser.
    @ViewBuilder
    private var destinationLayer: some View {
        ZStack {
            Cockpit.canvas.ignoresSafeArea()
            switch selectedTab {
            case .browse:
                EmptyView()
            case .vault:
                NavigationStack { VaultView(isEmbedded: true) }
            case .cards:
                NavigationStack { CardsView(isEmbedded: true, viewModel: viewModel) }
            case .automation:
                NavigationStack { AutomationView(viewModel: viewModel) }
            case .settings:
                NavigationStack { AppSettingsView(isEmbedded: true) }
            }
        }
    }

    /// Live run progress — one pill in single-window mode, the summary bar on
    /// a grid. Only over Browse; the other tabs have their own content.
    @ViewBuilder
    private var runOverlays: some View {
        if viewModel.isRCRRunning || (viewModel.rcrTotal > 0 && !viewModel.isQuadMode) {
            SwipeToHide(
                isVisible: singlePillVisible,
                edge: .bottom,
                restore: .labelled("RCR queue"),
                accessibilityLabel: "Show RCR queue"
            ) {
                singleQueuePill
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if viewModel.isQuadMode && (viewModel.quadController.anyRCRRunning || viewModel.quadController.activeSessions.contains(where: { $0.rcrTotal > 0 })) {
            quadSummarySection
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// `SwipeToHide` owns a plain Bool; the pill state predates it as a pair
    /// of arrays, so this bridges the two without changing either.
    private var singlePillVisible: Binding<Bool> {
        Binding(
            get: { !singlePillHidden },
            set: { singlePillHidden = !$0 }
        )
    }

    // MARK: - Bottom chrome

    /// The action dock and the tab bar: where you go, and what you do, kept
    /// as two clearly separate layers rather than one row of eight controls.
    private var bottomChrome: some View {
        SwipeToHide(
            isVisible: $isBottomChromeVisible,
            edge: .bottom,
            restore: .grabber,
            accessibilityLabel: "Show the toolbar"
        ) {
            VStack(spacing: Cockpit.Space.tight) {
                if selectedTab == .browse {
                    HStack {
                        Spacer(minLength: 0)
                        actionDock
                    }
                    .padding(.horizontal, Cockpit.Space.base)
                }
                CockpitTabBar(selection: $selectedTab, badges: tabBadges)
            }
            .padding(.bottom, Cockpit.Space.hair)
        }
    }

    /// Counts worth surfacing without opening the tab: saved cards, and
    /// logins the run flagged for a human.
    private var tabBadges: [CockpitTab: Int] {
        var badges: [CockpitTab: Int] = [:]
        let cards = CardVault.shared.count
        if cards > 0 { badges[.cards] = cards }
        let flagged = NeedsReviewStore.shared.entries.count
        if flagged > 0 { badges[.automation] = flagged }
        return badges
    }

    /// Fills every live window with its assigned card. Tap fills now; hold
    /// opens the mode, arming, rotation and wallet options — the same split a
    /// browser uses for its own autofill button.
    private var actionDock: some View {
        let vault = CardVault.shared
        return ActionDock(
            isRunning: viewModel.isRCRRunning,
            runProgress: rcrProgressFraction,
            cardCount: vault.count,
            isAutoFillArmed: vault.isAutoFillArmed,
            cardPressPulse: cardFillPulse,
            onRun: { viewModel.toggleRCR() },
            onFillCards: {
                cardFillPulse &+= 1
                if vault.isEmpty {
                    selectedTab = .cards
                } else {
                    viewModel.fillCardsEverywhere()
                }
            },
            cardMenu: { cardMenuContent }
        )
        .sensoryFeedback(.impact(weight: .light), trigger: viewModel.rcrIndex)
        .sensoryFeedback(.success, trigger: viewModel.rcrStatus == .success)
        .sensoryFeedback(.impact(weight: .heavy), trigger: viewModel.rcrBurnFlash)
        .sensoryFeedback(.impact(weight: .medium), trigger: cardFillPulse)
    }

    @ViewBuilder
    private var cardMenuContent: some View {
        let vault = CardVault.shared
        Section("Mode") {
            Picker("Mode", selection: cardModeBinding) {
                ForEach(CardFillMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.iconName).tag(mode)
                }
            }
            .pickerStyle(.inline)
        }
        Section {
            Button {
                viewModel.toggleCardAutoFill()
            } label: {
                Label(
                    vault.isAutoFillArmed ? "Auto-fill on checkout: On" : "Auto-fill on checkout",
                    systemImage: vault.isAutoFillArmed ? "checkmark.circle.fill" : "wand.and.sparkles"
                )
            }
            if vault.mode == .rotate && vault.count > 1 {
                Button("Next Set", systemImage: "arrow.forward.circle") {
                    viewModel.advanceCardRotation()
                }
            }
            Button("Fill This Window Only", systemImage: "rectangle.inset.filled") {
                cardFillPulse &+= 1
                viewModel.fillCardInFocusedWindow()
            }
        }
        Section {
            Button("Open Cards", systemImage: "creditcard") {
                selectedTab = .cards
            }
        }
    }

    private var cardModeBinding: Binding<CardFillMode> {
        Binding(
            get: { CardVault.shared.mode },
            set: { viewModel.setCardFillMode($0) }
        )
    }

    private var rcrProgressFraction: CGFloat {
        guard viewModel.rcrTotal > 0 else { return 0 }
        return CGFloat(min(viewModel.rcrIndex, viewModel.rcrTotal)) / CGFloat(viewModel.rcrTotal)
    }

    var quadModeToggle: some View {
        Menu {
            modeMenuItem(title: "Single Window", isSelected: viewModel.quadMode == .single) {
                viewModel.setQuadMode(.single)
            }
            ForEach(WindowGridSize.allCases) { size in
                Section("\(size.rawValue) Windows (\(size.label))") {
                    modeMenuItem(
                        title: "Single Site",
                        isSelected: viewModel.quadMode == .grid(size, dual: false)
                    ) {
                        viewModel.setQuadMode(.grid(size, dual: false))
                    }

                    if size.supportsDualSite {
                        Menu("Dual Site") {
                            // Only the splits that genuinely halve *this*
                            // shape. On a three-column grid "Left / Right"
                            // cannot, so offering it there would promise an
                            // arrangement the layout can't produce.
                            ForEach(DualSiteSplitPattern.available(for: size)) { pattern in
                                modeMenuItem(
                                    title: pattern.label,
                                    isSelected: viewModel.quadMode == .grid(size, dual: true)
                                        && viewModel.dualSiteSplitPattern == pattern
                                ) {
                                    viewModel.setDualSiteSplitPattern(pattern)
                                    viewModel.setQuadMode(.grid(size, dual: true))
                                }
                            }
                        }
                        if size == .nine {
                            Text("Center window unused")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Session Carry-Over") {
                Toggle(isOn: Binding(
                    get: { viewModel.cloneSessionToAllWindows },
                    set: { viewModel.setCloneSessionToAllWindows($0) }
                )) {
                    Label("Clone session from Window 1", systemImage: "person.2.fill")
                }
                Button {
                    viewModel.cloneSessionNow()
                } label: {
                    Label("Clone Window 1 to all windows now", systemImage: "square.on.square.dashed")
                }
                .disabled(!viewModel.isQuadMode)
            }
        } label: {
            quadModeIcon
        }
        .simultaneousGesture(TapGesture().onEnded {
            isURLBarFocused = false
            dismissKeyboard()
        })
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func modeMenuItem(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isSelected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var quadModeIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .stroke(quadModeStrokeColor, lineWidth: 1.5)
                .frame(width: 28, height: 28)

            switch viewModel.quadMode {
            case .single:
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Cockpit.live)
                    .frame(width: 14, height: 14)
            case .grid(let size, let dual):
                VStack(spacing: 1.5) {
                    ForEach(0..<size.rows, id: \.self) { row in
                        HStack(spacing: 1.5) {
                            ForEach(0..<size.columns, id: \.self) { column in
                                let index = row * size.columns + column
                                let targetSite = viewModel.dualSiteSplitPattern.targetSiteIndex(
                                    for: index,
                                    in: size
                                )
                                if dual && targetSite == -1 {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color.secondary.opacity(0.3))
                                } else {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(dual ? (targetSite == 0 ? Color.purple : Color.orange) : Cockpit.live)
                                }
                            }
                        }
                    }
                }
                .frame(width: 18, height: 18)
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }

    private var quadModeStrokeColor: Color {
        switch viewModel.quadMode {
        case .single: return .secondary.opacity(0.5)
        case .grid(_, let dual): return dual ? .purple : Cockpit.live
        }
    }


    // MARK: - Page menu

    /// Follow the Leader's menu row, which says which fidelity is armed as
    /// well as whether the mode is on — "On" alone would leave the two very
    /// different contracts indistinguishable from the one place the mode is
    /// actually switched.
    var followLeaderMenuTitle: String {
        let controller = viewModel.quadController
        guard controller.isFollowLeaderEnabled else { return "Follow the Leader" }
        return "Follow the Leader: \(controller.followLeaderMode.label)"
    }

    /// Everything that acts on the page you are looking at.
    ///
    /// This replaces the old hamburger, which sat in the bottom bar and mixed
    /// page actions with app destinations. The destinations are now tabs, so
    /// only page actions are left — including Burn, which was previously a
    /// permanent button wedged between the two most-pressed controls in the
    /// app despite destroying a whole session.
    @ViewBuilder
    var pageMenu: some View {
        Section {
            Button("Back", systemImage: "chevron.left") { viewModel.goBack() }
                .disabled(!canGoBack)
            Button("Forward", systemImage: "chevron.right") { viewModel.goForward() }
                .disabled(!canGoForward)
            Button("Reload", systemImage: "arrow.clockwise") { viewModel.reload() }
            Button("Home", systemImage: "house") { viewModel.goHome() }
        }
        Section {
            Button("New Tab", systemImage: "plus") { viewModel.addNewTab() }
            Button("Tabs (\(viewModel.tabs.count))", systemImage: "square.on.square") {
                viewModel.presentedSheet = .tabs
            }
            Button("Bookmarks", systemImage: "bookmark") {
                viewModel.presentedSheet = .bookmarks
            }
            Button("History", systemImage: "clock") {
                viewModel.presentedSheet = .history
            }
            Button("Add Bookmark", systemImage: "bookmark.fill") {
                viewModel.addBookmark()
            }
            if let shareURL = viewModel.currentPageURL {
                ShareLink(item: shareURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        Section("Session") {
            Button {
                viewModel.toggleReplayMode()
            } label: {
                Label(
                    "Session Deck (\(viewModel.replayDeck.count))",
                    systemImage: viewModel.isReplayMode ? "circle.grid.3x3.fill" : "circle.grid.3x3"
                )
            }
            // One source of truth for whether this layout can follow a
            // leader. The view model's own dual-site flag and the
            // controller's could disagree after a same-size re-pick, which
            // offered the mode here and then refused it on tap.
            if viewModel.quadController.canOfferFollowLeader
                || viewModel.quadController.isFollowLeaderEnabled {
                Button {
                    viewModel.quadController.toggleFollowLeader()
                } label: {
                    Label(
                        followLeaderMenuTitle,
                        systemImage: viewModel.quadController.isFollowLeaderEnabled ? "checkmark.circle.fill" : "person.2.wave.2"
                    )
                }
            }
            if !viewModel.isQuadMode {
                Button("Save Session", systemImage: "square.and.arrow.down") {
                    viewModel.prepareSessionExport()
                }
            }
            Button("Load Session", systemImage: "square.and.arrow.up") {
                viewModel.startSessionImport()
            }
        }
        Section {
            Button("Site Settings", systemImage: "gearshape") {
                if let domain = viewModel.activeTab?.domain, !domain.isEmpty {
                    viewModel.presentedSheet = .siteSettings(domain)
                }
            }
            Button {
                diagnostics.overlayEnabled.toggle()
            } label: {
                Label(
                    diagnostics.overlayEnabled ? "Hide Diagnostics" : "Show Diagnostics",
                    systemImage: "memorychip"
                )
            }
        }
        Section {
            Button("Burn Session", systemImage: "flame.fill", role: .destructive) {
                showBurnConfirmation = true
            }
        }
    }

    var isAnyRCRRunning: Bool {
        viewModel.isRCRRunning || viewModel.quadController.anyRCRRunning
    }

    var canGoBack: Bool {
        if viewModel.isReplayMode {
            return viewModel.replayTab?.canGoBack == true
        }
        if viewModel.isQuadMode {
            return viewModel.quadController.focusedSession.canGoBack
        }
        return viewModel.activeTab?.canGoBack == true
    }

    var canGoForward: Bool {
        if viewModel.isReplayMode {
            return viewModel.replayTab?.canGoForward == true
        }
        if viewModel.isQuadMode {
            return viewModel.quadController.focusedSession.canGoForward
        }
        return viewModel.activeTab?.canGoForward == true
    }

    var isCurrentPageLoading: Bool {
        if viewModel.isReplayMode {
            return viewModel.replayTab?.isLoading == true
        }
        if viewModel.isQuadMode {
            return viewModel.quadController.focusedSession.isLoading
        }
        return viewModel.activeTab?.isLoading == true
    }

    func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }
}

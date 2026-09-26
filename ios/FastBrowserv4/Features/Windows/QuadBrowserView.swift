import SwiftUI
import WebKit

/// A single cell of the Quad-Mode grid. Owns its own `WKWebView` backed by
/// the session's isolated `WKWebsiteDataStore` so cookies, cache and storage
/// are completely separated from the other three cells.
struct QuadCellWebView: UIViewRepresentable {
    let session: QuadSession
    let controller: QuadController

    func makeUIView(context: Context) -> WKWebView {
        let config = WebViewConfigurationFactory.shared.makeIsolatedConfiguration(dataStoreID: session.storeID)
        config.userContentController.add(context.coordinator, name: "rcrObserver")
        config.userContentController.add(context.coordinator, name: "followLeader")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        // KVO for live estimatedProgress so the per-cell progress bar
        // tracks the actual load progression instead of staying at 0.
        webView.addObserver(context.coordinator, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: .new, context: nil)

        context.coordinator.isObservingProgress = true
        context.coordinator.ownedWebView = webView
        session.webView = webView
        // A window holding for a cloned session stays blank until the clone
        // seats its cookies — loading now would render it signed out.
        if let url = session.url, !session.isRestoringSession {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard session.webView !== webView else { return }
        // Full teardown/re-wire of the previous view: just stripping script
        // handlers leaves the KVO observer registered on the old web view
        // (crash on dealloc) and the new view without its rcrObserver.
        if let old = context.coordinator.ownedWebView, old !== webView {
            old.removeObserver(context.coordinator, forKeyPath: #keyPath(WKWebView.estimatedProgress), context: nil)
            old.configuration.userContentController.removeAllScriptMessageHandlers()
            old.navigationDelegate = nil
        }
        // SwiftUI can hand the same web view back here more than once while
        // `session.webView` still points elsewhere — a rebuilt cell, or a
        // store swap that raced the layout pass. Registering on top of an
        // existing registration adds a second KVO observation and a duplicate
        // handler pair, and the single `removeObserver` at dismantle then
        // leaves one behind, which traps when the view deallocates. Removing
        // first makes this idempotent: the view ends up registered exactly
        // once no matter how often it arrives.
        context.coordinator.detachObserver(from: webView)
        webView.configuration.userContentController.removeAllScriptMessageHandlers()

        webView.addObserver(context.coordinator, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: .new, context: nil)
        context.coordinator.isObservingProgress = true
        webView.configuration.userContentController.add(context.coordinator, name: "rcrObserver")
        webView.configuration.userContentController.add(context.coordinator, name: "followLeader")
        webView.navigationDelegate = context.coordinator
        context.coordinator.ownedWebView = webView
        session.webView = webView
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detachObserver(from: webView)
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
        coordinator.ownedWebView = nil
        coordinator.session.webView = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, controller: controller)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let session: QuadSession
        weak var controller: QuadController?
        /// Stored reference to clean up the script message handler on dismantle.
        weak var ownedWebView: WKWebView?
        /// Whether a KVO observation is currently registered. Tracked rather
        /// than assumed: `removeObserver` on a view that was never observed
        /// traps just as hard as leaving one registered does.
        var isObservingProgress: Bool = false

        init(session: QuadSession, controller: QuadController) {
            self.session = session
            self.controller = controller
        }

        /// Removes our progress observation from `webView`, if we have one.
        /// Safe to call repeatedly — which is what makes registration
        /// idempotent at every entry point.
        func detachObserver(from webView: WKWebView) {
            guard isObservingProgress else { return }
            isObservingProgress = false
            webView.removeObserver(
                self,
                forKeyPath: #keyPath(WKWebView.estimatedProgress),
                context: nil
            )
        }

        nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                session.isLoading = true
                session.loadFailed = false
                session.estimatedProgress = 0
                session.canGoBack = webView.canGoBack
                session.canGoForward = webView.canGoForward
                if controller?.focusedIndex == session.index {
                    controller?.hostBrowser?.updateURLBar()
                }
            }
        }

        nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            Task { @MainActor in
                session.url = webView.url
                session.title = webView.title ?? "Loading…"
                session.canGoBack = webView.canGoBack
                session.canGoForward = webView.canGoForward
                // A committed document means the replacement web process is
                // alive, so mirrored actions held back by the crash can flow
                // again.
                session.flRecovering = false
                if controller?.focusedIndex == session.index {
                    controller?.hostBrowser?.updateURLBar()
                }
                // Arm the Follow the Leader recorder the moment the new
                // document exists, so actions taken while the page is still
                // coming up are mirrored instead of dropped.
                controller?.followLeaderCellDidCommit(session: session)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                session.isLoading = false
                session.loadFailed = false
                session.estimatedProgress = 1.0
                session.url = webView.url
                session.title = webView.title ?? session.domain
                session.canGoBack = webView.canGoBack
                session.canGoForward = webView.canGoForward
                // Keep the shared address bar in sync when the focused tile
                // finishes a load (back/forward, link taps, form submits).
                if controller?.focusedIndex == session.index {
                    controller?.hostBrowser?.updateURLBar()
                }
                controller?.cellPageDidFinish(session: session)
                WindowDiagnosticsService.shared.pageDidFinish(session: session)
                // Re-arm the Follow the Leader recorder on the leader window.
                controller?.followLeaderCellDidFinish(session: session)
                // Restore queued session storage once this window lands on
                // the saved origin (Load Session flow).
                SessionTransferService.shared.applyPendingStorageIfNeeded(
                    storeID: session.storeID,
                    webView: webView
                )
                // Page-load autofill for multi-window tiles (skips while any
                // RCR run is active).
                if !session.rcrRunning {
                    controller?.handleQuadPageLoadAutofill(for: session)
                    // Card autofill, only when the user armed it. The injected
                    // pass reports zero and does nothing on a page with no
                    // card fields, so this is inert everywhere but a checkout.
                    controller?.autoFillCardIfArmed(session: session)
                }
            }
        }

        /// The window's web content process died — most likely memory
        /// pressure on a big grid of full-size pages. Left alone the tile
        /// stays blank forever and Follow the Leader keeps firing actions
        /// into a corpse, burning every retry and timeout before flagging.
        nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            Task { @MainActor in
                controller?.webContentProcessDidTerminate(session: session, webView: webView)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let isCancellation = (error as NSError).code == NSURLErrorCancelled
            Task { @MainActor in
                session.isLoading = false
                session.estimatedProgress = 1.0
                // A deliberate cancellation (new navigation superseding this
                // one, a burn, RCR stop) is not a load failure — only a real
                // error should offer a retry.
                if !isCancellation { session.loadFailed = true }
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let isCancellation = (error as NSError).code == NSURLErrorCancelled
            Task { @MainActor in
                session.isLoading = false
                session.estimatedProgress = 1.0
                if !isCancellation { session.loadFailed = true }
            }
        }

        nonisolated func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            let navType = await MainActor.run { navigationAction.navigationType }
            if navType == .formSubmitted {
                await MainActor.run {
                    if controller?.anyRCRRunning != true {
                        controller?.detectAndOfferSaveQuad(session: session)
                    }
                }
            }
            return .allow
        }

        // KVO handler for WKWebView.estimatedProgress.
        nonisolated override func observeValue(
            forKeyPath keyPath: String?,
            of object: Any?,
            change: [NSKeyValueChangeKey: Any]?,
            context: UnsafeMutableRawPointer?
        ) {
            // NOTE: plain string literal — under Swift 6 a #keyPath to the
            // main-actor-isolated property can't be formed from this
            // nonisolated KVO entry point.
            guard keyPath == "estimatedProgress",
                  let webView = object as? WKWebView else {
                super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
                return
            }
            Task { @MainActor in
                session.estimatedProgress = webView.estimatedProgress
            }
        }

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            // WKScriptMessage's properties are main-actor-isolated, so every
            // read happens after the hop instead of before it.
            Task { @MainActor in
                let name = message.name
                guard name == "rcrObserver" || name == "followLeader" else { return }
                let body = message.body as? [String: Any] ?? [:]
                let originHost = message.frameInfo.securityOrigin.host
                switch name {
                case "rcrObserver":
                    // Origin gate: only the run's target host may drive RCR
                    // state — a forged `hasDisabled` post from any other
                    // origin would otherwise trigger vault auto-deletion.
                    guard BrowserViewModel.isTrustedRCROrigin(
                        originHost,
                        targetHost: session.rcrTargetURL?.host(percentEncoded: false)
                    ) else { return }
                    controller?.handleRCRMessage(session: session, payload: body)
                case "followLeader":
                    controller?.handleFollowLeaderEvent(session: session, payload: body)
                default:
                    break
                }
            }
        }
    }
}

/// Grid of isolated browser sessions — 2×2, 2×3, 4×2, 3×3, 3×4, or 4×4 depending
/// on the active `WindowGridSize`. The cell that's currently "focused" (tap to
/// switch) gets a cyan ring and is the target for the shared URL bar /
/// toolbar.
///
/// In Follow the Leader mode the layout changes: the leader snaps to
/// near-fullscreen while every follower parks behind it — either at a tiny
/// keep-alive size (Hidden) or as live, non-interactive thumbnails in a slim
/// bottom strip (Peek) — so its mirrored automation keeps running without
/// stealing focus or bogging down the leader. Every cell stays in the same
/// `ZStack` with a stable identity across all layouts, so toggling the mode
/// or the display style never tears down or reloads a web view.
struct QuadBrowserView: View {
    @Bindable var controller: QuadController
    private let diagnostics = WindowDiagnosticsService.shared
    // Swipe-to-hide state for the Follow the Leader status strip / display
    // toggle, so the leader can go fully edge-to-edge too.
    @State private var isFollowLeaderChromeVisible: Bool = true
    @State private var followLeaderChromeDrag: CGFloat = 0
    // Horizontal scroll of the Peek strip, used only once the thumbnails
    // stop fitting in one row (eight windows and up).
    @State private var peekScroll: CGFloat = 0
    @State private var peekScrollStart: CGFloat = 0
    @State private var isShowingLedger: Bool = false

    private var activeSessions: [QuadSession] {
        Array(controller.sessions.prefix(controller.activeCount))
    }

    /// Dim factor for the leader while a commit is being held. Only the
    /// leader dims: a follower is busy working, and fading it would suggest
    /// the opposite.
    private func leaderDim(_ session: QuadSession, followLeader: Bool) -> Double {
        guard followLeader,
              controller.isFollowLeaderGateHolding,
              controller.followLeaderIndex == session.index else { return 1 }
        return 0.82
    }

    var body: some View {
        GeometryReader { geo in
            let followLeader = controller.isFollowLeaderEnabled
            let style = controller.followLeaderDisplayStyle
            // Follower order drives the Peek thumbnails, so it's computed
            // once per layout pass.
            let followerIndices = followLeader
                ? activeSessions.filter { $0.index != controller.followLeaderIndex }.map(\.index)
                : []
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(activeSessions) { session in
                    let layout = layout(
                        for: session,
                        in: geo.size,
                        followLeader: followLeader,
                        style: style,
                        followerPosition: followerIndices.firstIndex(of: session.index) ?? 0,
                        followerCount: followerIndices.count,
                        peekScroll: peekScroll
                    )
                    cell(session, followLeader: followLeader)
                        // Laid out at the leader's size, then scaled into
                        // place — so a follower's page resolves the same
                        // responsive breakpoints the actions were recorded
                        // against, even when it is shown as a thumbnail.
                        .frame(width: layout.contentSize.width, height: layout.contentSize.height)
                        .scaleEffect(layout.scale, anchor: .topLeading)
                        .frame(
                            width: layout.contentSize.width * layout.scale,
                            height: layout.contentSize.height * layout.scale,
                            alignment: .topLeading
                        )
                        .frame(width: layout.frame.width, height: layout.frame.height, alignment: .top)
                        .clipped()
                        // The leader visibly steps back while it is held at a
                        // point of no return, so the pause reads as the grid
                        // being careful rather than the page being stuck.
                        .opacity(layout.opacity * leaderDim(session, followLeader: followLeader))
                        .allowsHitTesting(layout.interactive)
                        .position(x: layout.frame.midX, y: layout.frame.midY)
                        .zIndex(layout.zIndex)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .background(Color.black)
            // Both the mode switch and the Hidden/Peek toggle animate, so
            // the leader visibly snaps in and out instead of jumping.
            .animation(.spring(response: 0.42, dampingFraction: 0.9), value: followLeader)
            .animation(.spring(response: 0.42, dampingFraction: 0.9), value: style)
            .overlay(alignment: .bottom) {
                if followLeader && style == .peek {
                    peekScrollControl(
                        followerCount: followerIndices.count,
                        canvas: geo.size
                    )
                }
            }
            .overlay(alignment: .top) {
                if followLeader {
                    followLeaderChrome
                } else if diagnostics.overlayEnabled {
                    ProcessMemoryStrip(
                        sample: diagnostics.processSample,
                        windowCount: controller.enabledSessions.count
                    )
                    .padding(.top, 4)
                }
            }
            // The hold pill sits low and centred, clear of the strip at the
            // top and of anything the leader's own page puts at the bottom.
            .overlay(alignment: .bottom) {
                if followLeader && controller.isFollowLeaderGateHolding {
                    FollowLeaderHoldPill(count: controller.followLeaderGateWaiting)
                        .padding(.bottom, style == .peek ? FollowLeaderLayout.peekStripHeight + 12 : 28)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(20)
                }
            }
            // Instant Fill sits in the leader's bottom-right corner: within
            // thumb reach, out of the way of the page, and clear of both the
            // strip above and the centred hold pill beside it.
            .overlay(alignment: .bottomTrailing) {
                if followLeader && controller.canInstantFill {
                    InstantFillChip(
                        isWorking: controller.isInstantFilling,
                        action: { controller.runInstantFill() }
                    )
                    .padding(.trailing, Cockpit.Space.base)
                    .padding(.bottom, style == .peek ? FollowLeaderLayout.peekStripHeight + 12 : 28)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                    .zIndex(21)
                }
            }
            .animation(Cockpit.Motion.quick, value: controller.canInstantFill)
            .animation(Cockpit.Motion.panel, value: controller.isFollowLeaderGateHolding)
        }
        // A light tap the instant the squad lets the leader through, so a
        // release is felt rather than watched for.
        .sensoryFeedback(.impact(weight: .light), trigger: controller.followLeaderGateReleases)
        .sheet(isPresented: $isShowingLedger) {
            NavigationStack {
                FollowLeaderLedgerView(controller: controller)
            }
        }
        .onChange(of: controller.isFollowLeaderEnabled) { _, on in
            // A fresh activation always starts with the chrome visible —
            // it shouldn't stay hidden from a previous session.
            if on { isFollowLeaderChromeVisible = true }
            peekScroll = 0
        }
        .onChange(of: controller.gridSize) { _, _ in peekScroll = 0 }
        .onChange(of: controller.followLeaderDisplayStyle) { _, _ in peekScroll = 0 }
    }

    /// Drag layer over the Peek strip.
    ///
    /// Present only when the thumbnails genuinely overflow, and confined to
    /// the strip's own band below the leader — so it can never intercept a
    /// tap meant for the leader's page.
    @ViewBuilder
    private func peekScrollControl(followerCount: Int, canvas: CGSize) -> some View {
        let maxScroll = FollowLeaderLayout.peekMaxScroll(
            count: followerCount,
            canvasWidth: canvas.width
        )
        if maxScroll > 0 {
            let progress = maxScroll > 0 ? min(1, max(0, peekScroll / maxScroll)) : 0
            Color.clear
                .frame(height: FollowLeaderLayout.peekStripHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { value in
                            peekScroll = min(maxScroll, max(0, peekScrollStart - value.translation.width))
                        }
                        .onEnded { _ in
                            peekScrollStart = peekScroll
                        }
                )
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(.white.opacity(0.15))
                        .frame(width: 60, height: 3)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.white.opacity(0.7))
                                .frame(width: 22, height: 3)
                                .offset(x: 38 * progress)
                        }
                        .padding(.bottom, 3)
                        .allowsHitTesting(false)
                }
                .zIndex(6)
        }
    }

    /// Swipe-hideable wrapper around `FollowLeaderTopOverlay`: swipe the
    /// strip up to tuck it away for a fully edge-to-edge leader, swipe down
    /// from the top (or tap the pull tab) to bring it back.
    @ViewBuilder
    private var followLeaderChrome: some View {
        if isFollowLeaderChromeVisible {
            FollowLeaderTopOverlay(
                controller: controller,
                onOpenLedger: { isShowingLedger = true }
            )
                .padding(.top, 4)
                .offset(y: min(0, followLeaderChromeDrag))
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            followLeaderChromeDrag = min(0, value.translation.height)
                        }
                        .onEnded { value in
                            if value.translation.height < -20 {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    isFollowLeaderChromeVisible = false
                                    followLeaderChromeDrag = 0
                                }
                            } else {
                                withAnimation(.spring) { followLeaderChromeDrag = 0 }
                            }
                        }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
        } else {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    isFollowLeaderChromeVisible = true
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .transition(.opacity)
        }
    }

    /// Computes a cell's placement for the current layout. Grid mode uses the
    /// tiled rect; Follow the Leader delegates to the shared, unit-tested
    /// `FollowLeaderLayout` math (leader near-fullscreen, followers as hidden
    /// keep-alive cells or Peek thumbnails).
    private func layout(
        for session: QuadSession,
        in canvas: CGSize,
        followLeader: Bool,
        style: FollowLeaderDisplayStyle,
        followerPosition: Int,
        followerCount: Int,
        peekScroll: CGFloat
    ) -> FollowLeaderLayout.Placement {
        guard followLeader else {
            let rect = gridRect(for: session.index, in: canvas)
            return FollowLeaderLayout.Placement(
                frame: rect,
                contentSize: rect.size,
                scale: 1,
                opacity: 1,
                interactive: true,
                zIndex: 0
            )
        }
        return FollowLeaderLayout.placement(
            isLeader: controller.followLeaderIndex == session.index,
            followerPosition: followerPosition,
            followerCount: followerCount,
            in: canvas,
            style: style,
            peekScroll: peekScroll
        )
    }

    /// Reloads a cell against its last known URL and clears the failed flag
    /// optimistically so the retry overlay disappears immediately.
    private func retryLoad(_ session: QuadSession) {
        session.loadFailed = false
        if let url = session.url {
            session.webView?.load(URLRequest(url: url))
        } else {
            session.webView?.reload()
        }
    }

    /// Tiled rect for a window index in the current grid. Floors each cell so
    /// every tile is identical; leftover fractional pixels become centered
    /// gutters so 6/8/9/12/16-window grids never leave uneven rows/columns.
    private func gridRect(for index: Int, in canvas: CGSize) -> CGRect {
        let size = controller.gridSize
        let spacing: CGFloat = 1
        let totalHSpacing = spacing * CGFloat(max(0, size.columns - 1))
        let totalVSpacing = spacing * CGFloat(max(0, size.rows - 1))
        let cellW = floor((canvas.width - totalHSpacing) / CGFloat(size.columns))
        let cellH = floor((canvas.height - totalVSpacing) / CGFloat(size.rows))
        let usedW = cellW * CGFloat(size.columns) + totalHSpacing
        let usedH = cellH * CGFloat(size.rows) + totalVSpacing
        let hPad = max(0, (canvas.width - usedW) / 2)
        let vPad = max(0, (canvas.height - usedH) / 2)
        let row = index / size.columns
        let col = index % size.columns
        let x = hPad + CGFloat(col) * (cellW + spacing)
        let y = vPad + CGFloat(row) * (cellH + spacing)
        return CGRect(x: x, y: y, width: cellW, height: cellH)
    }

    @ViewBuilder
    private func cell(_ session: QuadSession, followLeader: Bool) -> some View {
        if session.isDisabled && !followLeader {
            // Disabled cells (e.g. 3×3 center in dual-site mode) show an
            // "Unused" label and no web view.
            ZStack {
                Color(.tertiarySystemFill)
                VStack(spacing: 4) {
                    Image(systemName: "square.slash")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text("Unused")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        } else {
            let isFocused = controller.focusedIndex == session.index && !followLeader
            let isLeader = followLeader && controller.followLeaderIndex == session.index
            ZStack {
                QuadCellWebView(session: session, controller: controller)
                    .id("\(session.index)-\(session.storeID.uuidString)-\(session.webViewGeneration)")

                // Per-cell chrome only in the grid; the full-screen leader is
                // kept clean and followers are invisible.
                if !followLeader {
                    cellBadge(session)

                    if diagnostics.overlayEnabled {
                        VStack {
                            Spacer(minLength: 0)
                            HStack {
                                WindowDiagnosticsBadge(
                                    title: session.id,
                                    snapshot: session.memorySnapshot,
                                    report: session.leakCheck,
                                    compact: controller.gridSize.rawValue >= 8
                                )
                                .padding(6)
                                Spacer(minLength: 0)
                            }
                        }
                    }

                    if session.isLoading {
                        VStack {
                            Spacer(minLength: 0)
                            GeometryReader { g in
                                Rectangle()
                                    .fill(Cockpit.live)
                                    .frame(width: g.size.width * session.estimatedProgress, height: 1.5)
                            }
                            .frame(height: 1.5)
                        }
                    }
                }

                // Held for a cloned session: a quiet shimmer instead of a
                // blank tile, so the pause before the page appears reads as
                // deliberate. Sits above the (empty) web view.
                if session.isRestoringSession {
                    RestoringSessionOverlay(compact: controller.gridSize.rawValue >= 8)
                }

                // Shown for every live grid cell, and for the leader in
                // Follow the Leader mode (followers stay invisible either way).
                if session.loadFailed && (!followLeader || isLeader) {
                    LoadFailedOverlay(compact: !isLeader) {
                        retryLoad(session)
                    }
                }

                // A card landing is otherwise completely silent — the page
                // just quietly gains values — so without this the only
                // feedback for a grid-wide fill is one toolbar toast that
                // says nothing about which window got which card.
                CardFillFlashOverlay(
                    session: session,
                    compact: !isLeader && controller.gridSize.rawValue >= 8
                )
            }
            .overlay(
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(isFocused ? Cockpit.live : .clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if !followLeader { controller.focusedIndex = session.index }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Window \(session.id)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if !followLeader { controller.focusedIndex = session.index }
            }
        }
    }

    /// Top-left badge with the window id, status, target-site letter and
    /// assigned card. Grid mode only.
    ///
    /// The badge used to shrink as the grid grew, which is exactly backwards:
    /// sixteen windows is when you most need to tell them apart, and a 10pt
    /// label with a 6pt dot at that size is decoration rather than
    /// information. It now grows slightly on the busy grids, and a window
    /// that wants attention lifts itself out of the pack instead of relying
    /// on you spotting one amber pixel among sixteen.
    @ViewBuilder
    private func cellBadge(_ session: QuadSession) -> some View {
        let status = session.displayStatus(isPausedAll: controller.isQuadRCRPaused)
        let dense = controller.gridSize.rawValue >= 9
        let wantsAttention = status.needsAttention || session.flMisfireCount > 0
        VStack {
            HStack {
                HStack(spacing: dense ? 4 : 6) {
                    Image(systemName: status.iconName)
                        .font(.system(size: dense ? 9 : 10, weight: .black))
                        .foregroundStyle(status.color)
                    Text(session.id)
                        .font(.system(size: dense ? 12 : 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(Cockpit.textPrimary)
                    if controller.isDualTargetMode {
                        Text(session.targetSiteIndex == 0 ? "A" : "B")
                            .font(.system(size: dense ? 10 : 9, weight: .black, design: .rounded))
                            .foregroundStyle(session.targetSiteIndex == 0 ? Cockpit.laneA : Cockpit.laneB)
                    }
                    // The word alongside the colour, so the state survives
                    // being shrunk and is readable without separating cyan
                    // from green. Dropped only on the very densest grids,
                    // where the icon and colour still carry it.
                    //
                    // `dense` starts at 9, so the old `!dense || <= 9` could
                    // never be false for 9 and never true for 12 or 16 — the
                    // second half was dead and the rule actually read "under
                    // 9". Stated once, at the size it was meant to be.
                    if controller.gridSize.rawValue <= 9 {
                        Text(status.label)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(status.color)
                            .lineLimit(1)
                    }
                    if session.rcrTotal > 0 {
                        Text("\(min(session.rcrIndex, session.rcrTotal))/\(session.rcrTotal)")
                            .font(.system(size: dense ? 10 : 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Cockpit.textSecondary)
                    }
                    // Which card this window will fill, on the tile itself —
                    // previously only visible on the Follow the Leader chips,
                    // so in plain grid mode there was no way to check an
                    // assignment without opening the wallet.
                    if let card = controller.assignedCard(for: session) {
                        Text("••\(card.last4)")
                            .font(.system(size: dense ? 10 : 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Cockpit.card)
                    }
                }
                .padding(.horizontal, dense ? 7 : 8)
                .padding(.vertical, dense ? 4 : 5)
                .background(Cockpit.canvas.opacity(0.82), in: .capsule)
                .overlay {
                    Capsule()
                        .strokeBorder(
                            wantsAttention ? status.color.opacity(0.9) : Cockpit.hairline,
                            lineWidth: wantsAttention ? 1.5 : 1
                        )
                }
                .shadow(color: wantsAttention ? status.color.opacity(0.5) : .clear, radius: 6)
                // Healthy, idle windows step back so the eye lands on the
                // ones that actually need something.
                .opacity(wantsAttention || status.isBusy ? 1 : 0.72)
                .animation(Cockpit.Motion.quick, value: wantsAttention)
                .padding(6)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Gold wash over a window the instant its card lands.
///
/// The flash is driven off the session's fill pulse rather than a fill's
/// return value, so an auto-fill on a checkout page announces itself exactly
/// the same way a button-triggered one does.
private struct CardFillFlashOverlay: View {
    let session: QuadSession
    let compact: Bool
    @State private var isFlashing: Bool = false
    @State private var flashToken: Int = 0

    var body: some View {
        Rectangle()
            .fill(Color.cardGold.opacity(isFlashing ? 0.16 : 0))
            .overlay {
                Rectangle()
                    .strokeBorder(Color.cardGold.opacity(isFlashing ? 0.9 : 0), lineWidth: 3)
            }
            .overlay {
                if isFlashing {
                    HStack(spacing: 4) {
                        Image(systemName: "creditcard.fill")
                            .font(.system(size: compact ? 9 : 12, weight: .black))
                        Text(session.cardLast4.isEmpty ? "Filled" : "••\(session.cardLast4)")
                            .font(.system(size: compact ? 10 : 13, weight: .heavy, design: .rounded))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, compact ? 7 : 10)
                    .padding(.vertical, compact ? 4 : 6)
                    .background(Capsule().fill(Color.cardGold))
                    .shadow(color: Color.cardGold.opacity(0.6), radius: 8)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .allowsHitTesting(false)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFlashing)
            .onChange(of: session.cardFillPulse) { _, pulse in
                flashToken = pulse
                isFlashing = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1100))
                    // Only the newest pulse clears the flash, so a second
                    // fill landing mid-flash extends it instead of cutting
                    // the first one short.
                    if flashToken == pulse { isFlashing = false }
                }
            }
            .accessibilityHidden(true)
    }
}

/// Compact strip shown over the full-screen leader in Follow the Leader mode.
/// One chip per window: the leader is flagged, and each hidden follower shows
/// working / done / misfire-count so you can glance at how the background
/// windows are doing without leaving the leader. Non-interactive so it never
/// intercepts taps meant for the leader.
private struct FollowLeaderStatusStrip: View {
    let controller: QuadController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(controller.enabledSessions) { session in
                    chip(session)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.10)))
        .padding(.horizontal, 12)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func chip(_ session: QuadSession) -> some View {
        if controller.followLeaderIndex == session.index {
            HStack(spacing: 4) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.black)
                Text("\(session.id) LEAD")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black)
                // The lockstep marker, shown once on the leader rather than
                // repeated on all sixteen chips — the mode belongs to the
                // squad, not to any one window.
                if controller.isStrictFollowLeader {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.black)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(Cockpit.live))
        } else {
            FollowLeaderChip(session: session)
        }
    }
}

/// Live mirroring state for one follower window.
///
/// The states are deliberately distinct: a window that is merely waiting for
/// its page to load reads differently from one that is grinding through a
/// backlog, which reads differently again from one that actually missed
/// something — so a glance at the strip tells you whether the grid is healthy.
private enum FollowLeaderChipState {
    case dropped
    case repairing
    case recovering
    case flagged(Int)
    case awaitingLoad
    case working
    case behind(Int)
    case synced
    case idle

    init(_ session: QuadSession) {
        // Ordered by how much the state overrides everything else. A window
        // that has left the squad is not slow, behind or flagged — it is out,
        // and saying anything else about it would be a lie.
        if session.flDropped { self = .dropped }
        else if session.flRepairing { self = .repairing }
        // A window whose web process died outranks the rest: it is not slow
        // or flagged, it is being brought back from the dead.
        else if session.flRecovering { self = .recovering }
        else if session.flMisfireCount > 0 { self = .flagged(session.flMisfireCount) }
        else if session.flAwaitingLoad { self = .awaitingLoad }
        else if session.flWorking { self = .working }
        else if session.flPending > 0 { self = .behind(session.flPending) }
        else if session.flReplayCount > 0 { self = .synced }
        else { self = .idle }
    }

    var tint: Color {
        switch self {
        case .dropped: return Cockpit.danger
        case .repairing: return Cockpit.attention
        case .recovering: return .red
        case .flagged: return .orange
        case .awaitingLoad: return Cockpit.live
        case .working: return .yellow
        case .behind: return .yellow
        case .synced: return .green
        case .idle: return .secondary
        }
    }

    var iconName: String? {
        switch self {
        case .dropped: return "minus.circle.fill"
        case .repairing: return "wrench.adjustable.fill"
        case .recovering: return "arrow.clockwise.heart"
        case .flagged: return "exclamationmark.triangle.fill"
        case .awaitingLoad: return "clock"
        case .working: return "arrow.triangle.2.circlepath"
        case .behind: return "chevron.right.2"
        case .synced: return "checkmark"
        case .idle: return nil
        }
    }

    var trailingText: String? {
        switch self {
        case .flagged(let count): return "\(count)"
        case .behind(let count): return "+\(count)"
        case .dropped: return "OUT"
        default: return nil
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .dropped: return "dropped out of sync"
        case .repairing: return "being repaired, replaying the page"
        case .recovering: return "page crashed, reloading"
        case .flagged(let count): return "\(count) missed"
        case .awaitingLoad: return "waiting for the page to load"
        case .working: return "copying the leader"
        case .behind(let count): return "\(count) actions behind"
        case .synced: return "caught up"
        case .idle: return "idle"
        }
    }
}

/// The floating pill shown while the leader is held at a point of no return.
///
/// Deliberately reads as a statement of fact rather than a warning: nothing is
/// wrong, the grid is simply making sure the irreversible step happens from
/// the same starting state in every window.
private struct FollowLeaderHoldPill: View {
    let count: Int

    @State private var isBreathing: Bool = false

    var body: some View {
        HStack(spacing: Cockpit.Space.tight) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Cockpit.onAccent)
                .opacity(isBreathing ? 1 : 0.55)
            Text("Holding for \(count) window\(count == 1 ? "" : "s")")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(Cockpit.onAccent)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, Cockpit.Space.snug + 2)
        .padding(.vertical, Cockpit.Space.tight + 1)
        .background(Capsule().fill(Cockpit.live))
        .shadow(color: Cockpit.live.opacity(0.4), radius: 14, y: 4)
        .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: isBreathing)
        .onAppear { isBreathing = true }
        .allowsHitTesting(false)
        .accessibilityLabel("Holding the leader for \(count) windows to catch up")
    }
}

/// The Instant Fill chip, floating in the leader's corner.
///
/// Deliberately small and quiet. It sits over someone's live page, so it earns
/// its place by being reachable rather than by being loud — gold, because it
/// belongs to the same family as the card fill, and captioned so its one
/// destructive-looking capability (writing into fifteen other windows) is
/// never a mystery press.
private struct InstantFillChip: View {
    let isWorking: Bool
    let action: () -> Void

    @State private var isPressed: Bool = false
    @State private var spin: Double = 0

    var body: some View {
        Button(action: action) {
            HStack(spacing: Cockpit.Space.hair + 2) {
                Image(systemName: isWorking ? "arrow.triangle.2.circlepath" : "wand.and.sparkles")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Cockpit.onAccent)
                    .rotationEffect(.degrees(spin))
                Text(isWorking ? "Filling…" : "Fill all")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(Cockpit.onAccent)
            }
            .padding(.horizontal, Cockpit.Space.snug)
            .padding(.vertical, Cockpit.Space.tight + 1)
            .background(Capsule().fill(Cockpit.card))
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1)
            }
            .shadow(color: Cockpit.card.opacity(0.45), radius: 12, y: 4)
            .scaleEffect(isPressed ? 0.92 : 1)
            .opacity(isWorking ? 0.85 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .animation(Cockpit.Motion.quick, value: isPressed)
        .animation(Cockpit.Motion.quick, value: isWorking)
        // A press that visibly answers is what stops a second, duplicate tap
        // while the fill is still reading the leader.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .sensoryFeedback(.impact(weight: .medium), trigger: isWorking)
        .onChange(of: isWorking) { _, working in
            guard working else {
                spin = 0
                return
            }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                spin = 360
            }
        }
        .accessibilityLabel("Fill all windows from this one")
        .accessibilityHint("Copies every field you have filled here into the other windows")
    }
}

/// One follower chip. Pulses the moment its window drains the last queued
/// action, so catching up is visible without reading anything.
private struct FollowLeaderChip: View {
    let session: QuadSession
    @State private var pulse: Bool = false

    var body: some View {
        let state = FollowLeaderChipState(session)
        HStack(spacing: 4) {
            Circle()
                .fill(state.tint)
                .frame(width: 6, height: 6)
            Text(session.id)
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            if let iconName = state.iconName {
                Image(systemName: iconName)
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(state.tint)
            }
            if let trailing = state.trailingText {
                Text(trailing)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(state.tint)
            }
            // Which card this window is filling. Only shown once a card has
            // actually landed here, so the chip never implies an assignment
            // that hasn't happened yet.
            if !session.cardLast4.isEmpty {
                Text("••\(session.cardLast4)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.cardGold)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(pulse ? state.tint.opacity(0.35) : Color.white.opacity(0.12))
        )
        .scaleEffect(pulse ? 1.12 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: pulse)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            session.cardLast4.isEmpty
                ? "Window \(session.id), \(state.accessibilityDescription)"
                : "Window \(session.id), \(state.accessibilityDescription), card ending \(session.cardLast4)"
        )
        .onChange(of: session.flSyncPulse) { _, _ in
            pulse = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(260))
                pulse = false
            }
        }
    }
}

/// Top overlay in Follow the Leader mode: the follower status strip plus the
/// Hidden/Peek display switch. Only the switch is interactive — the strip
/// itself stays tap-through so it never steals taps meant for the leader.
private struct FollowLeaderTopOverlay: View {
    let controller: QuadController
    let onOpenLedger: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            FollowLeaderStatusStrip(controller: controller)
            modeToggle
            displayToggle
        }
        .padding(.horizontal, 12)
    }

    /// Relaxed / Unbreakable, plus the way into the ledger.
    ///
    /// Sits beside the view picker so the fidelity choice is made in the same
    /// place and the same breath as the layout choice — not buried in a
    /// settings screen two taps away from the grid it governs.
    private var modeToggle: some View {
        HStack(spacing: 3) {
            ForEach(FollowLeaderSyncMode.allCases) { mode in
                let isSelected = controller.followLeaderMode == mode
                Button {
                    controller.setFollowLeaderMode(mode)
                } label: {
                    Image(systemName: mode.iconName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isSelected ? Cockpit.onAccent : Color.white.opacity(0.75))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(isSelected ? Cockpit.live : Color.white.opacity(0.12)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(mode.label) sync")
                .accessibilityHint(mode.blurb)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
            // Only offered in Unbreakable: in Relaxed there is nothing
            // recorded to look at, and a button that opens an empty screen is
            // worse than no button.
            if controller.isStrictFollowLeader {
                Button(action: onOpenLedger) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sync ledger")
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.10)))
    }

    private var displayToggle: some View {
        HStack(spacing: 3) {
            ForEach(FollowLeaderDisplayStyle.allCases) { style in
                let isSelected = controller.followLeaderDisplayStyle == style
                Button {
                    controller.followLeaderDisplayStyle = style
                } label: {
                    Image(systemName: style.iconName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.75))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(isSelected ? Cockpit.live : Color.white.opacity(0.12)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(style.label) follower layout")
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.10)))
    }
}

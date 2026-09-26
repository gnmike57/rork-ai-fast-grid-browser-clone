import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import WebKit

/// The page itself: both address bars, the load progress line, and whatever
/// is being displayed — a single tab, the window grid, a replayed session, or
/// the speed dial.
///
/// Split out of `BrowserView` so the screen's shell stays readable. The shell
/// owns the layers and the lifecycle; this owns what a page looks like.

extension BrowserView {

    // MARK: - URL bars

    /// Pull-tab shown at the top edge when the main URL bar is hidden.
    private var urlBarPullTab: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                viewModel.isURLBarVisible = true
                viewModel.resetURLBarTimer()
            }
        } label: {
            Capsule()
                .fill(Color(.secondarySystemBackground))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 2)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// Main URL bar with auto-hide, swipe gesture, and dual-quad label.
    var urlBar: some View {
        Group {
            if viewModel.isURLBarVisible {
                urlBarView(label: viewModel.isDualQuadMode ? "Site A" : nil, barID: "main")
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                urlBarPullTab
            }
        }
    }

    /// Secondary URL bar for dual-quad mode Site B.
    var urlBarB: some View {
        Group {
            if viewModel.isURLBarBVisible {
                urlBarView(label: "Site B", barID: "b")
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func urlBarView(label: String?, barID: String) -> some View {
        let isBarB = barID == "b"
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let label {
                    Text(label)
                        .font(.system(.caption, design: .rounded, weight: .heavy))
                        .foregroundStyle(Cockpit.live)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Cockpit.live.opacity(0.15)))
                }

                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(viewModel.currentPageURL?.scheme == "https" ? .green : .secondary)

                TextField("Search or enter URL", text: isBarB ? $viewModel.urlBarTextB : $viewModel.urlBarText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused(isBarB ? $isURLBarBFocused : $isURLBarFocused)
                    .disabled(isAnyRCRRunning)
                    .onSubmit {
                        if isBarB {
                            viewModel.navigateToB(viewModel.urlBarTextB)
                            isURLBarBFocused = false
                        } else {
                            viewModel.navigateTo(viewModel.urlBarText)
                            isURLBarFocused = false
                        }
                    }
                    .onTapGesture {
                        if isBarB { viewModel.resetURLBarBTimer() }
                        else { viewModel.resetURLBarTimer() }
                    }
                    .onChange(of: isBarB ? isURLBarBFocused : isURLBarFocused) { _, focused in
                        viewModel.isURLBarEditing = focused
                        if focused {
                            // Cancels any pending hide countdown and pins
                            // the bar open — no new countdown starts while
                            // editing is true.
                            if isBarB { viewModel.resetURLBarBTimer() }
                            else { viewModel.resetURLBarTimer() }
                            DispatchQueue.main.async {
                                UIApplication.shared.sendAction(
                                    #selector(UIResponder.selectAll(_:)),
                                    to: nil, from: nil, for: nil
                                )
                            }
                        } else {
                            viewModel.updateURLBar()
                            // Editing ended — now it is safe to start the
                            // auto-hide countdown.
                            if isBarB { viewModel.resetURLBarBTimer() }
                            else { viewModel.resetURLBarTimer() }
                        }
                    }

                if (isBarB ? isURLBarBFocused : isURLBarFocused) && !(isBarB ? viewModel.urlBarTextB : viewModel.urlBarText).isEmpty {
                    Button {
                        if isBarB {
                            viewModel.urlBarTextB = ""
                        } else {
                            viewModel.urlBarText = ""
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else if isCurrentPageLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                // Window layout stays one tap away — it decides what the
                // whole screen is, so it does not belong behind a menu.
                quadModeToggle

                Menu {
                    pageMenu
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .foregroundStyle(Cockpit.textPrimary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, Cockpit.Space.snug)
            .padding(.vertical, Cockpit.Space.tight)
            .background(Cockpit.surface)
            .clipShape(.rect(cornerRadius: Cockpit.Radius.medium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Cockpit.Radius.medium, style: .continuous)
                    .strokeBorder(Cockpit.hairline, lineWidth: 1)
            }
            .padding(.horizontal, Cockpit.Space.snug)
            .padding(.bottom, 2)
        }
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    // Block swipe-to-hide while the user is typing so an
                    // accidental upward drag can't dismiss the field.
                    guard !viewModel.isURLBarEditing else { return }
                    if value.translation.height < -20 {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            if barID == "b" {
                                viewModel.isURLBarBVisible = false
                            } else {
                                viewModel.isURLBarVisible = false
                            }
                        }
                    }
                }
        )
        .padding(.top, 4)
    }

    var progressBar: some View {
        let isLoading = progressSourceIsLoading
        let progress = progressSourceFraction
        return GeometryReader { geo in
            if isLoading {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * progress, height: 2)
                    .animation(.linear, value: progress)
            }
        }
        .frame(height: 2)
    }

    /// Progress + loading state follow whatever window is actually on
    /// screen: the replayed session, the focused tile, or the active tab.
    private var progressSourceIsLoading: Bool {
        if viewModel.isReplayMode { return viewModel.replayTab?.isLoading == true }
        if viewModel.isQuadMode { return viewModel.quadController.focusedSession.isLoading }
        return viewModel.activeTab?.isLoading == true
    }

    private var progressSourceFraction: Double {
        if viewModel.isReplayMode { return viewModel.replayTab?.estimatedProgress ?? 0 }
        if viewModel.isQuadMode { return viewModel.quadController.focusedSession.estimatedProgress }
        return viewModel.activeTab?.estimatedProgress ?? 0
    }

    var webContent: some View {
        ZStack {
            if viewModel.isReplayMode, let tab = viewModel.replayTab {
                // The frozen store lands signed-in; the deck strip rides on
                // top so the circles stay reachable while it loads.
                WebViewWrapper(tab: tab, viewModel: viewModel)
                    .id("replay-\(tab.id)-\(tab.webViewGeneration)")
            } else if viewModel.isQuadMode {
                QuadBrowserView(controller: viewModel.quadController)
            } else if let tab = viewModel.activeTab, tab.url != nil {
                ZStack(alignment: .bottomLeading) {
                    WebViewWrapper(tab: tab, viewModel: viewModel)
                        .id("\(tab.id)-\(tab.webViewGeneration)")
                    if diagnostics.overlayEnabled {
                        VStack(alignment: .leading, spacing: 6) {
                            ProcessMemoryStrip(sample: diagnostics.processSample, windowCount: 1)
                            WindowDiagnosticsBadge(
                                title: "S1",
                                snapshot: tab.memorySnapshot,
                                report: tab.leakCheck,
                                compact: false
                            )
                        }
                        .padding(10)
                    }
                    if tab.loadFailed {
                        LoadFailedOverlay {
                            tab.loadFailed = false
                            if let url = tab.lastURL ?? tab.url {
                                tab.webView?.load(URLRequest(url: url))
                            } else {
                                tab.webView?.reload()
                            }
                        }
                    }
                }
            } else {
                speedDialHome
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            if viewModel.isReplayMode {
                ReplayDeckRail(viewModel: viewModel)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: viewModel.isReplayMode)
    }

    private var speedDialHome: some View {
        SpeedDialHomeView { entry in
            viewModel.openSpeedDial(entry)
        }
    }
}

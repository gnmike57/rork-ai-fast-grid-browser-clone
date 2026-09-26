import SwiftUI

struct AppSettingsView: View {
    /// True when hosted by the tab bar rather than presented as a sheet, in
    /// which case there is no Done button because there is nothing to dismiss.
    var isEmbedded: Bool = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.autoFillOnPageLoad) private var autoFillOnLoad: Bool = true
    @AppStorage(SettingsKey.offerToSavePasswords) private var offerToSave: Bool = true
    @AppStorage("defaultSearchEngine") private var searchEngine: String = "Google"
    @AppStorage("inAppNotifications") private var inAppNotifications: Bool = true
    @AppStorage("dnsPrewarmEnabled") private var dnsPrewarmEnabled: Bool = false
    @AppStorage("rcrExtraSubmits") private var rcrExtraSubmits: Int = 0
    @AppStorage("rcrSubmitDelay") private var rcrSubmitDelay: Double = 1.5
    @AppStorage("dualQuadURL_A") private var dualQuadURL_A: String = "https://www.ignitioncasino.ooo/login"
    @AppStorage("dualQuadURL_B") private var dualQuadURL_B: String = "https://joefortune.win/login"
    @AppStorage("dualSiteSplitPattern") private var dualSiteSplitPatternRawValue: String = DualSiteSplitPattern.checkerboard.rawValue
    @AppStorage("windowDiagnosticsEnabled") private var windowDiagnosticsEnabled: Bool = true
    @AppStorage(SettingsKey.sessionCloneLoadTiming) private var sessionCloneTimingRawValue: String = SessionCloneLoadTiming.waitForSession.rawValue
    @State private var isShowingExcludedDomains: Bool = false

    private var isSiteAValid: Bool { BrowserViewModel.resolveURL(from: dualQuadURL_A) != nil }
    private var isSiteBValid: Bool { BrowserViewModel.resolveURL(from: dualQuadURL_B) != nil }

    private func normalizeSiteA() {
        guard let resolved = BrowserViewModel.resolveURL(from: dualQuadURL_A) else { return }
        dualQuadURL_A = resolved.absoluteString
    }

    private func normalizeSiteB() {
        guard let resolved = BrowserViewModel.resolveURL(from: dualQuadURL_B) else { return }
        dualQuadURL_B = resolved.absoluteString
    }

    var body: some View {
        Form {
            Section("Security") {
                HStack {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(Cockpit.live)
                    Text("Passwords stored in iOS Keychain")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Show In-App Notifications", isOn: $inAppNotifications)
            } header: {
                Text("Notifications")
            } footer: {
                Text("When off, status toasts are hidden. Important warnings and errors still appear.")
            }

            Section {
                Label("Automation tab", systemImage: "wand.and.sparkles")
                    .foregroundStyle(Cockpit.textSecondary)
            } header: {
                Text("AI Copilot")
            } footer: {
                Text("The AI brains, auto-repair, success detection and the list of everything that runs on a page now live in the Automation tab, next to the runs they affect. Passwords are never shared with any AI.")
            }

            Section {
                Stepper(value: $rcrExtraSubmits, in: 0...10) {
                    LabeledContent("Extra Submits", value: "\(rcrExtraSubmits)")
                }
                HStack {
                    Text("Delay")
                    Spacer()
                    Text(String(format: "%.1fs", rcrSubmitDelay))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $rcrSubmitDelay, in: 0.5...5.0, step: 0.1)
            } header: {
                Text("RCR Sure-Login")
            } footer: {
                Text("After the initial submit, RCR fires the configured extra submits with this delay. All other actions pause until they finish.")
            }

            Section("Auto Fill") {
                Toggle("Auto-fill on Page Load", isOn: $autoFillOnLoad)
                Toggle("Offer to Save New Passwords", isOn: $offerToSave)

                Button {
                    isShowingExcludedDomains = true
                } label: {
                    HStack {
                        Label("Excluded Domains", systemImage: "nosign")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Section {
                Picker("When Windows Load", selection: $sessionCloneTimingRawValue) {
                    ForEach(SessionCloneLoadTiming.allCases) { timing in
                        Text(timing.label).tag(timing.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text(SessionCloneLoadTiming(rawValue: sessionCloneTimingRawValue)?.detail
                     ?? SessionCloneLoadTiming.waitForSession.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Session Cloning")
            } footer: {
                Text("With cloning on, Window 1's signed-in session is copied into every other window whenever the layout changes. In dual-site mode each site keeps its own leader.")
            }

            Section {
                LabeledContent("Site A") {
                    TextField("URL", text: $dualQuadURL_A)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .onSubmit(normalizeSiteA)
                }
                if !isSiteAValid {
                    Text("Enter a valid web address, e.g. example.com/login")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                LabeledContent("Site B") {
                    TextField("URL", text: $dualQuadURL_B)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .onSubmit(normalizeSiteB)
                }
                if !isSiteBValid {
                    Text("Enter a valid web address, e.g. example.com/login")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                Picker("Default Split", selection: $dualSiteSplitPatternRawValue) {
                    ForEach(DualSiteSplitPattern.allCases) { pattern in
                        Label(pattern.label, systemImage: pattern.systemImage)
                            .tag(pattern.rawValue)
                    }
                }
            } header: {
                Text("Dual-Site Targets")
            } footer: {
                Text("Dual-site mode is available for every grid size, including 4×4 (16 windows). Horizontal, vertical, and checkerboard layouts always assign half the tiles to each URL. The 3×3 grid leaves its center tile unused, splitting the remaining eight tiles evenly.")
            }

            Section {
                Toggle("Window Diagnostics", isOn: $windowDiagnosticsEnabled)
                    .onChange(of: windowDiagnosticsEnabled) { _, enabled in
                        WindowDiagnosticsService.shared.overlayEnabled = enabled
                    }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Shows estimated memory for each window and the latest automated leak-check: store isolation, cookie leak, burn wipe, and process pressure. Useful when running 8–16 windows.")
            }

            Section {
                Picker("Search Engine", selection: $searchEngine) {
                    Text("Google").tag("Google")
                    Text("DuckDuckGo").tag("DuckDuckGo")
                    Text("Bing").tag("Bing")
                }
                Toggle("Pre-connect to Frequent Sites", isOn: $dnsPrewarmEnabled)
            } header: {
                Text("Browser")
            } footer: {
                Text("Pre-connecting opens a network connection to your most-visited sites at launch so they load faster. Off by default.")
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")

                HStack {
                    Image(systemName: "bolt.shield.fill")
                        .foregroundStyle(.linearGradient(
                            colors: [Cockpit.live, Cockpit.live.opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                    VStack(alignment: .leading) {
                        Text("Sitch AI Browser")
                            .font(.headline)
                        Text("The smartest, most forgiving login browser")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isEmbedded {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $isShowingExcludedDomains) {
            NavigationStack { ExcludedDomainsView() }
        }
        .onDisappear {
            normalizeSiteA()
            normalizeSiteB()
        }
    }
}

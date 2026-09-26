import Foundation
import WebKit
import SwiftData
import os

/// Dual-site runs: the paired-lane model.
///
/// Split out of `QuadController` because it is a genuinely different run
/// model from the single-site one — lanes of two windows testing the *same*
/// credential against two different sites, rather than independent per-window
/// slices of one queue. Keeping the two side by side in one file was most of
/// why that file had grown past 2,700 lines.
extension QuadController {

    // MARK: - Dual-quad RCR (paired-lane model)
    //
    // Dual URL split mode tests two vault entries at a time per pair — not
    // independent per-window slices. Active sessions are grouped into lanes
    // determined by the active split pattern (horizontal, vertical, or
    // checkerboard). Each lane pairs one Site A session with one Site B
    // session so that both sides test the SAME credential concurrently —
    // one against URL A, the other against URL B. The lane only advances
    // once BOTH sides reach a terminal result.
    //
    // Credentials are pre-balanced across lanes using round-robin so every
    // lane gets either floor(N/lanes) or ceil(N/lanes) — equal to within
    // one credential, no matter the vault size. This replaces the old
    // greedy shared-pool model that could starve slow lanes.


    /// Number of A/B lane pairs available for dual-site RCR.
    var laneCount: Int { laneSessionAIndices.count }

    /// Compact-bar progress across every dual-site lane — sums the per-lane
    /// completed and total counters so 6/8/9/12/16-window grids never show only
    /// the first pair's numbers.
    var dualOverallProgress: (completed: Int, total: Int) {
        Self.overallProgress(
            completedPerLane: laneCompletedCounts,
            totalsPerLane: laneStates.map { $0.credentials.count }
        )
    }

    /// Sums per-lane completed/total counters into one overall pair.
    /// Splits `items` evenly across `windowCount` slots using balanced
    /// round-robin, so every slot gets either floor(N/W) or ceil(N/W) items
    /// — guaranteed equal to within one, no matter how small the queue.
    /// Pulled out as a pure function so the balance guarantee has a direct
    /// unit test instead of only being exercised indirectly through a run.
    nonisolated static func roundRobinSlices<T>(_ items: [T], windowCount: Int) -> [[T]] {
        guard windowCount > 0 else { return [] }
        var slices: [[T]] = Array(repeating: [], count: windowCount)
        for (i, item) in items.enumerated() {
            slices[i % windowCount].append(item)
        }
        return slices
    }

    nonisolated static func overallProgress(
        completedPerLane: [Int],
        totalsPerLane: [Int]
    ) -> (completed: Int, total: Int) {
        (completedPerLane.reduce(0, +), totalsPerLane.reduce(0, +))
    }

    /// Backfills per-lane completed counts for a resumed dual run: counts
    /// each lane's credentials that were already finished against both
    /// target sites.
    nonisolated static func laneBackfillCounts(
        slices: [[String]],
        finishedIDs: Set<String>
    ) -> [Int] {
        slices.map { slice in slice.filter { finishedIDs.contains($0) }.count }
    }

    /// Rebuilds lane pairings from the current `targetSiteIndex` assignments.
    /// Each lane pairs one Site A session with one Site B session, in index
    /// order, so the pairing always matches the visual split pattern.
    /// Disabled sessions (e.g. 3×3 center) are excluded entirely.
    func rebuildLaneMapping() {
        let activeIndices = Array(0..<activeCount).filter { !sessions[$0].isDisabled }
        let aIndices = activeIndices.filter { sessions[$0].targetSiteIndex == 0 }
        let bIndices = activeIndices.filter { sessions[$0].targetSiteIndex == 1 }
        let count = min(aIndices.count, bIndices.count)
        laneSessionAIndices = Array(aIndices.prefix(count))
        laneSessionBIndices = Array(bIndices.prefix(count))
    }

    func laneIndex(for session: QuadSession) -> Int {
        for i in 0..<laneSessionAIndices.count {
            if laneSessionAIndices[i] == session.index || laneSessionBIndices[i] == session.index {
                return i
            }
        }
        return 0
    }
    private func isASide(_ session: QuadSession) -> Bool {
        laneSessionAIndices.contains(session.index)
    }
    func sessionA(forLane lane: Int) -> QuadSession {
        guard laneSessionAIndices.indices.contains(lane) else { return sessions[0] }
        return sessions[laneSessionAIndices[lane]]
    }
    func sessionB(forLane lane: Int) -> QuadSession {
        guard laneSessionBIndices.indices.contains(lane) else { return sessions[1] }
        return sessions[laneSessionBIndices[lane]]
    }

    func currentDualCredential(_ s: QuadSession) -> Credential? {
        guard let id = dualCredentialIDBySessionIndex[s.index], let context = modelContext else { return nil }
        let descriptor = FetchDescriptor<Credential>(predicate: #Predicate<Credential> { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    /// Dual-quad RCR: two lanes, each testing one credential against BOTH
    /// URL A and URL B before advancing to the next vault entry.
    func startDualQuadRCR(urlA: URL, urlB: URL) {
        guard !anyRCRRunning, !isStartingRCR else { return }
        guard let context = modelContext else { return }
        autoDisableFollowLeader(reason: "Follow the Leader off — run started")
        FillHealerEngine.shared.resetRunBudget()
        ParkedSessionStore.shared.markRunStarted()
        NeedsReviewStore.shared.markRunStarted()
        let descriptor = FetchDescriptor<Credential>(
            sortBy: [
                SortDescriptor(\Credential.domain),
                SortDescriptor(\Credential.username)
            ]
        )
        guard let all = try? context.fetch(descriptor), !all.isEmpty else {
            browserViewModel?.showToast("Vault is empty", force: true)
            return
        }
        let excluded = browserViewModel?.excludedDomainSet ?? []

        let eligible = all.filter { cred in
            !excluded.contains(ExcludedDomain.canonicalize(cred.domain))
                && !PermaDisabledStore.shared.isDisabled(credentialID: cred.id)
        }
        guard !eligible.isEmpty else {
            browserViewModel?.showToast("Vault is empty", force: true)
            return
        }

        let lanes = laneSessionAIndices.count
        guard lanes > 0 else {
            browserViewModel?.showToast("No valid lane pairing for this layout", force: true)
            return
        }

        // Keychain reads block the caller — fetch password counts off the
        // main thread so a large vault can't freeze the UI at run start.
        isStartingRCR = true
        rcrStartGeneration &+= 1
        let startGeneration = rcrStartGeneration
        let credIDs = eligible.map(\.id)
        Task { [weak self] in
            guard let self else { return }
            let counts = await Task.detached {
                Dictionary(uniqueKeysWithValues: credIDs.map {
                    ($0, KeychainService.shared.getPasswords(for: $0).count)
                })
            }.value
            guard self.isStartingRCR, self.rcrStartGeneration == startGeneration else { return }
            self.isStartingRCR = false
            self.beginDualQuadRun(urlA: urlA, urlB: urlB, eligible: eligible, passwordCounts: counts, context: context)
        }
    }

    /// Continues `startDualQuadRCR` on the main actor once password counts
    /// are ready: applies the restart/resume rules and kicks off every lane.
    private func beginDualQuadRun(
        urlA: URL,
        urlB: URL,
        eligible: [Credential],
        passwordCounts: [String: Int],
        context: ModelContext
    ) {
        let domainA = urlA.host(percentEncoded: false)?.lowercased() ?? ""
        let domainB = urlB.host(percentEncoded: false)?.lowercased() ?? ""
        let tracker = AttemptTrackingService.shared

        func finishedBoth(_ cred: Credential) -> Bool {
            let pwCount = passwordCounts[cred.id] ?? 0
            let doneA = tracker.credentialIsFinished(
                context: context, credentialID: cred.id, targetDomain: domainA, totalPasswords: pwCount
            )
            let doneB = tracker.credentialIsFinished(
                context: context, credentialID: cred.id, targetDomain: domainB, totalPasswords: pwCount
            )
            return doneA && doneB
        }

        let lanes = laneSessionAIndices.count
        let finishedBeforeRestart = eligible.filter { finishedBoth($0) }
        let restartingClean = finishedBeforeRestart.count == eligible.count
        if restartingClean {
            // The whole vault already finished against both URLs — restart clean.
            tracker.clearAttempts(context: context, targetDomain: domainA)
            tracker.clearAttempts(context: context, targetDomain: domainB)
        }
        let previouslyFinishedIDs: Set<String> = restartingClean
            ? []
            : Set(finishedBeforeRestart.map(\.id))

        // Split each lane's FULL share up front so a resumed run still shows
        // previously-finished credentials in the queue and counters.
        var fullLaneSlices: [[Credential]] = Array(repeating: [], count: lanes)
        for (i, cred) in eligible.enumerated() {
            fullLaneSlices[i % lanes].append(cred)
        }

        dualQuadURLA = urlA
        dualQuadURLB = urlB
        dualQuadTargetDomainA = domainA
        dualQuadTargetDomainB = domainB
        dualQuadActive = true
        dualNeedsBurn = [:]
        dualCredentialIDBySessionIndex = [:]
        laneStates = (0..<lanes).map { lane in
            let fullSlice = fullLaneSlices[lane]
            return LaneState(
                credentials: fullSlice,
                skipIDs: Set(fullSlice.map(\.id)).intersection(previouslyFinishedIDs)
            )
        }
        // Backfill counters with credentials already finished against BOTH
        // sites so pause→resume doesn't reset the visible progress.
        laneCompletedCounts = Self.laneBackfillCounts(
            slices: fullLaneSlices.map { $0.map(\.id) },
            finishedIDs: previouslyFinishedIDs
        )

        for lane in 0..<lanes {
            let slice = fullLaneSlices[lane]
            let sliceIDs = slice.map(\.id)
            let sliceUsernames = slice.map(\.username)
            let sliceCounts: [Int] = sliceIDs.map { passwordCounts[$0] ?? 0 }
            let skipIDs = laneStates[lane].skipIDs
            for s in [sessionA(forLane: lane), sessionB(forLane: lane)] {
                s.rcrQueueIDs = sliceIDs
                s.rcrQueueUsernames = sliceUsernames
                s.rcrQueuePasswordCounts = sliceCounts
                s.rcrTotal = slice.count
                s.rcrCompletedIDs = skipIDs
                s.rcrIndex = 0
                s.rcrSuccessCount = 0
                s.rcrAwaitingNavigation = false
                s.rcrExtraSubmitsInFlight = false
                s.needsPostBurnSettle = false
            }
        }

        // Human-like scrolling only runs while an automated run is active.
        for s in activeSessions {
            s.webView?.evaluateJavaScript(
                JavaScriptInjectionService.rcrScrollEnableScript(),
                completionHandler: nil
            )
        }

        for lane in 0..<lanes {
            assignNextCredential(lane: lane)
        }
    }

    /// Pulls the next unclaimed credential from the shared pool for `lane`
    /// and kicks off both of its sessions "sortve parallel" against URL A
    /// and URL B. If the pool is exhausted, the lane is marked finished.
    private func assignNextCredential(lane: Int) {
        guard dualQuadActive else { return }
        let sA = sessionA(forLane: lane)
        let sB = sessionB(forLane: lane)

        // Skip credentials already finished against both sites when this
        // run started — they're counted via the backfilled counter, not
        // re-tested.
        while laneStates[lane].index < laneStates[lane].credentials.count,
              laneStates[lane].skipIDs.contains(
                  laneStates[lane].credentials[laneStates[lane].index].id
              ) {
            laneStates[lane].index += 1
        }

        guard laneStates[lane].index < laneStates[lane].credentials.count else {
            sA.rcrRunning = false
            sA.rcrStatus = .finished
            sB.rcrRunning = false
            sB.rcrStatus = .finished
            cancelRCRWatchdog(for: sA)
            cancelRCRWatchdog(for: sB)
            // Don't leave plaintext passwords sitting in memory.
            sA.rcrPasswords = []
            sB.rcrPasswords = []
            checkDualQuadAllFinished()
            return
        }

        let credential = laneStates[lane].credentials[laneStates[lane].index]
        laneStates[lane].resultA = nil
        laneStates[lane].resultB = nil
        laneStates[lane].finalizing = false
        dualCredentialIDBySessionIndex[sA.index] = credential.id
        dualCredentialIDBySessionIndex[sB.index] = credential.id

        for s in [sA, sB] {
            s.rcrIndex = laneStates[lane].index
            s.rcrCurrentUsername = credential.username
            s.rcrRunning = true
            s.rcrStatus = .navigating
        }

        guard let urlA = dualQuadURLA, let urlB = dualQuadURLB else { return }
        Task {
            await self.runDualSide(
                session: sA, credential: credential, targetURL: urlA,
                targetDomain: self.dualQuadTargetDomainA, lane: lane
            )
        }
        Task {
            await self.runDualSide(
                session: sB, credential: credential, targetURL: urlB,
                targetDomain: self.dualQuadTargetDomainB, lane: lane
            )
        }
    }

    /// Runs ONE side (URL A or URL B) of a lane's current credential —
    /// fetches/filters passwords, burns+reloads first if the previous round
    /// left a pending "been disabled" burn for this session, navigates if
    /// needed, then hands off to `attemptFillDual`.
    private func runDualSide(
        session s: QuadSession,
        credential: Credential,
        targetURL: URL,
        targetDomain: String,
        lane: Int
    ) async {
        guard dualQuadActive, s.rcrRunning else { return }
        await waitIfPausedOrFrozen(s)
        guard dualQuadActive, s.rcrRunning else { return }

        if TempDisabledStore.shared.isDisabled(credentialID: credential.id) {
            finishDualSide(session: s, lane: lane, status: .tempDisabled)
            return
        }
        if PermaDisabledStore.shared.isDisabled(credentialID: credential.id) {
            finishDualSide(session: s, lane: lane, status: .disabled)
            return
        }

        let credID = credential.id
        let allPasswords = await Task.detached {
            KeychainService.shared.getPasswords(for: credID)
        }.value
        guard !allPasswords.isEmpty else {
            finishDualSide(session: s, lane: lane, status: .failed)
            return
        }

        let tracker = AttemptTrackingService.shared
        let filtered: [String]
        if let context = modelContext {
            if retryFailed {
                filtered = allPasswords.filter { pw in
                    !tracker.isTerminallyAttempted(
                        context: context, credentialID: credID,
                        passwordHash: PasswordFingerprint.hash(pw), targetDomain: targetDomain
                    )
                }
            } else {
                let descriptor = FetchDescriptor<AttemptRecord>(
                    predicate: #Predicate<AttemptRecord> { rec in
                        rec.credentialID == credID
                            && rec.targetDomain == targetDomain
                            && rec.statusRaw != "pending"
                            && rec.statusRaw != "skipped"
                    }
                )
                let attempted = Set(((try? context.fetch(descriptor)) ?? []).map { $0.passwordHash })
                filtered = allPasswords.filter { !attempted.contains(PasswordFingerprint.hash($0)) }
            }
        } else {
            filtered = allPasswords
        }

        guard !filtered.isEmpty else {
            finishDualSide(session: s, lane: lane, status: .failed)
            return
        }

        s.rcrPasswords = filtered
        s.rcrPasswordIndex = 0
        s.rcrPasswordsCredentialID = credential.id
        s.rcrTargetURL = targetURL
        s.rcrCurrentDomain = targetDomain

        // A permanent disable on the previous round for this window needs a
        // full burn + fresh reload (and cookie-notice wait) before we try
        // the next credential here — regardless of the current URL.
        if dualNeedsBurn[s.index] == true {
            dualNeedsBurn[s.index] = false
            s.rcrStatus = .burning
            s.rcrBurnFlash &+= 1
            if !ParkedSessionStore.shared.contains(storeID: s.storeID) {
                await QuadDataStore.burn(dataStoreID: s.storeID)
            }
            guard dualQuadActive, s.rcrRunning else { return }
            s.needsPostBurnSettle = true
            s.rcrStatus = .navigating
            s.rcrAwaitingNavigation = true
            s.url = targetURL
            s.webView?.load(URLRequest(url: targetURL))
            armRCRWatchdog(for: s, timeout: PageSettleService.postBurnNavigationWatchdog)
            return
        }

        let liveURL = s.webView?.url ?? s.url
        if !BrowserViewModel.sameTarget(liveURL, targetURL) {
            s.rcrStatus = .navigating
            s.rcrAwaitingNavigation = true
            s.url = targetURL
            s.webView?.load(URLRequest(url: targetURL))
            armRCRWatchdog(for: s)
            return
        }

        await attemptFillDual(session: s, lane: lane)
    }

    func attemptFillDual(session s: QuadSession, lane: Int) async {
        guard dualQuadActive, s.rcrRunning else { return }
        await waitIfPausedOrFrozen(s)
        guard dualQuadActive, s.rcrRunning, !s.rcrPasswords.isEmpty else { return }
        guard let credential = currentDualCredential(s) else {
            finishDualSide(session: s, lane: lane, status: .failed)
            return
        }
        let password = s.rcrPasswords[s.rcrPasswordIndex]
        let targetDomain = s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain
        let siteSetting = browserViewModel?.fetchSiteSetting(for: targetDomain)

        s.rcrStatus = .filling
        let fillScript = JavaScriptInjectionService.fillCredentialScript(
            username: credential.username,
            password: password,
            usernameSelector: siteSetting?.usernameSelector,
            passwordSelector: siteSetting?.passwordSelector,
            suppressKeyboard: true
        )
        let fillResult = try? await s.webView?.evaluateJavaScript(fillScript)

        var healedSubmitSelector: String? = nil
        if FillHealerEngine.fillMissed(fillResult),
           let webView = s.webView,
           let context = self.modelContext {
            let outcome = await FillHealerEngine.shared.healAndRefill(
                webView: webView,
                domain: targetDomain,
                sessionTag: s.sessionTag,
                username: credential.username,
                password: password,
                modelContext: context
            )
            healedSubmitSelector = outcome?.submitSelector
        }

        s.rcrStatus = .submitting
        let submitScript = JavaScriptInjectionService.submitFormScript(
            submitSelector: healedSubmitSelector ?? siteSetting?.submitButtonSelector
        )
        guard let webViewForSubmit = s.webView else {
            ParkedSessionStore.shared.recordFailure()
            captureAndRecord(session: s, credential: credential, password: password, status: .failed)
            browserViewModel?.showToast("Window closed mid-submit — skipping \(credential.username)")
            if s.rcrPasswordIndex + 1 < s.rcrPasswords.count {
                s.rcrPasswordIndex += 1
                Task { await self.attemptFillDual(session: s, lane: lane) }
            } else {
                finishDualSide(session: s, lane: lane, status: .failed)
            }
            return
        }
        do {
            _ = try await webViewForSubmit.evaluateJavaScript(submitScript)
        } catch {
            ParkedSessionStore.shared.recordFailure()
            captureAndRecord(session: s, credential: credential, password: password, status: .failed)
            browserViewModel?.showToast("Submit failed — skipping \(credential.username)")
            if s.rcrPasswordIndex + 1 < s.rcrPasswords.count {
                s.rcrPasswordIndex += 1
                Task { await self.attemptFillDual(session: s, lane: lane) }
            } else {
                finishDualSide(session: s, lane: lane, status: .failed)
            }
            return
        }

        let extraCount = max(0, UserDefaults.standard.integer(forKey: "rcrExtraSubmits"))
        let rawDelay = UserDefaults.standard.double(forKey: "rcrSubmitDelay")
        let baseDelay = rawDelay > 0 ? rawDelay : 1.5
        let delay = max(0.2, baseDelay * activeSpeedProfile.submitGapMultiplier)
        if extraCount > 0 {
            // Self-driving loop — watchdog must not fire during it; it
            // re-arms when the loop hands back to the observer.
            cancelRCRWatchdog(for: s)
            s.rcrExtraSubmitsInFlight = true
            for _ in 0..<extraCount {
                await waitIfPausedOrFrozen(s)
                guard s.rcrRunning, dualQuadActive else { s.rcrExtraSubmitsInFlight = false; return }
                try? await Task.sleep(for: .seconds(delay))
                guard s.rcrRunning, dualQuadActive else { s.rcrExtraSubmitsInFlight = false; return }
                _ = try? await s.webView?.evaluateJavaScript(submitScript)

                try? await Task.sleep(for: .seconds(0.35))
                guard s.rcrRunning, dualQuadActive else { s.rcrExtraSubmitsInFlight = false; return }
                let rawState = try? await s.webView?.evaluateJavaScript(
                    JavaScriptInjectionService.pageStateSnapshotScript()
                )
                if let payload = JavaScriptInjectionService.parsePageState(rawState),
                   JavaScriptInjectionService.isTerminalRCRState(payload) {
                    s.rcrExtraSubmitsInFlight = false
                    s.rcrStatus = .waiting
                    handleDualQuadMessage(session: s, payload: payload)
                    return
                }
            }
            s.rcrExtraSubmitsInFlight = false
        }

        credential.lastUsedAt = Date()
        credential.usageCount += 1
        try? modelContext?.save()

        if let context = modelContext {
            _ = AttemptTrackingService.shared.recordAttempt(
                context: context,
                credentialID: credential.id,
                username: credential.username,
                password: password,
                passwordIndex: s.rcrPasswordIndex + 1,
                passwordTotal: s.rcrPasswords.count,
                targetDomain: targetDomain,
                sessionTag: s.sessionTag,
                status: .pending
            )
        }

        s.rcrStatus = .waiting
        let installScript = JavaScriptInjectionService.rcrInstallObserverScript()
        _ = try? await s.webView?.evaluateJavaScript(installScript)
        armRCRWatchdog(for: s)
    }

    func handleDualQuadMessage(session s: QuadSession, payload: [String: Any]) {
        guard dualQuadActive, s.rcrRunning, s.rcrStatus == .waiting else { return }
        if s.rcrExtraSubmitsInFlight { return }
        if s.rcrJudging { return }
        let lane = laneIndex(for: s)
        guard let credential = currentDualCredential(s) else {
            finishDualSide(session: s, lane: lane, status: .failed)
            return
        }
        let password = s.rcrPasswords[safe: s.rcrPasswordIndex] ?? ""
        let signal = SuccessJudgeEngine.classifyLocal(payload)

        switch signal {
        case .disabled:
            ParkedSessionStore.shared.recordFailure()
            captureAndRecord(session: s, credential: credential, password: password, status: .disabled)
            dualNeedsBurn[s.index] = true
            finishDualSide(session: s, lane: lane, status: .disabled)
        case .tempDisabled:
            captureAndRecord(session: s, credential: credential, password: password, status: .tempDisabled)
            if s.rcrPasswords.count > 1 {
                TempDisabledStore.shared.markDisabled(credentialID: credential.id)
                browserViewModel?.showToast("Temp-disabled — \(credential.username)")
            }
            finishDualSide(session: s, lane: lane, status: .tempDisabled)
        case .stillOnLogin:
            ParkedSessionStore.shared.recordFailure()
            captureAndRecord(session: s, credential: credential, password: password, status: .failed)
            if s.rcrPasswordIndex + 1 < s.rcrPasswords.count {
                s.rcrPasswordIndex += 1
                Task { await self.attemptFillDual(session: s, lane: lane) }
            } else {
                finishDualSide(session: s, lane: lane, status: .failed)
            }
        case .apparentSuccess, .unclear:
            s.rcrJudging = true
            cancelRCRWatchdog(for: s)
            let credID = credential.id
            Task {
                await self.judgeDualAndAdvance(session: s, lane: lane, payload: payload, credentialID: credID, password: password)
                s.rcrJudging = false
            }
        }
    }

    private func judgeDualAndAdvance(
        session s: QuadSession,
        lane: Int,
        payload: [String: Any],
        credentialID: String,
        password: String
    ) async {
        guard dualQuadActive, s.rcrRunning else { return }
        guard let credential = currentDualCredential(s), credential.id == credentialID else { return }
        // Speed-scaled grace before judging so the page settles into its
        // final state — slower profiles judge later, never sooner.
        try? await Task.sleep(for: activeSpeedProfile.judgeGrace)
        guard dualQuadActive, s.rcrRunning else { return }
        let image = await WebViewSnapshotter.capture(s.webView)
        let filename: String?
        if let image {
            filename = await ScreenshotStorage.save(image)
        } else {
            filename = nil
        }
        let domain = s.rcrTargetURL?.host(percentEncoded: false)?.lowercased() ?? credential.domain
        let decision = await SuccessJudgeEngine.judge(
            payload: payload,
            image: image,
            domain: domain,
            sessionTag: s.sessionTag
        )
        recordOutcome(
            session: s,
            credential: credential,
            password: password,
            status: decision.status,
            filename: filename,
            judge: decision
        )

        switch decision.status {
        case .disabled:
            ParkedSessionStore.shared.recordFailure()
            dualNeedsBurn[s.index] = true
            finishDualSide(session: s, lane: lane, status: .disabled)
        case .tempDisabled:
            if s.rcrPasswords.count > 1 {
                TempDisabledStore.shared.markDisabled(credentialID: credential.id)
            }
            finishDualSide(session: s, lane: lane, status: .tempDisabled)
        case .failed, .pending, .skipped:
            ParkedSessionStore.shared.recordFailure()
            if s.rcrPasswordIndex + 1 < s.rcrPasswords.count {
                s.rcrPasswordIndex += 1
                Task { await self.attemptFillDual(session: s, lane: lane) }
            } else {
                finishDualSide(session: s, lane: lane, status: .failed)
            }
        case .review:
            finishDualSide(session: s, lane: lane, status: .review)
        case .success:
            s.rcrSuccessCount += 1
            s.rcrStatus = .success
            if decision.shouldPark {
                parkSession(s, credential: credential, thumbnail: image)
            }
            finishDualSide(session: s, lane: lane, status: .success)
        }
    }

    /// Records this session's side result for the lane's current credential.
    /// Once BOTH sides have reported in, finalizes the pairing exactly once.
    func finishDualSide(session s: QuadSession, lane: Int, status: AttemptRecord.Status) {
        guard dualQuadActive else { return }
        if isASide(s) {
            laneStates[lane].resultA = status
        } else {
            laneStates[lane].resultB = status
        }
        s.rcrStatus = .pairWait

        guard let resultA = laneStates[lane].resultA, let resultB = laneStates[lane].resultB else {
            // Still waiting on the other URL's result for this credential.
            return
        }
        guard !laneStates[lane].finalizing else { return }
        laneStates[lane].finalizing = true
        finalizeLane(lane: lane, resultA: resultA, resultB: resultB)
    }

    /// Applies the paired deletion rule: only delete when a permanent
    /// disable is paired with another removal-safe result (another
    /// permanent disable, or an ordinary login failure). Never delete when
    /// paired with success or temp-disabled — those credentials are kept.
    private func finalizeLane(lane: Int, resultA: AttemptRecord.Status, resultB: AttemptRecord.Status) {
        guard let credential = laneStates[lane].credentials[safe: laneStates[lane].index] else {
            advanceLane(lane: lane)
            return
        }

        let keepStatuses: Set<AttemptRecord.Status> = [.success, .tempDisabled, .review]
        let isRemovalSafe = (resultA == .disabled || resultB == .disabled)
            && !keepStatuses.contains(resultA)
            && !keepStatuses.contains(resultB)

        if isRemovalSafe {
            PermaDisabledStore.shared.markDisabled(credentialID: credential.id)
            NeedsReviewStore.shared.flag(
                credentialID: credential.id,
                username: credential.username,
                domain: credential.domain,
                reason: "Showed as disabled on both sites during a run"
            )
            browserViewModel?.showToast("Flagged for review — \(credential.username)")
        }

        for s in [sessionA(forLane: lane), sessionB(forLane: lane)] {
            s.rcrCompletedIDs.insert(credential.id)
        }
        if laneCompletedCounts.indices.contains(lane) {
            laneCompletedCounts[lane] += 1
        }

        advanceLane(lane: lane)
    }

    private func advanceLane(lane: Int) {
        laneStates[lane].index += 1
        assignNextCredential(lane: lane)
    }

    private func checkDualQuadAllFinished() {
        guard dualQuadActive else { return }
        let allLanesDone = laneStates.allSatisfy { $0.index >= $0.credentials.count }
        guard allLanesDone else { return }
        let stillWorking = enabledSessions.contains { $0.rcrRunning && $0.rcrStatus != .finished }
        guard !stillWorking else { return }
        dualQuadActive = false
        let totalSuccess = enabledSessions.reduce(0) { $0 + $1.rcrSuccessCount }
        let totalTried = laneStates.reduce(0) { $0 + $1.credentials.count }
        ParkedSessionStore.shared.markRunFinished()
        browserViewModel?.showToast("Dual RCR complete — \(totalSuccess) hits / \(totalTried) tried")
        browserViewModel?.offerNeedsReviewSummaryIfNeeded()
    }
}

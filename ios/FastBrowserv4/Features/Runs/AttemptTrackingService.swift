import Foundation
import SwiftData
import UIKit

/// Centralized read/write of `AttemptRecord` rows. All mutations go through
/// here so the rest of the app never touches SwiftData directly for attempts
/// — keeps the bulletproof tracking guarantees in one place.
@MainActor
final class AttemptTrackingService {
    static let shared = AttemptTrackingService()
    private init() {}

    /// True if this credential+password+domain combo already has a terminal
    /// (success / disabled) result. Used to skip already-finished attempts
    /// when resuming RCR.
    func isTerminallyAttempted(
        context: ModelContext,
        credentialID: String,
        passwordHash: String,
        targetDomain: String
    ) -> Bool {
        let descriptor = FetchDescriptor<AttemptRecord>(
            predicate: #Predicate<AttemptRecord> { rec in
                rec.credentialID == credentialID
                    && rec.passwordHash == passwordHash
                    && rec.targetDomain == targetDomain
                    && (rec.statusRaw == "success" || rec.statusRaw == "disabled" || rec.statusRaw == "review")
            }
        )
        return ((try? context.fetch(descriptor).first) != nil)
    }

    /// True if any password belonging to this credential has already been
    /// terminally attempted against the given domain. Used to skip an entire
    /// credential from the queue when resuming.
    func credentialIsFinished(
        context: ModelContext,
        credentialID: String,
        targetDomain: String,
        totalPasswords: Int
    ) -> Bool {
        // Success on any password = finished.
        let successDescriptor = FetchDescriptor<AttemptRecord>(
            predicate: #Predicate<AttemptRecord> { rec in
                rec.credentialID == credentialID
                    && rec.targetDomain == targetDomain
                    && (rec.statusRaw == "success" || rec.statusRaw == "review")
            }
        )
        if (try? context.fetch(successDescriptor).first) != nil { return true }

        // All passwords disabled or exhausted = finished.
        let terminalDescriptor = FetchDescriptor<AttemptRecord>(
            predicate: #Predicate<AttemptRecord> { rec in
                rec.credentialID == credentialID
                    && rec.targetDomain == targetDomain
                    && (rec.statusRaw == "disabled" || rec.statusRaw == "failed")
            }
        )
        let attempts = (try? context.fetch(terminalDescriptor)) ?? []
        let uniqueHashes = Set(attempts.map { $0.passwordHash })
        return uniqueHashes.count >= totalPasswords && totalPasswords > 0
    }

    /// Records (or updates) an attempt. If a `pending` row already exists
    /// for the same combo it is replaced in-place so we don't accumulate
    /// duplicate pendings during normal flow.
    @discardableResult
    func recordAttempt(
        context: ModelContext,
        credentialID: String,
        username: String,
        password: String,
        passwordIndex: Int,
        passwordTotal: Int,
        targetDomain: String,
        sessionTag: String,
        status: AttemptRecord.Status,
        resultURL: String? = nil,
        resultPageTitle: String? = nil,
        screenshotFilename: String? = nil,
        judge: SuccessJudgeEngine.Decision? = nil
    ) -> AttemptRecord {
        let hash = PasswordFingerprint.hash(password)
        let descriptor = FetchDescriptor<AttemptRecord>(
            predicate: #Predicate<AttemptRecord> { rec in
                rec.credentialID == credentialID
                    && rec.passwordHash == hash
                    && rec.targetDomain == targetDomain
            }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.statusRaw = status.rawValue
            existing.timestamp = Date()
            existing.passwordIndex = passwordIndex
            existing.passwordTotal = passwordTotal
            existing.sessionTag = sessionTag
            existing.username = username
            if let resultURL { existing.resultURL = resultURL }
            if let resultPageTitle { existing.resultPageTitle = resultPageTitle }
            if let screenshotFilename {
                if let old = existing.screenshotFilename, old != screenshotFilename {
                    ScreenshotStorage.delete(old)
                }
                existing.screenshotFilename = screenshotFilename
            }
            if let judge { apply(judge, to: existing) }
            try? context.save()
            return existing
        }

        let record = AttemptRecord(
            credentialID: credentialID,
            username: username,
            passwordHash: hash,
            passwordIndex: passwordIndex,
            passwordTotal: passwordTotal,
            targetDomain: targetDomain,
            sessionTag: sessionTag,
            status: status
        )
        record.resultURL = resultURL
        record.resultPageTitle = resultPageTitle
        record.screenshotFilename = screenshotFilename
        if let judge { apply(judge, to: record) }
        context.insert(record)
        try? context.save()
        return record
    }

    private func apply(_ judge: SuccessJudgeEngine.Decision, to record: AttemptRecord) {
        record.judgeVerdict = judge.verdict
        record.judgeConfidence = judge.confidence
        record.judgeReason = judge.reason
        record.judgeSource = judge.source
        record.judgeBrain = judge.brain
        if let ocr = judge.ocrCategory { record.ocrCategory = ocr }
    }

    /// Returns the count of distinct password fingerprints attempted for
    /// this credential (across all domains). Powers the vault's "X / Y
    /// tried" badge.
    func attemptedPasswordCount(context: ModelContext, credentialID: String) -> Int {
        let descriptor = FetchDescriptor<AttemptRecord>(
            predicate: #Predicate<AttemptRecord> { $0.credentialID == credentialID }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return Set(rows.map { $0.passwordHash }).count
    }

    /// Bulk variant for the vault list — runs one fetch and groups in
    /// memory, instead of N round-trips.
    func attemptedPasswordCounts(context: ModelContext) -> [String: Int] {
        let descriptor = FetchDescriptor<AttemptRecord>()
        let rows = (try? context.fetch(descriptor)) ?? []
        var byCred: [String: Set<String>] = [:]
        for row in rows {
            byCred[row.credentialID, default: []].insert(row.passwordHash)
        }
        return byCred.mapValues { $0.count }
    }

    /// Wipes attempt history for a single target domain. Used when the user
    /// presses RCR again after the entire vault has finished against that
    /// target — gives them a clean restart from the top.
    func clearAttempts(context: ModelContext, targetDomain: String) {
        let descriptor = FetchDescriptor<AttemptRecord>(
            predicate: #Predicate<AttemptRecord> { $0.targetDomain == targetDomain }
        )
        if let rows = try? context.fetch(descriptor) {
            for row in rows {
                if let f = row.screenshotFilename { ScreenshotStorage.delete(f) }
                context.delete(row)
            }
        }
        try? context.save()
    }

    /// Wipes attempt history for a specific set of credentials against a
    /// single target domain — used to restart one multi-window session's
    /// share from the top without touching other windows/pairs that share
    /// the same domain but haven't finished their own share yet.
    func clearAttempts(context: ModelContext, credentialIDs: Set<String>, targetDomain: String) {
        guard !credentialIDs.isEmpty else { return }
        let descriptor = FetchDescriptor<AttemptRecord>(
            predicate: #Predicate<AttemptRecord> { $0.targetDomain == targetDomain }
        )
        guard let rows = try? context.fetch(descriptor) else { return }
        for row in rows where credentialIDs.contains(row.credentialID) {
            if let f = row.screenshotFilename { ScreenshotStorage.delete(f) }
            context.delete(row)
        }
        try? context.save()
    }

    func clearAll(context: ModelContext) {
        let descriptor = FetchDescriptor<AttemptRecord>()
        if let rows = try? context.fetch(descriptor) {
            for row in rows {
                if let f = row.screenshotFilename { ScreenshotStorage.delete(f) }
                context.delete(row)
            }
        }
        ScreenshotStorage.deleteAll()
        try? context.save()
    }
}

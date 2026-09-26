import Foundation
import UIKit
import Vision

/// On-device OCR that classifies RCR post-submit screenshots into one of
/// four categories: success, failure, captcha, or locked. All Vision work
/// runs off the main actor so the runner never blocks on image analysis.
enum ScreenshotOCRService {

    enum Category: String, CaseIterable {
        case success = "Login Success"
        case failure = "Login Failure"
        case captcha = "Captcha Triggered"
        case locked = "Account Locked"
        case unknown = "Unknown"
    }

    /// Extracts text from `image` using the on-device Vision framework,
    /// then keyword-matches the result against five categories. Runs
    /// entirely off the main actor so the RCR loop stays responsive.
    nonisolated static func classify(_ image: UIImage) async -> (category: Category, allText: String) {
        guard let cgImage = image.cgImage else {
            return (.unknown, "")
        }

        let extracted = await extractText(cgImage: cgImage)
        let category = categorize(extracted)
        return (category, extracted)
    }

    // MARK: - Private

    nonisolated private static func extractText(cgImage: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }
                let allText = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
                continuation.resume(returning: allText)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            // If the request throws instead of invoking its completion
            // handler, the continuation must still resume — otherwise the
            // caller hangs forever.
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: "")
            }
        }
    }

    nonisolated private static func categorize(_ text: String) -> Category {
        let lower = text.lowercased()

        // Order matters — locked and captcha trump failure, which trumps success.

        // Account Locked
        if lower.contains("been disabled")
            || lower.contains("account is locked")
            || lower.contains("account locked")
            || lower.contains("your account has been suspended")
            || lower.contains("account suspended")
            || lower.contains("your account is blocked") {
            return .locked
        }

        // Captcha
        if lower.contains("captcha")
            || lower.contains("verify you are human")
            || lower.contains("are you a robot")
            || lower.contains("not a robot")
            || lower.contains("complete the security check")
            || lower.contains("please verify")
            || lower.contains("security challenge")
            || lower.contains("prove you are human") {
            return .captcha
        }

        // Login Failure
        if lower.contains("invalid")
            || lower.contains("incorrect")
            || lower.contains("wrong password")
            || lower.contains("wrong email")
            || lower.contains("try again")
            || lower.contains("not recognized")
            || lower.contains("no account found")
            || lower.contains("password is incorrect")
            || lower.contains("email or password is incorrect")
            || lower.contains("login failed")
            || lower.contains("could not sign in")
            || lower.contains("doesn't match")
            || lower.contains("didn't match") {
            return .failure
        }

        // Login Success — must check text (not just lower) for exact "Welcome!"
        // case-sensitive marker; also broad lowercased signs.
        if text.contains("Welcome!")
            || lower.contains("welcome back")
            || lower.contains("dashboard")
            || lower.contains("my account")
            || lower.contains("sign out")
            || lower.contains("log out")
            || lower.contains("account balance")
            || lower.contains("deposit")
            || lower.contains("withdraw")
            || lower.contains("cashier")
            || lower.contains("recently played")
            || lower.contains("my balance") {
            return .success
        }

        return .unknown
    }
}

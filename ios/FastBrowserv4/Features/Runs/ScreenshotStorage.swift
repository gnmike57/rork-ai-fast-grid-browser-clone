import Foundation
import UIKit
import ImageIO
import CryptoKit

/// On-disk store for RCR post-submit screenshots. Files live under
/// `Application Support/RCRScreenshots` and are named with random UUIDs so
/// no PII leaks into the filesystem.
@MainActor
enum ScreenshotStorage {
    static let directoryName = "RCRScreenshots"

    static var directory: URL {
        // Application Support is guaranteed to resolve on iOS, but a force
        // unwrap here would crash the whole app for a directory lookup;
        // falling back to the caches directory keeps screenshots working.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.cachesDirectory
        let dir = base.appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
        return dir
    }

    /// Persists `image` as a JPEG (quality 0.7 — plenty for thumbnails) and
    /// returns the relative filename, or `nil` on failure. Screenshots show
    /// post-login pages (balances, account data), so files are written with
    /// complete file protection — unreadable while the device is locked.
    /// Encoding runs off the main thread — a full-page snapshot encode can
    /// take real time, and a 16-window run judges attempts constantly.
    @discardableResult
    static func save(_ image: UIImage) async -> String? {
        let name = UUID().uuidString + ".jpg"
        let fileURL = directory.appendingPathComponent(name)
        // UIImage's read-only operations (jpegData) are safe off the main
        // thread, and UIImage is Sendable, so the encode hops straight
        // off-actor with no unsafe opt-out needed.
        let wrote: Bool = await Task.detached(priority: .utility) {
            guard let data = image.jpegData(compressionQuality: 0.7) else { return false }
            do {
                try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
                return true
            } catch {
                return false
            }
        }.value
        return wrote ? name : nil
    }

    static func url(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// Bounded decode caches — evict automatically under memory pressure
    /// instead of growing forever like a plain dictionary. Thumbnails and
    /// full images are cached separately since a screen may want either.
    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 40
        return cache
    }()
    private static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    static func loadImage(_ filename: String) -> UIImage? {
        let key = filename as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: url(for: filename).path) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    /// Decode off the main thread; used when a screen needs the full-size
    /// image (e.g. the attempt detail view).
    static func loadImageAsync(_ filename: String) async -> UIImage? {
        let key = filename as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        let path = url(for: filename).path
        let image = await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: path)
        }.value
        if let image { imageCache.setObject(image, forKey: key) }
        return image
    }

    /// Downsampled thumbnail for list/grid rows — decodes at a small pixel
    /// size using ImageIO instead of decoding (and caching) the full-size
    /// JPEG just to show a 48–110pt row. Dramatically cheaper for a large
    /// results grid.
    static func loadThumbnailAsync(_ filename: String, maxDimension: CGFloat = 160) async -> UIImage? {
        let key = filename as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        let path = url(for: filename).path
        let thumbnail = await Task.detached(priority: .userInitiated) {
            Self.downsample(path: path, maxDimension: maxDimension)
        }.value
        if let thumbnail { thumbnailCache.setObject(thumbnail, forKey: key) }
        return thumbnail
    }

    nonisolated private static func downsample(path: String, maxDimension: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    static func delete(_ filename: String) {
        let key = filename as NSString
        imageCache.removeObject(forKey: key)
        thumbnailCache.removeObject(forKey: key)
        try? FileManager.default.removeItem(at: url(for: filename))
    }

    static func deleteAll() {
        imageCache.removeAllObjects()
        thumbnailCache.removeAllObjects()
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items {
            try? fm.removeItem(at: item)
        }
    }
}

/// Truncated SHA-256 used to fingerprint a password without ever storing it
/// outside the keychain.
nonisolated enum PasswordFingerprint {
    static func hash(_ password: String) -> String {
        let digest = SHA256.hash(data: Data(password.utf8))
        return digest.map { String(format: "%02x", $0) }.prefix(16).joined()
    }
}

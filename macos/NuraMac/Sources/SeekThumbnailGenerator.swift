import AppKit
@preconcurrency import AVFoundation

final class SeekThumbnailRequest: @unchecked Sendable {
    private let cancelHandler: () -> Void
    private var cancelled = false
    private let lock = NSLock()

    init(cancelHandler: @escaping () -> Void) {
        self.cancelHandler = cancelHandler
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        lock.unlock()
        cancelHandler()
    }
}

struct SeekThumbnailResult {
    let image: NSImage
    let position: Double
}

@MainActor
final class SeekThumbnailGenerator {
    private let cache = NSCache<NSString, NSImage>()
    private let previewSize = NSSize(width: 180, height: 102)

    init() {
        cache.countLimit = 120
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func request(
        source: URL,
        position: Double,
        completion: @escaping @MainActor (SeekThumbnailResult?) -> Void
    ) -> SeekThumbnailRequest {
        guard source.isFileURL else {
            Task { @MainActor in completion(nil) }
            return SeekThumbnailRequest(cancelHandler: {})
        }

        let key = cacheKey(source: source, position: position)
        if let image = cache.object(forKey: key as NSString) {
            Task { @MainActor in completion(SeekThumbnailResult(image: image, position: position)) }
            return SeekThumbnailRequest(cancelHandler: {})
        }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = previewSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let request = SeekThumbnailRequest {
            generator.cancelAllCGImageGeneration()
        }
        let time = CMTime(seconds: position, preferredTimescale: 600)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { [weak self, weak request] _, image, _, result, _ in
            guard result == .succeeded, let image, let self else {
                Task { @MainActor in completion(nil) }
                return
            }
            guard request != nil else { return }
            Task { @MainActor in
                let nsImage = NSImage(cgImage: image, size: self.previewSize)
                let cost = Int(self.previewSize.width * self.previewSize.height * 4)
                self.cache.setObject(nsImage, forKey: key as NSString, cost: cost)
                completion(SeekThumbnailResult(image: nsImage, position: position))
            }
        }
        return request
    }

    func clearCache() {
        cache.removeAllObjects()
    }

    private func cacheKey(source: URL, position: Double) -> String {
        let canonicalPath = source.standardizedFileURL.path
        return "\(canonicalPath)|\(String(format: "%.2f", position))|\(Int(previewSize.width))x\(Int(previewSize.height))"
    }
}

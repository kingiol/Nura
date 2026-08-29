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
    private var cachedSource: URL?
    private var cachedGenerator: AVAssetImageGenerator?

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

        if source.pathExtension.lowercased() == "webm" {
            return requestWithFFmpeg(source: source, position: position, completion: completion)
        }

        let key = cacheKey(source: source, position: position)
        if let image = cache.object(forKey: key as NSString) {
            Task { @MainActor in completion(SeekThumbnailResult(image: image, position: position)) }
            return SeekThumbnailRequest(cancelHandler: {})
        }

        let generator: AVAssetImageGenerator
        if cachedSource == source, let cachedGenerator {
            generator = cachedGenerator
        } else {
            generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
            cachedSource = source
            cachedGenerator = generator
        }
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = previewSize
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

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
        cachedSource = nil
        cachedGenerator = nil
    }

    private func cacheKey(source: URL, position: Double) -> String {
        let canonicalPath = source.standardizedFileURL.path
        return "\(canonicalPath)|\(String(format: "%.2f", position))|\(Int(previewSize.width))x\(Int(previewSize.height))"
    }

    private func requestWithFFmpeg(
        source: URL,
        position: Double,
        completion: @escaping @MainActor (SeekThumbnailResult?) -> Void
    ) -> SeekThumbnailRequest {
        guard let executable = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ].map(URL.init(fileURLWithPath:)).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            Task { @MainActor in completion(nil) }
            return SeekThumbnailRequest(cancelHandler: {})
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Nura/SeekThumbnails", isDirectory: true)
        let output = directory.appendingPathComponent("\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "-hide_banner", "-loglevel", "error",
            "-ss", String(format: "%.3f", position),
            "-i", source.path,
            "-frames:v", "1",
            "-vf", "scale=320:180:force_original_aspect_ratio=decrease,pad=320:180:(ow-iw)/2:(oh-ih)/2",
            "-y", output.path
        ]

        let job = FFmpegThumbnailJob(process: process, output: output)
        let request = SeekThumbnailRequest {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: output)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    Task { @MainActor in completion(nil) }
                    return
                }
                let data = try Data(contentsOf: output)
                Task { @MainActor in
                    defer { try? FileManager.default.removeItem(at: output) }
                    guard let image = NSImage(data: data) else {
                        completion(nil)
                        return
                    }
                    let key = self.cacheKey(source: source, position: position)
                    let cost = Int(self.previewSize.width * self.previewSize.height * 4)
                    self.cache.setObject(image, forKey: key as NSString, cost: cost)
                    completion(SeekThumbnailResult(image: image, position: position))
                }
            } catch {
                Task { @MainActor in completion(nil) }
            }
            _ = job
        }
        return request
    }
}

private final class FFmpegThumbnailJob: @unchecked Sendable {
    let process: Process
    let output: URL

    init(process: Process, output: URL) {
        self.process = process
        self.output = output
    }
}

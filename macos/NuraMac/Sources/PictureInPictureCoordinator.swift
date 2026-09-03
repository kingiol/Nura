import AVFoundation
import AVKit
import CoreVideo
import Foundation
import OSLog
import QuartzCore

private typealias GLInt = Int32
private typealias GLSize = Int32
private typealias GLEnum = UInt32

@_silgen_name("glReadPixels") private func nura_glReadPixels(
    _ x: GLInt,
    _ y: GLInt,
    _ width: GLSize,
    _ height: GLSize,
    _ format: GLEnum,
    _ type: GLEnum,
    _ pixels: UnsafeMutableRawPointer?
)
@_silgen_name("glBindFramebuffer") private func nura_glBindFramebuffer(_ target: GLEnum, _ framebuffer: GLInt)

private let nuraGLRGBA: GLEnum = 0x1908
private let nuraGLUnsignedByte: GLEnum = 0x1401

final class PictureInPictureCoordinator: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    private let logger = Logger(subsystem: "com.nura.Nura", category: "PictureInPicture")
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let onPlayingChange: (Bool) -> Void
    private let onSeekRelative: (Double) -> Void
    private let currentPlaybackState: () -> (isPlaying: Bool, duration: Double)
    private let reportError: (String) -> Void

    private var controller: AVPictureInPictureController?
    private var readbackBuffer: [UInt8] = []
    private var currentFormatDescription: CMVideoFormatDescription?
    private var currentDimensions: CMVideoDimensions = .init(width: 0, height: 0)
    private var captureEnabled = false
    private var startRequested = false
    private var lastFrameTime: CFTimeInterval = 0
    private var captureStartTime: CFTimeInterval?
    private var loggedFirstFrame = false
    private var controlTimebase: CMTimebase?
    private(set) var isActive = false

    init(
        onPlayingChange: @escaping (Bool) -> Void,
        onSeekRelative: @escaping (Double) -> Void,
        currentPlaybackState: @escaping () -> (isPlaying: Bool, duration: Double),
        reportError: @escaping (String) -> Void
    ) {
        self.onPlayingChange = onPlayingChange
        self.onSeekRelative = onSeekRelative
        self.currentPlaybackState = currentPlaybackState
        self.reportError = reportError
        super.init()

        displayLayer.videoGravity = .resizeAspect
        var timebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        ) == noErr, let timebase {
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 1)
            controlTimebase = timebase
            displayLayer.controlTimebase = timebase
        }
    }

    func toggle() {
        if isActive || captureEnabled { stop() } else { start() }
    }

    func start() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            reportError("Picture in Picture is not supported on this Mac")
            return
        }
        captureEnabled = true
        startRequested = true
        captureStartTime = nil
        lastFrameTime = 0
        loggedFirstFrame = false
        if let controlTimebase {
            CMTimebaseSetTime(controlTimebase, time: .zero)
            CMTimebaseSetRate(controlTimebase, rate: 1)
        }
        startIfPossible()
    }

    func stop() {
        captureEnabled = false
        startRequested = false
        captureStartTime = nil
        guard let controller, controller.isPictureInPictureActive else {
            isActive = false
            return
        }
        controller.stopPictureInPicture()
    }

    func invalidatePlaybackState() {
        controller?.invalidatePlaybackState()
    }

    /// Called while the model's OpenGL context is current.
    func appendFrame(framebuffer: Int32, width: Int32, height: Int32) {
        guard captureEnabled, width > 0, height > 0 else { return }
        let now = CACurrentMediaTime()
        guard now - lastFrameTime >= (1.0 / 30.0) else { return }
        lastFrameTime = now
        let pixelCount = Int(width) * Int(height) * 4
        if readbackBuffer.count != pixelCount {
            readbackBuffer = [UInt8](repeating: 0, count: pixelCount)
        }
        // AVKit mirrors this layer into the PiP window on macOS. Keep a
        // concrete, non-zero geometry so the mirrored layer has a render size.
        displayLayer.frame = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        displayLayer.bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        ensureController()
        nura_glBindFramebuffer(0x8D40, framebuffer)
        readbackBuffer.withUnsafeMutableBytes { bytes in
            nura_glReadPixels(0, 0, width, height, nuraGLRGBA, nuraGLUnsignedByte, bytes.baseAddress)
        }

        guard let pixelBuffer = makePixelBuffer(width: width, height: height) else { return }
        var formatDescription = currentFormatDescription
        if currentDimensions.width != width || currentDimensions.height != height || formatDescription == nil {
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: nil,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription
            ) == noErr else { return }
            currentFormatDescription = formatDescription
            currentDimensions = CMVideoDimensions(width: width, height: height)
        }
        guard let formatDescription else { return }

        let captureNow = CACurrentMediaTime()
        if captureStartTime == nil { captureStartTime = captureNow }
        let presentationTime = CMTime(
            seconds: max(0, captureNow - (captureStartTime ?? captureNow)),
            preferredTimescale: 600
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }
        CMSetAttachment(
            sampleBuffer,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate
        )
        if displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
        if !loggedFirstFrame {
            loggedFirstFrame = true
            logger.info("queued first PiP frame \(width)x\(height), layerStatus=\(String(describing: self.displayLayer.status.rawValue)), ready=\(self.displayLayer.isReadyForMoreMediaData)")
        }
        startIfPossible()
    }

    private func startIfPossible() {
        guard startRequested, let controller else { return }
        guard controller.isPictureInPicturePossible else { return }
        startRequested = false
        controller.startPictureInPicture()
    }

    private func ensureController() {
        guard controller == nil else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let newController = AVPictureInPictureController(contentSource: source)
        newController.delegate = self
        controller = newController
    }

    private func makePixelBuffer(width: Int32, height: Int32) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(width),
            Int(height),
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess,
              let pixelBuffer,
              CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return nil }
        guard let destination = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            return nil
        }

        let sourceRowBytes = Int(width) * 4
        let destinationRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let destinationBytes = destination.assumingMemoryBound(to: UInt8.self)
        for row in 0..<Int(height) {
            let sourceRow = Int(height) - row - 1
            let sourceOffset = sourceRow * sourceRowBytes
            let destinationOffset = row * destinationRowBytes
            for column in 0..<Int(width) {
                let source = sourceOffset + column * 4
                let target = destinationOffset + column * 4
                destinationBytes[target] = readbackBuffer[source + 2]
                destinationBytes[target + 1] = readbackBuffer[source + 1]
                destinationBytes[target + 2] = readbackBuffer[source]
                destinationBytes[target + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {}

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
        invalidatePlaybackState()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        captureEnabled = false
        startRequested = false
        captureStartTime = nil
        loggedFirstFrame = false
        isActive = false
        reportError("Unable to start Picture in Picture: \(error.localizedDescription)")
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {}

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        captureEnabled = false
        startRequested = false
        isActive = false
        displayLayer.flush()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        onPlayingChange(playing)
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        let duration = currentPlaybackState().duration
        guard duration.isFinite, duration > 0 else {
            // A transiently unknown duration must not make AVKit show an
            // endless loading state while the first frames are already queued.
            return CMTimeRange(start: .zero, duration: .positiveInfinity)
        }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        !currentPlaybackState().isPlaying
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        onSeekRelative(skipInterval.seconds)
        completionHandler()
    }
}

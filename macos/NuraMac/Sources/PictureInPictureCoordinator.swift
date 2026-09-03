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
    private let onActiveChange: (Bool) -> Void

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
    private var pipRenderSize = CMVideoDimensions(width: 480, height: 270)
    private let maxPiPRenderSize = CMVideoDimensions(width: 480, height: 270)
    private(set) var isActive = false

    init(
        onPlayingChange: @escaping (Bool) -> Void,
        onSeekRelative: @escaping (Double) -> Void,
        currentPlaybackState: @escaping () -> (isPlaying: Bool, duration: Double),
        reportError: @escaping (String) -> Void,
        onActiveChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.onPlayingChange = onPlayingChange
        self.onSeekRelative = onSeekRelative
        self.currentPlaybackState = currentPlaybackState
        self.reportError = reportError
        self.onActiveChange = onActiveChange
        super.init()

        displayLayer.videoGravity = .resizeAspect
        displayLayer.contentsScale = 1
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
    func appendFrame(
        framebuffer: Int32,
        width: Int32,
        height: Int32,
        videoWidth: Int32?,
        videoHeight: Int32?
    ) {
        guard captureEnabled, width > 0, height > 0 else { return }
        let now = CACurrentMediaTime()
        guard now - lastFrameTime >= (1.0 / 30.0) else { return }
        lastFrameTime = now
        let captureRegion = videoCaptureRegion(
            viewportWidth: Int(width),
            viewportHeight: Int(height),
            videoWidth: videoWidth,
            videoHeight: videoHeight
        )
        let pixelCount = Int(width) * Int(height) * 4
        if readbackBuffer.count != pixelCount {
            readbackBuffer = [UInt8](repeating: 0, count: pixelCount)
        }
        // AVKit mirrors this layer into the PiP window on macOS. Keep a
        // concrete, non-zero geometry so the mirrored layer has a render size.
        let outputSize = outputDimensions(for: captureRegion)
        let layerWidth = CGFloat(outputSize.width)
        let layerHeight = CGFloat(outputSize.height)
        displayLayer.frame = CGRect(x: 0, y: 0, width: layerWidth, height: layerHeight)
        displayLayer.bounds = CGRect(x: 0, y: 0, width: layerWidth, height: layerHeight)
        ensureController()
        nura_glBindFramebuffer(0x8D40, framebuffer)
        readbackBuffer.withUnsafeMutableBytes { bytes in
            nura_glReadPixels(0, 0, width, height, nuraGLRGBA, nuraGLUnsignedByte, bytes.baseAddress)
        }

        guard let pixelBuffer = makePixelBuffer(
            sourceWidth: width,
            sourceHeight: height,
            cropX: captureRegion.originX,
            cropTop: captureRegion.originY,
            cropWidth: captureRegion.width,
            cropHeight: captureRegion.height,
            width: outputSize.width,
            height: outputSize.height
        ) else { return }
        var formatDescription = currentFormatDescription
        let outputWidth = Int32(outputSize.width)
        let outputHeight = Int32(outputSize.height)
        if currentDimensions.width != outputWidth || currentDimensions.height != outputHeight || formatDescription == nil {
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: nil,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription
            ) == noErr else { return }
            currentFormatDescription = formatDescription
            currentDimensions = CMVideoDimensions(width: outputWidth, height: outputHeight)
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
            logger.info("queued first PiP frame \(outputWidth)x\(outputHeight), layerStatus=\(String(describing: self.displayLayer.status.rawValue)), ready=\(self.displayLayer.isReadyForMoreMediaData)")
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

    private func makePixelBuffer(
        sourceWidth: Int32,
        sourceHeight: Int32,
        cropX: Int,
        cropTop: Int,
        cropWidth: Int,
        cropHeight: Int,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
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

        let sourceRowBytes = Int(sourceWidth) * 4
        let destinationRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let destinationBytes = destination.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let sourceCropRow = min(cropHeight - 1, (row * cropHeight) / height)
            let sourceRow = Int(sourceHeight) - cropTop - sourceCropRow - 1
            let sourceOffset = sourceRow * sourceRowBytes + cropX * 4
            let destinationOffset = row * destinationRowBytes
            for column in 0..<width {
                let sourceColumn = min(cropWidth - 1, (column * cropWidth) / width)
                let source = sourceOffset + sourceColumn * 4
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

    private func outputDimensions(
        for region: (originX: Int, originY: Int, width: Int, height: Int)
    ) -> (width: Int, height: Int) {
        let sourceAspect = Double(region.width) / Double(region.height)
        let targetWidth = max(2, Int(pipRenderSize.width))
        let targetHeight = max(2, Int(pipRenderSize.height))
        let targetAspect = Double(targetWidth) / Double(targetHeight)
        guard sourceAspect.isFinite, sourceAspect > 0, targetAspect.isFinite, targetAspect > 0 else {
            return (targetWidth, targetHeight)
        }

        if sourceAspect > targetAspect {
            return (targetWidth, max(2, Int((Double(targetWidth) / sourceAspect).rounded())))
        }
        return (max(2, Int((Double(targetHeight) * sourceAspect).rounded())), targetHeight)
    }

    private func videoCaptureRegion(
        viewportWidth: Int,
        viewportHeight: Int,
        videoWidth: Int32?,
        videoHeight: Int32?
    ) -> (originX: Int, originY: Int, width: Int, height: Int) {
        guard let videoWidth, let videoHeight, videoWidth > 0, videoHeight > 0 else {
            return (0, 0, viewportWidth, viewportHeight)
        }
        let viewportAspect = Double(viewportWidth) / Double(viewportHeight)
        let videoAspect = Double(videoWidth) / Double(videoHeight)
        guard viewportAspect.isFinite, videoAspect.isFinite, viewportAspect > 0, videoAspect > 0 else {
            return (0, 0, viewportWidth, viewportHeight)
        }

        if viewportAspect > videoAspect {
            let croppedWidth = max(2, Int((Double(viewportHeight) * videoAspect).rounded()))
            return ((viewportWidth - croppedWidth) / 2, 0, croppedWidth, viewportHeight)
        }

        let croppedHeight = max(2, Int((Double(viewportWidth) / videoAspect).rounded()))
        return (0, (viewportHeight - croppedHeight) / 2, viewportWidth, croppedHeight)
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {}

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
        onActiveChange(true)
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
        onActiveChange(false)
        reportError("Unable to start Picture in Picture: \(error.localizedDescription)")
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {}

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        captureEnabled = false
        startRequested = false
        isActive = false
        onActiveChange(false)
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
    ) {
        guard newRenderSize.width > 0, newRenderSize.height > 0 else { return }
        pipRenderSize = CMVideoDimensions(
            width: min(newRenderSize.width, maxPiPRenderSize.width),
            height: min(newRenderSize.height, maxPiPRenderSize.height)
        )
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        onSeekRelative(skipInterval.seconds)
        completionHandler()
    }
}

import AppKit
@preconcurrency import AVFoundation
import AVKit
import CoreVideo
import Foundation
import OSLog
import QuartzCore

private typealias GLInt = Int32
private typealias GLSize = Int32
private typealias GLEnum = UInt32

@_silgen_name("glGetIntegerv") private func nura_glGetIntegerv(_ name: GLEnum, _ value: UnsafeMutablePointer<GLInt>)
@_silgen_name("glBindFramebuffer") private func nura_glBindFramebuffer(_ target: GLEnum, _ framebuffer: GLInt)
@_silgen_name("glGenFramebuffers") private func nura_glGenFramebuffers(_ count: GLSize, _ framebuffers: UnsafeMutablePointer<GLInt>)
@_silgen_name("glFramebufferTexture2D") private func nura_glFramebufferTexture2D(
    _ target: GLEnum,
    _ attachment: GLEnum,
    _ textureTarget: GLEnum,
    _ texture: UInt32,
    _ level: GLInt
)
@_silgen_name("glCheckFramebufferStatus") private func nura_glCheckFramebufferStatus(_ target: GLEnum) -> GLEnum
@_silgen_name("glFlush") private func nura_glFlush()
private let nuraGLFramebuffer: GLEnum = 0x8D40
private let nuraGLDrawFramebuffer: GLEnum = 0x8CA9
private let nuraGLReadFramebuffer: GLEnum = 0x8CA8
private let nuraGLDrawFramebufferBinding: GLEnum = 0x8CA6
private let nuraGLReadFramebufferBinding: GLEnum = 0x8CAA
private let nuraGLColorAttachment0: GLEnum = 0x8CE0
private let nuraGLFramebufferComplete: GLEnum = 0x8CD5

struct PictureInPictureRenderSize: Equatable {
    let width: Int32
    let height: Int32

    static func validated(width: Int32, height: Int32) -> Self {
        Self(
            width: max(2, width),
            height: max(2, height)
        )
    }

    static func aspectFit(
        sourceWidth: Int32,
        sourceHeight: Int32,
        targetWidth: Int32,
        targetHeight: Int32
    ) -> Self {
        let safeSourceWidth = max(1, sourceWidth)
        let safeSourceHeight = max(1, sourceHeight)
        let safeTargetWidth = max(2, targetWidth)
        let safeTargetHeight = max(2, targetHeight)
        let sourceAspect = Double(safeSourceWidth) / Double(safeSourceHeight)
        let targetAspect = Double(safeTargetWidth) / Double(safeTargetHeight)

        if sourceAspect > targetAspect {
            return validated(
                width: safeTargetWidth,
                height: max(2, Int32((Double(safeTargetWidth) / sourceAspect).rounded()))
            )
        }

        return validated(
            width: max(2, Int32((Double(safeTargetHeight) * sourceAspect).rounded())),
            height: safeTargetHeight
        )
    }
}

@MainActor
final class PictureInPictureCoordinator: NSObject, @MainActor AVPictureInPictureControllerDelegate, @MainActor AVPictureInPictureSampleBufferPlaybackDelegate {
    private let logger = Logger(subsystem: "com.nura.Nura", category: "PictureInPicture")
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let onPlayingChange: (Bool) -> Void
    private let onSeekRelative: (Double) -> Void
    private let currentPlaybackState: () -> (isPlaying: Bool, duration: Double)
    private let reportError: (String) -> Void
    private let onActiveChange: (Bool) -> Void
    private let videoDimensions: () -> (width: Int32, height: Int32)?
    private let renderFrame: (Int32, Int32, Int32) -> Bool

    private var controller: AVPictureInPictureController?
    private var textureCache: CVOpenGLTextureCache?
    private var pipFramebuffer: GLInt = 0
    private var currentFormatDescription: CMVideoFormatDescription?
    private var currentDimensions: CMVideoDimensions = .init(width: 0, height: 0)
    private var captureEnabled = false
    private var startRequested = false
    private var lastFrameTime: CFTimeInterval = 0
    private var captureStartTime: CFTimeInterval?
    private var loggedFirstFrame = false
    private var controlTimebase: CMTimebase?
    // macOS mirrors sample-buffer PIP content at its pixel dimensions. Keep
    // this aligned with AVKit's latest render-size callback.
    private var pipRenderSize = CMVideoDimensions(width: 320, height: 180)
    private(set) var isActive = false

    init(
        onPlayingChange: @escaping (Bool) -> Void,
        onSeekRelative: @escaping (Double) -> Void,
        currentPlaybackState: @escaping () -> (isPlaying: Bool, duration: Double),
        reportError: @escaping (String) -> Void,
        videoDimensions: @escaping () -> (width: Int32, height: Int32)? = { nil },
        renderFrame: @escaping (Int32, Int32, Int32) -> Bool,
        onActiveChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.onPlayingChange = onPlayingChange
        self.onSeekRelative = onSeekRelative
        self.currentPlaybackState = currentPlaybackState
        self.reportError = reportError
        self.videoDimensions = videoDimensions
        self.renderFrame = renderFrame
        self.onActiveChange = onActiveChange
        super.init()

        displayLayer.videoGravity = .resizeAspect
        displayLayer.contentsScale = 1
        let initialLayerSize = CGSize(width: 320, height: 180)
        displayLayer.frame = CGRect(origin: .zero, size: initialLayerSize)
        displayLayer.bounds = CGRect(origin: .zero, size: initialLayerSize)
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
            reportError(L10n.text("Picture in Picture is not supported on this Mac"))
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
        width: Int32,
        height: Int32,
        openGLContext: NSOpenGLContext
    ) {
        guard captureEnabled, width > 0, height > 0 else { return }
        let now = CACurrentMediaTime()
        guard now - lastFrameTime >= (1.0 / 30.0) else { return }
        lastFrameTime = now
        ensureController()
        let outputSize = outputDimensions()
        guard let pixelBuffer = renderPixelBuffer(
            width: outputSize.width,
            height: outputSize.height,
            openGLContext: openGLContext
        ) else { return }
        var formatDescription = currentFormatDescription
        let outputWidth = Int32(outputSize.width)
        let outputHeight = Int32(outputSize.height)
        let dimensionsChanged = currentDimensions.width != outputWidth || currentDimensions.height != outputHeight
        if dimensionsChanged {
            displayLayer.flush()
        }
        if dimensionsChanged || formatDescription == nil {
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
            logger.info(
                "queued first PiP frame sourceViewport=\(width)x\(height), output=\(outputWidth)x\(outputHeight), layerStatus=\(String(describing: self.displayLayer.status.rawValue)), ready=\(self.displayLayer.isReadyForMoreMediaData)"
            )
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

    private func renderPixelBuffer(
        width: Int,
        height: Int,
        openGLContext: NSOpenGLContext
    ) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferOpenGLCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess else { return nil }
        guard let pixelBuffer else { return nil }

        if textureCache == nil {
            guard let cglContext = openGLContext.cglContextObj,
                  let cglPixelFormat = openGLContext.pixelFormat.cglPixelFormatObj else {
                return nil
            }
            var cache: CVOpenGLTextureCache?
            guard CVOpenGLTextureCacheCreate(
                kCFAllocatorDefault,
                nil,
                cglContext,
                cglPixelFormat,
                nil,
                &cache
            ) == kCVReturnSuccess else { return nil }
            textureCache = cache
        }
        guard let textureCache else { return nil }
        var texture: CVOpenGLTexture?
        guard CVOpenGLTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            &texture
        ) == kCVReturnSuccess, let texture else { return nil }

        var previousDrawFramebuffer: GLInt = 0
        var previousReadFramebuffer: GLInt = 0
        nura_glGetIntegerv(nuraGLDrawFramebufferBinding, &previousDrawFramebuffer)
        nura_glGetIntegerv(nuraGLReadFramebufferBinding, &previousReadFramebuffer)
        if pipFramebuffer == 0 {
            nura_glGenFramebuffers(1, &pipFramebuffer)
        }
        guard pipFramebuffer != 0 else { return nil }
        nura_glBindFramebuffer(nuraGLFramebuffer, pipFramebuffer)
        let textureTarget = CVOpenGLTextureGetTarget(texture)
        nura_glFramebufferTexture2D(
            nuraGLFramebuffer,
            nuraGLColorAttachment0,
            textureTarget,
            CVOpenGLTextureGetName(texture),
            0
        )
        let framebufferStatus = nura_glCheckFramebufferStatus(nuraGLFramebuffer)
        guard framebufferStatus == nuraGLFramebufferComplete else {
            nura_glFramebufferTexture2D(nuraGLFramebuffer, nuraGLColorAttachment0, textureTarget, 0, 0)
            restoreFramebuffers(draw: previousDrawFramebuffer, read: previousReadFramebuffer)
            logger.error("PiP pixel-buffer framebuffer is incomplete: \(framebufferStatus)")
            return nil
        }

        let rendered = renderFrame(pipFramebuffer, Int32(width), Int32(height))
        nura_glFlush()
        nura_glFramebufferTexture2D(nuraGLFramebuffer, nuraGLColorAttachment0, textureTarget, 0, 0)
        restoreFramebuffers(draw: previousDrawFramebuffer, read: previousReadFramebuffer)
        guard rendered else { return nil }
        return pixelBuffer
    }

    private func restoreFramebuffers(draw: GLInt, read: GLInt) {
        nura_glBindFramebuffer(nuraGLDrawFramebuffer, draw)
        nura_glBindFramebuffer(nuraGLReadFramebuffer, read)
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
        reportError(L10n.format("Unable to start Picture in Picture: %@", error.localizedDescription))
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
        logger.info("PiP render size changed to \(newRenderSize.width)x\(newRenderSize.height)")
        let renderSize = PictureInPictureRenderSize.validated(
            width: newRenderSize.width,
            height: newRenderSize.height
        )
        pipRenderSize = CMVideoDimensions(width: renderSize.width, height: renderSize.height)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        onSeekRelative(skipInterval.seconds)
        completionHandler()
    }

    private func outputDimensions() -> (width: Int, height: Int) {
        let targetWidth = max(2, Int(pipRenderSize.width))
        let targetHeight = max(2, Int(pipRenderSize.height))
        guard let videoDimensions = videoDimensions(),
              videoDimensions.width > 0,
              videoDimensions.height > 0 else {
            return (targetWidth, targetHeight)
        }

        let renderSize = PictureInPictureRenderSize.aspectFit(
            sourceWidth: videoDimensions.width,
            sourceHeight: videoDimensions.height,
            targetWidth: Int32(targetWidth),
            targetHeight: Int32(targetHeight)
        )
        return (Int(renderSize.width), Int(renderSize.height))
    }

}

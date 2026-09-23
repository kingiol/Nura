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
@_silgen_name("glReadBuffer") private func nura_glReadBuffer(_ mode: GLEnum)
@_silgen_name("glGetError") private func nura_glGetError() -> GLEnum

private let nuraGLRGBA: GLEnum = 0x1908
private let nuraGLUnsignedByte: GLEnum = 0x1401
private let nuraGLNoError: GLEnum = 0
private let nuraGLBack: GLEnum = 0x0405
private let nuraGLColorAttachment0: GLEnum = 0x8CE0

struct PictureInPictureCaptureRegion: Equatable {
    let originX: Int
    let originY: Int
    let width: Int
    let height: Int

    static func resolve(
        viewportWidth: Int,
        viewportHeight: Int
    ) -> Self {
        // The OpenGL viewport is the authoritative rendered image. Video
        // metadata can describe a different display matrix, aspect override,
        // zoom, or rotation, so cropping from it can remove valid pixels.
        return Self(originX: 0, originY: 0, width: viewportWidth, height: viewportHeight)
    }
}

struct PictureInPictureRenderSize: Equatable {
    let width: Int32
    let height: Int32

    static func validated(width: Int32, height: Int32) -> Self {
        Self(
            width: max(2, width),
            height: max(2, height)
        )
    }

    static func fromContentSize(_ size: CGSize, scale: CGFloat) -> Self? {
        guard size.width.isFinite, size.height.isFinite,
              scale.isFinite, size.width > 0, size.height > 0, scale > 0 else {
            return nil
        }
        return validated(
            width: Int32((size.width * scale).rounded()),
            height: Int32((size.height * scale).rounded())
        )
    }
}

struct PictureInPictureContentRect: Equatable {
    let originX: Int
    let originY: Int
    let width: Int
    let height: Int

    static func aspectFit(
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> Self {
        let safeSourceWidth = max(1, sourceWidth)
        let safeSourceHeight = max(1, sourceHeight)
        let safeTargetWidth = max(1, targetWidth)
        let safeTargetHeight = max(1, targetHeight)
        let sourceAspect = Double(safeSourceWidth) / Double(safeSourceHeight)
        let targetAspect = Double(safeTargetWidth) / Double(safeTargetHeight)

        let fittedWidth: Int
        let fittedHeight: Int
        if sourceAspect > targetAspect {
            fittedWidth = safeTargetWidth
            fittedHeight = max(1, Int((Double(safeTargetWidth) / sourceAspect).rounded()))
        } else {
            fittedWidth = max(1, Int((Double(safeTargetHeight) * sourceAspect).rounded()))
            fittedHeight = safeTargetHeight
        }

        return Self(
            originX: (safeTargetWidth - fittedWidth) / 2,
            originY: (safeTargetHeight - fittedHeight) / 2,
            width: fittedWidth,
            height: fittedHeight
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
    private let sourceWindow: () -> NSWindow?

    private var controller: AVPictureInPictureController?
    private var readbackBuffer: [UInt8] = []
    private var currentFormatDescription: CMVideoFormatDescription?
    private var currentDimensions: CMVideoDimensions = .init(width: 0, height: 0)
    private var captureEnabled = false
    private var startRequested = false
    private var lastFrameTime: CFTimeInterval = 0
    private var captureStartTime: CFTimeInterval?
    private var loggedFirstFrame = false
    private var loggedReadbackError = false
    private var controlTimebase: CMTimebase?
    private var pipContentFrameObserver: NSObjectProtocol?
    private var pipRenderSizeUpdateWorkItem: DispatchWorkItem?
    private var savedSourceWindowFrame: NSRect?
    private var savedSourceWindowAlpha: CGFloat?
    // macOS mirrors sample-buffer PIP content at its pixel dimensions. Keep
    // this aligned with AVKit's latest render-size callback.
    private var pipRenderSize = CMVideoDimensions(width: 320, height: 180)
    private(set) var isActive = false

    init(
        onPlayingChange: @escaping (Bool) -> Void,
        onSeekRelative: @escaping (Double) -> Void,
        currentPlaybackState: @escaping () -> (isPlaying: Bool, duration: Double),
        reportError: @escaping (String) -> Void,
        onActiveChange: @escaping (Bool) -> Void = { _ in },
        sourceWindow: @escaping () -> NSWindow? = { nil }
    ) {
        self.onPlayingChange = onPlayingChange
        self.onSeekRelative = onSeekRelative
        self.currentPlaybackState = currentPlaybackState
        self.reportError = reportError
        self.onActiveChange = onActiveChange
        self.sourceWindow = sourceWindow
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
            reportError(L10n.text("Picture in Picture is not supported on this Mac"))
            return
        }
        captureEnabled = true
        startRequested = true
        captureStartTime = nil
        lastFrameTime = 0
        loggedFirstFrame = false
        loggedReadbackError = false
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
        stopTrackingPIPContentSize()
        guard let controller, controller.isPictureInPictureActive else {
            restoreSourceWindow()
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
        height: Int32
    ) {
        guard captureEnabled, width > 0, height > 0 else { return }
        let now = CACurrentMediaTime()
        guard now - lastFrameTime >= (1.0 / 30.0) else { return }
        lastFrameTime = now
        // Preserve the complete rendered viewport. The output frame below
        // keeps the PiP target dimensions and centers this viewport inside it.
        let captureRegion = PictureInPictureCaptureRegion.resolve(
            viewportWidth: Int(width),
            viewportHeight: Int(height)
        )
        let pixelCount = Int(width) * Int(height) * 4
        if readbackBuffer.count != pixelCount {
            readbackBuffer = [UInt8](repeating: 0, count: pixelCount)
        }
        ensureController()
        nura_glBindFramebuffer(0x8D40, framebuffer)
        // mpv may leave GL_READ_BUFFER pointing at an attachment that is not
        // valid for the default framebuffer. Set it explicitly before reading
        // or glReadPixels can fail and leave an all-zero frame for AVKit.
        nura_glReadBuffer(framebuffer == 0 ? nuraGLBack : nuraGLColorAttachment0)
        while nura_glGetError() != nuraGLNoError {}
        readbackBuffer.withUnsafeMutableBytes { bytes in
            nura_glReadPixels(0, 0, width, height, nuraGLRGBA, nuraGLUnsignedByte, bytes.baseAddress)
        }
        let readbackError = nura_glGetError()
        if readbackError != nuraGLNoError {
            if !loggedReadbackError {
                loggedReadbackError = true
                logger.error("PiP framebuffer readback failed with OpenGL error \(readbackError)")
            }
            return
        }

        let outputSize = outputDimensions()

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
        let dimensionsChanged = currentDimensions.width != outputWidth || currentDimensions.height != outputHeight
        if dimensionsChanged {
            let layerSize = CGSize(width: outputSize.width, height: outputSize.height)
            displayLayer.frame = CGRect(origin: .zero, size: layerSize)
            displayLayer.bounds = CGRect(origin: .zero, size: layerSize)
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
        let contentRect = PictureInPictureContentRect.aspectFit(
            sourceWidth: cropWidth,
            sourceHeight: cropHeight,
            targetWidth: width,
            targetHeight: height
        )
        for row in 0..<height {
            let destinationOffset = row * destinationRowBytes
            let rowInContent = row >= contentRect.originY && row < contentRect.originY + contentRect.height
            let sourceOffset: Int
            if rowInContent {
                let contentRow = row - contentRect.originY
                let sourceCropRow = min(cropHeight - 1, (contentRow * cropHeight) / contentRect.height)
                let sourceRow = Int(sourceHeight) - cropTop - sourceCropRow - 1
                sourceOffset = sourceRow * sourceRowBytes + cropX * 4
            } else {
                sourceOffset = 0
            }
            for column in 0..<width {
                let target = destinationOffset + column * 4
                let columnInContent = column >= contentRect.originX && column < contentRect.originX + contentRect.width
                if rowInContent && columnInContent {
                    let sourceColumn = min(cropWidth - 1, ((column - contentRect.originX) * cropWidth) / contentRect.width)
                    let source = sourceOffset + sourceColumn * 4
                    destinationBytes[target] = readbackBuffer[source + 2]
                    destinationBytes[target + 1] = readbackBuffer[source + 1]
                    destinationBytes[target + 2] = readbackBuffer[source]
                } else {
                    destinationBytes[target] = 0
                    destinationBytes[target + 1] = 0
                    destinationBytes[target + 2] = 0
                }
                destinationBytes[target + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {}

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
        onActiveChange(true)
        invalidatePlaybackState()
        schedulePIPSourceWindowSynchronization()
        schedulePIPOverlaySuppression()
        schedulePIPContentSizeTracking()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        captureEnabled = false
        startRequested = false
        captureStartTime = nil
        loggedFirstFrame = false
        loggedReadbackError = false
        stopTrackingPIPContentSize()
        restoreSourceWindow()
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
        stopTrackingPIPContentSize()
        restoreSourceWindow()
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
        let renderSize = PictureInPictureRenderSize.validated(
            width: newRenderSize.width,
            height: newRenderSize.height
        )
        pipRenderSize = CMVideoDimensions(width: renderSize.width, height: renderSize.height)
        schedulePIPSourceWindowSynchronization()
        schedulePIPOverlaySuppression()
        schedulePIPContentSizeTracking()
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
        return (targetWidth, targetHeight)
    }

    private func schedulePIPSourceWindowSynchronization() {
        for delay in [0.1, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.synchronizeSourceWindowWithPIPContent()
            }
        }
    }

    private func schedulePIPOverlaySuppression() {
        for delay in [0.1, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.suppressPIPOverlayIfPresent()
            }
        }
    }

    private func schedulePIPContentSizeTracking() {
        for delay in [0.1, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.startTrackingPIPContentSize()
            }
        }
    }

    private func startTrackingPIPContentSize() {
        guard let contentView = pipContentView else { return }
        if pipContentFrameObserver == nil {
            contentView.postsFrameChangedNotifications = true
            pipContentFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.requestPIPResizeUpdate()
                }
            }
        }
        updatePIPRenderSize(from: contentView)
    }

    private func requestPIPResizeUpdate() {
        pipRenderSizeUpdateWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.updatePIPRenderSizeAndSourceWindow()
            self.suppressPIPOverlayIfPresent()
        }
        pipRenderSizeUpdateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func stopTrackingPIPContentSize() {
        pipRenderSizeUpdateWorkItem?.cancel()
        pipRenderSizeUpdateWorkItem = nil
        if let pipContentFrameObserver {
            NotificationCenter.default.removeObserver(pipContentFrameObserver)
            self.pipContentFrameObserver = nil
        }
    }

    private var pipContentView: NSView? {
        NSApplication.shared.windows.first(where: {
            String(describing: type(of: $0)).contains("PIPPanel")
        })?.contentView
    }

    private func updatePIPRenderSizeAndSourceWindow() {
        guard let contentView = pipContentView else { return }
        updatePIPRenderSize(from: contentView)
        synchronizeSourceWindow(with: contentView)
    }

    private func updatePIPRenderSize(from contentView: NSView) {
        let scale = contentView.window?.backingScaleFactor ?? 1
        guard let renderSize = PictureInPictureRenderSize.fromContentSize(
            contentView.bounds.size,
            scale: scale
        ) else { return }
        guard pipRenderSize.width != renderSize.width || pipRenderSize.height != renderSize.height else {
            return
        }
        pipRenderSize = CMVideoDimensions(width: renderSize.width, height: renderSize.height)
    }

    private func synchronizeSourceWindowWithPIPContent() {
        guard let contentView = pipContentView else { return }
        synchronizeSourceWindow(with: contentView)
    }

    private func synchronizeSourceWindow(with contentView: NSView) {
        guard let window = sourceWindow() else { return }
        let contentSize = contentView.bounds.size
        guard contentSize.width > 0, contentSize.height > 0 else { return }
        if savedSourceWindowFrame == nil {
            savedSourceWindowFrame = window.frame
            savedSourceWindowAlpha = window.alphaValue
        }

        let targetFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        var frame = window.frame
        frame.size = targetFrame.size
        frame.origin.y = window.frame.maxY - frame.height
        window.alphaValue = 0
        let minimumSize = window.minSize
        window.minSize = NSSize(width: 1, height: 1)
        window.setFrame(frame, display: false, animate: false)
        window.minSize = minimumSize
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func restoreSourceWindow() {
        guard let window = sourceWindow() else {
            savedSourceWindowFrame = nil
            savedSourceWindowAlpha = nil
            return
        }
        if let savedSourceWindowFrame {
            window.setFrame(savedSourceWindowFrame, display: true, animate: false)
        }
        if let savedSourceWindowAlpha {
            window.alphaValue = savedSourceWindowAlpha
        }
        self.savedSourceWindowFrame = nil
        savedSourceWindowAlpha = nil
    }

    private func suppressPIPOverlayIfPresent() {
        guard let pipWindow = NSApplication.shared.windows.first(where: {
            String(describing: type(of: $0)).contains("PIPPanel")
        }), let contentView = pipWindow.contentView else { return }
        suppressPIPOverlay(in: contentView)
    }

    private func suppressPIPOverlay(in view: NSView) {
        if String(describing: type(of: view)) == "AVPictureInPictureCALayerHostView" {
            view.isHidden = true
            return
        }
        for subview in view.subviews {
            suppressPIPOverlay(in: subview)
        }
    }

}

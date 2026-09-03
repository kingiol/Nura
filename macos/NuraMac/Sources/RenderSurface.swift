import AppKit

private typealias GLInt = Int32
private typealias GLSize = Int32
private typealias GLEnum = UInt32
private typealias GLBitfield = UInt32

@_silgen_name("glGetIntegerv") private func nura_glGetIntegerv(_ name: GLEnum, _ value: UnsafeMutablePointer<GLInt>)
@_silgen_name("glViewport") private func nura_glViewport(_ x: GLInt, _ y: GLInt, _ width: GLSize, _ height: GLSize)
@_silgen_name("glClearColor") private func nura_glClearColor(_ red: Float, _ green: Float, _ blue: Float, _ alpha: Float)
@_silgen_name("glClear") private func nura_glClear(_ mask: GLBitfield)

private let nuraGLDrawFramebufferBinding: GLEnum = 0x8CA6
private let nuraGLColorBufferBit: GLBitfield = 0x00004000

final class RenderSurface: NSOpenGLView {
    var attachRenderer: (() -> Void)?
    var renderFrame: ((Int32, Int32, Int32) -> Bool)?
    var captureFrame: ((Int32, Int32, Int32) -> Void)?
    private var redrawTimer: Timer?
    private var rendererAttached = false

    init() {
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAOpenGLProfile), NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersion3_2Core),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAColorSize), 24,
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAlphaSize), 8,
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADoubleBuffer),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAccelerated),
            0,
        ]
        super.init(frame: .zero, pixelFormat: NSOpenGLPixelFormat(attributes: attributes)!)!
        wantsBestResolutionOpenGLSurface = true
        openGLContext?.view = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        openGLContext?.makeCurrentContext()
        attachRendererIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        redrawTimer?.invalidate()
        redrawTimer = nil
        guard window != nil else { return }
        redrawTimer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(requestRedraw), userInfo: nil, repeats: true)
        RunLoop.main.add(redrawTimer!, forMode: .common)
    }

    @objc private func requestRedraw() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = openGLContext else { return }
        context.makeCurrentContext()
        attachRendererIfNeeded()
        var framebuffer: GLInt = 0
        nura_glGetIntegerv(nuraGLDrawFramebufferBinding, &framebuffer)
        let width = Int32(bounds.width * windowScale)
        let height = Int32(bounds.height * windowScale)
        nura_glViewport(0, 0, width, height)
        nura_glClearColor(0.035, 0.04, 0.05, 1.0)
        nura_glClear(nuraGLColorBufferBit)
        guard renderFrame?(Int32(framebuffer), width, height) == true else {
            return
        }
        captureFrame?(Int32(framebuffer), width, height)
        context.flushBuffer()
    }

    private var windowScale: CGFloat { window?.backingScaleFactor ?? 1.0 }

    private func attachRendererIfNeeded() {
        guard !rendererAttached, let attachRenderer else { return }
        rendererAttached = true
        attachRenderer()
    }

}

import SwiftUI

struct RenderSurfaceView: NSViewRepresentable {
    let model: PlayerViewModel

    func makeNSView(context: Context) -> RenderSurface {
        let surface = RenderSurface()
        surface.attachRenderer = { [weak model] in
            model?.attachOpenGLContext()
        }
        surface.renderFrame = { [weak model] fbo, width, height in
            model?.render(fbo: fbo, width: width, height: height) ?? false
        }
        surface.captureFrame = { [weak model] framebuffer, width, height in
            model?.capturePiPFrame(
                framebuffer: framebuffer,
                width: width,
                height: height
            )
        }
        return surface
    }

    func updateNSView(_ nsView: RenderSurface, context: Context) {}
}

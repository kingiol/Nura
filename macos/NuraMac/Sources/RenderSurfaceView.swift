import SwiftUI

struct RenderSurfaceView: NSViewRepresentable {
    @ObservedObject var model: PlayerViewModel

    func makeNSView(context: Context) -> RenderSurface {
        let surface = RenderSurface()
        surface.attachRenderer = { [weak model] in
            model?.attachOpenGLContext()
        }
        surface.renderFrame = { [weak model] fbo, width, height in
            model?.render(fbo: fbo, width: width, height: height) ?? false
        }
        return surface
    }

    func updateNSView(_ nsView: RenderSurface, context: Context) {}
}

import SwiftUI

struct RenderSurfaceView: NSViewRepresentable {
    let model: PlayerViewModel

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        context.coordinator.install(in: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.install(in: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    @MainActor
    final class Coordinator {
        let model: PlayerViewModel
        private(set) var surface: RenderSurface?

        init(model: PlayerViewModel) {
            self.model = model
        }

        func install(in container: NSView) {
            guard surface?.superview !== container else {
                surface?.frame = container.bounds
                return
            }
            if let surface {
                surface.removeFromSuperview()
            }
            let surface = renderSurface()
            surface.translatesAutoresizingMaskIntoConstraints = true
            surface.autoresizingMask = [.width, .height]
            surface.frame = container.bounds
            container.addSubview(surface)
        }

        func renderSurface() -> RenderSurface {
            if let surface {
                return surface
            }
            let surface = RenderSurface()
            surface.attachRenderer = { [weak model] in
                MainActor.assumeIsolated {
                    model?.attachOpenGLContext()
                }
            }
            surface.renderFrame = { [weak model] fbo, width, height in
                MainActor.assumeIsolated {
                    model?.render(fbo: fbo, width: width, height: height) ?? false
                }
            }
            surface.captureFrame = { [weak model] framebuffer, width, height in
                MainActor.assumeIsolated {
                    model?.capturePiPFrame(
                        framebuffer: framebuffer,
                        width: width,
                        height: height
                    )
                }
            }
            self.surface = surface
            return surface
        }
    }
}

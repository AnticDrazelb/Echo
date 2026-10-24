import CoreImage
import MetalKit
import SwiftUI

/// Thread-safe holder for the latest frame to display. Producers (editor,
/// camera, video) push images; the Metal view draws the newest one.
final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CIImage?
    fileprivate weak var view: MTKView?

    var current: CIImage? {
        lock.lock(); defer { lock.unlock() }
        return image
    }

    func push(_ newImage: CIImage?) {
        lock.lock()
        image = newImage
        lock.unlock()
        if Thread.isMainThread {
            view?.setNeedsDisplay()
        } else {
            DispatchQueue.main.async { [weak self] in self?.view?.setNeedsDisplay() }
        }
    }
}

/// GPU-backed image view: renders Core Image graphs straight into a Metal
/// drawable, so every slider tick is a fresh full-quality frame.
struct MetalImageView: UIViewRepresentable {
    enum Fill { case fit, fill }

    let store: FrameStore
    var fill: Fill = .fit

    func makeCoordinator() -> Coordinator { Coordinator(store: store, fill: fill) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: RenderEngine.shared.device)
        view.delegate = context.coordinator
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.autoResizeDrawable = true
        store.view = view
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.fill = fill
        if store.view !== view { store.view = view }
        view.setNeedsDisplay()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let store: FrameStore
        var fill: Fill

        init(store: FrameStore, fill: Fill) {
            self.store = store
            self.fill = fill
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.setNeedsDisplay()
        }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let queue = RenderEngine.shared.commandQueue,
                  let buffer = queue.makeCommandBuffer()
            else { return }
            let size = view.drawableSize
            guard size.width > 0, size.height > 0 else { return }
            let canvas = CGRect(origin: .zero, size: size)
            var output = CIImage(color: .clear).cropped(to: canvas)

            if let image = store.current, !image.extent.isEmpty, !image.extent.isInfinite {
                let ext = image.extent
                let sx = size.width / ext.width, sy = size.height / ext.height
                let scale = fill == .fit ? min(sx, sy) : max(sx, sy)
                let w = ext.width * scale, h = ext.height * scale
                let placed = image
                    .transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(translationX: (size.width - w) / 2, y: (size.height - h) / 2))
                output = placed.composited(over: output).cropped(to: canvas)
            }

            let destination = CIRenderDestination(
                width: Int(size.width),
                height: Int(size.height),
                pixelFormat: view.colorPixelFormat,
                commandBuffer: buffer,
                mtlTextureProvider: { drawable.texture }
            )
            destination.colorSpace = RenderEngine.sRGB
            _ = try? RenderEngine.shared.context.startTask(toRender: output, to: destination)
            buffer.present(drawable)
            buffer.commit()
        }
    }
}

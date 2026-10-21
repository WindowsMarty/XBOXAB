import SwiftUI
import MetalKit

/// Render at the native canvas resolution and precision before scaling for the window.
@MainActor
final class WallpaperMetalPreview {
    let renderer: ProjectMetalRenderer
    let texture: MTLTexture
    let presentationPipeline: MTLRenderPipelineState

    init(project: WallpaperProject) throws {
        renderer = try ProjectMetalRenderer(project: project, pixelFormat: .rgb10a2Unorm)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgb10a2Unorm, width: 1920, height: 1080, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = renderer.device.makeTexture(descriptor: descriptor) else {
            throw NSError(domain: "WallpaperMetalPreview", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建壁纸画布"])
        }
        self.texture = texture
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .precise
        let library = try renderer.device.makeLibrary(source: Self.presentationSource, options: options)
        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.vertexFunction = library.makeFunction(name: "presentationVertex")
        pipeline.fragmentFunction = library.makeFunction(name: "presentationFragment")
        pipeline.colorAttachments[0].pixelFormat = .bgr10a2Unorm
        presentationPipeline = try renderer.device.makeRenderPipelineState(descriptor: pipeline)
    }

    func draw(in view: MTKView, at time: Double) throws {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor else { return }
        try renderer.render(to: texture, at: time)
        guard let command = renderer.queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(presentationPipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(renderer.sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
        // The native host waits for its frame fence before reusing the canvas.
        command.waitUntilCompleted()
        if let error = command.error { throw error }
    }

    private static let presentationSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct Output { float4 position [[position]]; float2 uv; };
    vertex Output presentationVertex(uint id [[vertex_id]]) {
        const float2 positions[4] = {{-1,-1},{1,-1},{-1,1},{1,1}};
        const float2 coords[4] = {{0,1},{1,1},{0,0},{1,0}};
        return {float4(positions[id], 0, 1), coords[id]};
    }
    fragment float4 presentationFragment(Output in [[stage_in]],
        texture2d<float> image [[texture(0)]], sampler s [[sampler(0)]]) {
        return float4(image.sample(s, in.uv).rgb, 1);
    }
    """
}

struct WallpaperMetalView: NSViewRepresentable {
    let preview: WallpaperMetalPreview
    let onError: (Error) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(preview: preview, onError: onError) }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: preview.renderer.device)
        view.colorPixelFormat = .bgr10a2Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        view.isPaused = false
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.onError = onError
        if context.coordinator.preview !== preview {
            context.coordinator.preview = preview
            context.coordinator.epoch = DispatchTime.now().uptimeNanoseconds
            view.isPaused = false
        }
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        var preview: WallpaperMetalPreview
        var onError: (Error) -> Void
        var epoch = DispatchTime.now().uptimeNanoseconds

        init(preview: WallpaperMetalPreview, onError: @escaping (Error) -> Void) {
            self.preview = preview
            self.onError = onError
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            // Preserve the native shader's global clock across timeline cycles.
            let elapsed = DispatchTime.now().uptimeNanoseconds - epoch
            // Keep the clock precise until the renderer has applied its epoch.
            let time = Double(elapsed) / 1_000_000_000
            do {
                try preview.draw(in: view, at: time)
            } catch {
                view.isPaused = true
                onError(error)
            }
        }
    }
}

import Metal
import QuartzCore

private struct MetalEffect {
    var meta: SIMD4<Float>
    var f1: SIMD4<Float>
    var f2: SIMD4<Float>
    var f3: SIMD4<Float>
    var f4: SIMD4<Float>
    var f5: SIMD4<Float>
}

@MainActor
final class ProjectMetalRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    let textures: [MTLTexture]
    private let effects: [(track: Int, effect: MetalEffect)]
    let duration: Double
    private var slots = [MetalEffect](repeating: MetalEffect(meta: .zero, f1: .zero, f2: .zero, f3: .zero, f4: .zero, f5: .zero), count: 8)
    private var nextSegment = 0
    private var cycleStart: Float = 0
    private var nextCycleBoundary: Float = 0
    private var clockOrigin: Double = 0
    private var lastInputTime: Double = -1

    @MainActor init(project: WallpaperProject, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "ProjectMetalRenderer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "设备不支持 Metal"])
        }
        self.device = device
        self.queue = queue
        self.duration = Double(Float(project.config?.timelineLength ?? 15))
        guard duration.isFinite, duration > 0 else {
            throw NSError(domain: "ProjectMetalRenderer", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "时间轴长度必须大于零"])
        }

        var library: MTLLibrary? = device.makeDefaultLibrary()
        if library == nil, let metalURL = Bundle.main.url(forResource: "ImageEffectsShader", withExtension: "metal"),
           let sourceStr = try? String(contentsOf: metalURL, encoding: .utf8) {
            let options = MTLCompileOptions()
            options.mathMode = .safe
            options.mathFloatingPointFunctions = .precise
            library = try device.makeLibrary(source: sourceStr, options: options)
        }
        if library == nil {
            let options = MTLCompileOptions()
            options.mathMode = .safe
            options.mathFloatingPointFunctions = .precise
            library = try device.makeLibrary(source: Self.shaderSource, options: options)
        }
        guard let validLibrary = library else {
            throw NSError(domain: "ProjectMetalRenderer", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法加载 Metal 着色器库"])
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = validLibrary.makeFunction(name: "wallpaperVertex")
        descriptor.fragmentFunction = validLibrary.makeFunction(name: "wallpaperFragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw NSError(domain: "ProjectMetalRenderer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建纹理采样器"])
        }
        self.sampler = sampler

        let fallbackDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        fallbackDescriptor.usage = [.shaderRead]
        guard let fallback = device.makeTexture(descriptor: fallbackDescriptor) else {
            throw NSError(domain: "ProjectMetalRenderer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建备用纹理"])
        }
        var transparent: [UInt8] = [0, 0, 0, 0]
        fallback.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                         withBytes: &transparent, bytesPerRow: 4)
        guard let folder = project.folderURL else {
            throw NSError(domain: "ProjectMetalRenderer", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "壁纸工程没有资源目录"])
        }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let imageEffects = project.segments.filter { $0.isVisible && [1, 4, 5, 6, 7].contains($0.effectType) }
        // The native JSON reader stores these parameters as float32 before the
        // CPU loader and GPU both convert their indices to integers.
        let subIndices = Set(imageEffects.compactMap { Int(exactly: Float($0.floats2_2).rounded(.towardZero)) })
        let maskIndices = Set(imageEffects.filter { $0.effectType == 7 }
            .compactMap { Int(exactly: Float($0.floats2_3).rounded(.towardZero)) })
        var loaded = [MTLTexture](repeating: fallback, count: 13)
        loaded[0] = try OriginalPNGTextureLoader.load(
            url: folder.appendingPathComponent("DynamicBg.png"), device: device)
        for i in 0..<8 where subIndices.contains(i) {
            loaded[i + 1] = try OriginalPNGTextureLoader.load(
                url: folder.appendingPathComponent("DynamicSubImg\(i + 1).png"), device: device)
        }
        for i in 0..<3 where maskIndices.contains(i) {
            loaded[i + 9] = try OriginalPNGTextureLoader.load(
                url: folder.appendingPathComponent("AlphaMask\(i + 1).png"), device: device)
        }
        if project.segments.contains(where: { $0.isVisible && $0.effectType == 3 }) {
            guard let normalURL = Bundle.main.url(forResource: "waterripplenormal", withExtension: "png") else {
                throw NSError(domain: "ProjectMetalRenderer", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "应用缺少原版水波法线纹理"])
            }
            loaded[12] = try OriginalPNGTextureLoader.load(url: normalURL, device: device, ignoreSRGB: false)
        }
        self.textures = loaded
        self.nextCycleBoundary = Float(duration)
        self.effects = project.segments.enumerated()
            .filter { $0.element.isVisible && (0..<8).contains($0.element.trackIndex) }
            .sorted {
                // The binary was already sorted by the native editor. Its exact
                // ordering (including equal start times) is authoritative.
                if project.usesBinaryConfig { return $0.offset < $1.offset }
                if $0.element.startTime == $1.element.startTime { return $0.offset < $1.offset }
                return $0.element.startTime < $1.element.startTime
            }
            .map { _, segment in
                var effect = MetalEffect(
                    meta: SIMD4(Float(bitPattern: UInt32(truncatingIfNeeded: segment.effectType)), Float(segment.startTime),
                                Float(segment.duration), Float(segment.effectData1)),
                    f1: SIMD4(Float(segment.floats1_0), Float(segment.floats1_1), Float(segment.floats1_2), Float(segment.floats1_3)),
                    f2: SIMD4(Float(segment.floats2_0), Float(segment.floats2_1), Float(segment.floats2_2), Float(segment.floats2_3)),
                    f3: SIMD4(Float(segment.floats3_0), Float(segment.floats3_1), Float(segment.floats3_2), Float(segment.floats3_3)),
                    f4: SIMD4(Float(segment.floats4_0), Float(segment.floats4_1), Float(segment.floats4_2), Float(segment.floats4_3)),
                    f5: SIMD4(Float(segment.floats5_0), Float(segment.floats5_1), Float(segment.floats5_2), Float(segment.floats5_3))
                )
                // Native loader only replaces scale when BOTH endpoints are zero.
                if [1, 4, 5, 6, 7].contains(segment.effectType), effect.f5.x == 0, effect.f5.y == 0 {
                    effect.f5.x = 1
                    effect.f5.y = 1
                }
                return (track: segment.trackIndex, effect: effect)
            }
    }

    func render(to target: MTLTexture, at time: Double, present drawable: CAMetalDrawable? = nil,
                waitUntilCompleted: Bool = false) throws {
        guard let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        for (index, texture) in textures.enumerated() {
            encoder.setFragmentTexture(texture, index: index)
        }
        let constants = frameConstants(at: time)
        constants.withUnsafeBytes { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        if let drawable { buffer.present(drawable) }
        buffer.commit()
        if waitUntilCompleted {
            buffer.waitUntilCompleted()
            if let error = buffer.error { throw error }
        }
    }

    func frameConstants(at time: Double) -> [SIMD4<Float>] {
        let inputTime = time
        // Offline callers may seek backwards. Live playback always moves forward.
        if inputTime < lastInputTime {
            slots = [MetalEffect](repeating: MetalEffect(meta: .zero, f1: .zero, f2: .zero, f3: .zero, f4: .zero, f5: .zero), count: 8)
            nextSegment = 0
            cycleStart = 0
            nextCycleBoundary = Float(duration)
            clockOrigin = 0
        }
        lastInputTime = inputTime
        // Rebase in high precision before float32 quantization. Native rollover
        // takes a new QPC epoch, restoring precision for small elapsed intervals.
        var shaderTime = Float(inputTime - clockOrigin)
        if !effects.isEmpty, shaderTime > nextCycleBoundary {
            if shaderTime > 86400 {
                // The native day-long QPC rollover keeps the existing GPU slots.
                clockOrigin = inputTime
                shaderTime = 0
                cycleStart = 0
            } else {
                cycleStart = (shaderTime / Float(duration)).rounded(.towardZero) * Float(duration)
            }
            nextSegment = 0
            nextCycleBoundary = cycleStart + Float(duration)
        }
        // Match the native cursor, strict start comparison and retained slots.
        // A dropped frame must not invent segments in a skipped previous cycle.
        while nextSegment < effects.count {
            let entry = effects[nextSegment]
            var effect = entry.effect
            effect.meta.y += cycleStart
            guard shaderTime > effect.meta.y else { break }
            slots[entry.track] = effect
            nextSegment += 1
        }
        var constants = [SIMD4<Float>(shaderTime, 0, 0, 0)]
        for slot in slots {
            constants.append(contentsOf: [slot.meta, slot.f1, slot.f2, slot.f3, slot.f4, slot.f5])
        }
        return constants
    }

    private static let shaderSource = """
    // Generated by reverse-engineering/tools/translate_shader.py. Do not edit by hand.
    // Shipped DXBC SHA-256: 951fae31164c8b5cff4ae202a9e9d29937744e3360d5f42c271b783770b3368b
    // All branch constants and float literals come from the binary, not rounded disassembly.
    #include <metal_stdlib>
    using namespace metal;
    // SM4/5 conversion instructions clamp and map NaN to zero; a C++ vector cast
    // alone does not define overflow/NaN conversion. Clamp before the cast as well.
    inline int4 dx_ftoi(float4 value) {
        float4 clean = select(value, float4(0), isnan(value));
        int4 converted = int4(clamp(clean, float4(-2147483648.0f), float4(2147483520.0f)));
        return select(converted, int4(2147483647), clean >= 2147483648.0f);
    }
    inline uint4 dx_ftou(float4 value) {
        float4 clean = select(value, float4(0), isnan(value));
        uint4 converted = uint4(clamp(clean, float4(0), float4(4294967040.0f)));
        return select(converted, uint4(0xffffffffu), clean >= 4294967296.0f);
    }
    inline float4 dx_saturate(float4 value) {
        return select(saturate(value), float4(0), isnan(value));
    }
    struct VertexOutput { float4 position [[position]]; float2 uv; };
    vertex VertexOutput wallpaperVertex(uint id [[vertex_id]]) {
        const float2 positions[4] = {{-1,-1},{1,-1},{-1,1},{1,1}};
        const float2 coords[4] = {{0,1},{1,1},{0,0},{1,0}};
        return {float4(positions[id], 0, 1), coords[id]};
    }
    fragment float4 wallpaperFragment(VertexOutput in [[stage_in]],
        constant uint4 *cb [[buffer(0)]],
        sampler s [[sampler(0)]],
        texture2d<float> t0 [[texture(0)]],
        texture2d<float> t1 [[texture(1)]],
        texture2d<float> t2 [[texture(2)]],
        texture2d<float> t3 [[texture(3)]],
        texture2d<float> t4 [[texture(4)]],
        texture2d<float> t5 [[texture(5)]],
        texture2d<float> t6 [[texture(6)]],
        texture2d<float> t7 [[texture(7)]],
        texture2d<float> t8 [[texture(8)]],
        texture2d<float> t9 [[texture(9)]],
        texture2d<float> t10 [[texture(10)]],
        texture2d<float> t11 [[texture(11)]],
        texture2d<float> t12 [[texture(12)]]
    ) {
        uint4 v0 = as_type<uint4>(float4(in.position.xy, 0, 1));
        uint4 o0 = uint4(0);
        uint4 r0 = uint4(0);
        uint4 r1 = uint4(0);
        uint4 r2 = uint4(0);
        uint4 r3 = uint4(0);
        uint4 r4 = uint4(0);
        uint4 r5 = uint4(0);
        uint4 r6 = uint4(0);
        uint4 r7 = uint4(0);
        uint4 r8 = uint4(0);
        uint4 r9 = uint4(0);
        uint4 r10 = uint4(0);
        uint4 r11 = uint4(0);
        uint4 r12 = uint4(0);
        uint4 r13 = uint4(0);
        uint4 r14 = uint4(0);
        // DXBC token 71: mul r0.xy, v0.xy, l(0.000521, 0.000926, 0.000000, 0.000000)
        r0.xy = (as_type<uint4>((as_type<float4>((v0).xyxx) * as_type<float4>((uint4(0x3a088889u, 0x3a72b9d6u, 0x00000000u, 0x00000000u)).xyzw)))).xy;
        // DXBC token 81: sample_indexable(texture2d)(float,float,float,float) r1.xyzw, r0.xyx, t0.xyzw, s0
        r1.xyzw = (as_type<uint4>(t0.sample(s, (as_type<float4>((r0).xyxx)).xy).xyzw)).xyzw;
        // DXBC token 92: mul r0.z, cb0[0].x, l(6.283180)
        r0.z = (as_type<uint4>((as_type<float4>((cb[0]).xxxx) * as_type<float4>((uint4(0x40c90fd0u)).xxxx)))).z;
        // DXBC token 100: mov r2.yz, l(0.000000, 0.000000, 0.000000, 0.000000)
        r2.yz = ((uint4(0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u)).xyzw).yz;
        // DXBC token 108: mov r3.w, l(1.000000)
        r3.w = ((uint4(0x3f800000u)).xxxx).w;
        // DXBC token 113: mov r4.yz, l(0.000000, 0.000000, 0.000000, 0.000000)
        r4.yz = ((uint4(0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u)).xyzw).yz;
        // DXBC token 121: mov r5.yz, l(0.000000, 0.000000, 0.000000, 0.000000)
        r5.yz = ((uint4(0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u)).xyzw).yz;
        // DXBC token 129: mov r6.xyzw, r1.xyzw
        r6.xyzw = ((r1).xyzw).xyzw;
        // DXBC token 134: mov r0.w, l(0.000000)
        r0.w = ((uint4(0x00000000u)).xxxx).w;
        // DXBC token 139: loop
        while (true) {
        // DXBC token 140: ige r7.x, r0.w, l(8)
        r7.x = (select(uint4(0), uint4(0xffffffffu), as_type<int4>((r0).wwww) >= as_type<int4>((uint4(0x00000008u)).xxxx))).x;
        // DXBC token 147: breakc_nz r7.x
        if (((r7).xxxx).x != 0u) break;
        // DXBC token 150: imul null, r7.x, r0.w, l(6)
        r7.x = (((r0).wwww * (uint4(0x00000006u)).xxxx)).x;
        // DXBC token 158: if_nz cb0[r7.x + 1].x
        if (((cb[1 + ((r7).xxxx).x]).xxxx).x != 0u) {
        // DXBC token 164: ieq r8.xyzw, l(1, 4, 5, 6), cb0[r7.x + 1].x
        r8.xyzw = (select(uint4(0), uint4(0xffffffffu), as_type<int4>((uint4(0x00000001u, 0x00000004u, 0x00000005u, 0x00000006u)).xyzw) == as_type<int4>((cb[1 + ((r7).xxxx).x]).xxxx))).xyzw;
        // DXBC token 177: or r7.y, r8.y, r8.x
        r7.y = (((r8).yyyy | (r8).xxxx)).y;
        // DXBC token 184: or r7.y, r8.z, r7.y
        r7.y = (((r8).zzzz | (r7).yyyy)).y;
        // DXBC token 191: or r7.y, r8.w, r7.y
        r7.y = (((r8).wwww | (r7).yyyy)).y;
        // DXBC token 198: ieq r7.z, l(7), cb0[r7.x + 1].x
        r7.z = (select(uint4(0), uint4(0xffffffffu), as_type<int4>((uint4(0x00000007u)).xxxx) == as_type<int4>((cb[1 + ((r7).xxxx).x]).xxxx))).z;
        // DXBC token 208: or r7.y, r7.z, r7.y
        r7.y = (((r7).zzzz | (r7).yyyy)).y;
        // DXBC token 215: if_nz r7.y
        if (((r7).yyyy).x != 0u) {
        // DXBC token 218: add r7.y, cb0[0].x, -cb0[r7.x + 1].y
        r7.y = (as_type<uint4>((as_type<float4>((cb[0]).xxxx) + -(as_type<float4>((cb[1 + ((r7).xxxx).x]).yyyy))))).y;
        // DXBC token 230: div r7.w, r7.y, cb0[r7.x + 1].z
        r7.w = (as_type<uint4>((as_type<float4>((r7).yyyy) / as_type<float4>((cb[1 + ((r7).xxxx).x]).zzzz)))).w;
        // DXBC token 240: lt r8.x, l(1.000000), r7.w
        r8.x = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x3f800000u)).xxxx) < as_type<float4>((r7).wwww))).x;
        // DXBC token 247: if_z r8.x
        if (((r8).xxxx).x == 0u) {
        // DXBC token 250: eq r9.xyzw, l(0.000000, 1.000000, 3.000000, 4.000000), cb0[r7.x + 1].w
        r9.xyzw = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x00000000u, 0x3f800000u, 0x40400000u, 0x40800000u)).xyzw) == as_type<float4>((cb[1 + ((r7).xxxx).x]).wwww))).xyzw;
        // DXBC token 263: mov_sat r8.z, r7.w
        r8.z = (as_type<uint4>(dx_saturate(as_type<float4>((r7).wwww)))).z;
        // DXBC token 268: mad r10.x, r8.z, l(-2.000000), l(3.000000)
        r10.x = (as_type<uint4>((as_type<float4>((r8).zzzz) * as_type<float4>((uint4(0xc0000000u)).xxxx) + as_type<float4>((uint4(0x40400000u)).xxxx)))).x;
        // DXBC token 277: mul r8.z, r8.z, r8.z
        r8.z = (as_type<uint4>((as_type<float4>((r8).zzzz) * as_type<float4>((r8).zzzz)))).z;
        // DXBC token 284: mul r8.z, r8.z, r10.x
        r8.z = (as_type<uint4>((as_type<float4>((r8).zzzz) * as_type<float4>((r10).xxxx)))).z;
        // DXBC token 291: add r10.x, -r7.w, l(1.000000)
        r10.x = (as_type<uint4>((-(as_type<float4>((r7).wwww)) + as_type<float4>((uint4(0x3f800000u)).xxxx)))).x;
        // DXBC token 299: mul r10.y, r10.x, r10.x
        r10.y = (as_type<uint4>((as_type<float4>((r10).xxxx) * as_type<float4>((r10).xxxx)))).y;
        // DXBC token 306: mad r10.x, -r10.x, r10.y, l(1.000000)
        r10.x = (as_type<uint4>((-(as_type<float4>((r10).xxxx)) * as_type<float4>((r10).yyyy) + as_type<float4>((uint4(0x3f800000u)).xxxx)))).x;
        // DXBC token 316: mul r10.y, r7.w, r7.w
        r10.y = (as_type<uint4>((as_type<float4>((r7).wwww) * as_type<float4>((r7).wwww)))).y;
        // DXBC token 323: mul r10.y, r7.w, r10.y
        r10.y = (as_type<uint4>((as_type<float4>((r7).wwww) * as_type<float4>((r10).yyyy)))).y;
        // DXBC token 330: movc r10.x, r9.z, r10.x, r10.y
        r10.x = (select((r10).yyyy, (r10).xxxx, (r9).zzzz != uint4(0))).x;
        // DXBC token 339: or r9.xy, r9.yw, r9.xz
        r9.xy = (((r9).ywyy | (r9).xzxx)).xy;
        // DXBC token 346: movc r8.z, r9.x, r8.z, r10.x
        r8.z = (select((r10).xxxx, (r8).zzzz, (r9).xxxx != uint4(0))).z;
        // DXBC token 355: or r9.x, r9.y, r9.x
        r9.x = (((r9).yyyy | (r9).xxxx)).x;
        // DXBC token 362: movc r8.z, r9.x, r8.z, r7.w
        r8.z = (select((r7).wwww, (r8).zzzz, (r9).xxxx != uint4(0))).z;
        // DXBC token 371: add r9.x, -r8.z, l(1.000000)
        r9.x = (as_type<uint4>((-(as_type<float4>((r8).zzzz)) + as_type<float4>((uint4(0x3f800000u)).xxxx)))).x;
        // DXBC token 379: mul r9.x, r9.x, r9.x
        r9.x = (as_type<uint4>((as_type<float4>((r9).xxxx) * as_type<float4>((r9).xxxx)))).x;
        // DXBC token 386: add r10.xyzw, cb0[r7.x + 2].xyzw, -cb0[r7.x + 4].xyxy
        r10.xyzw = (as_type<uint4>((as_type<float4>((cb[2 + ((r7).xxxx).x]).xyzw) + -(as_type<float4>((cb[4 + ((r7).xxxx).x]).xyxy))))).xyzw;
        // DXBC token 400: mad r9.xy, r9.x, r10.xy, cb0[r7.x + 4].xy
        r9.xy = (as_type<uint4>((as_type<float4>((r9).xxxx) * as_type<float4>((r10).xyxx) + as_type<float4>((cb[4 + ((r7).xxxx).x]).xyxx)))).xy;
        // DXBC token 412: mul r9.z, r8.z, r8.z
        r9.z = (as_type<uint4>((as_type<float4>((r8).zzzz) * as_type<float4>((r8).zzzz)))).z;
        // DXBC token 419: mad r9.xy, r9.z, r10.zw, r9.xy
        r9.xy = (as_type<uint4>((as_type<float4>((r9).zzzz) * as_type<float4>((r10).zwzz) + as_type<float4>((r9).xyxx)))).xy;
        // DXBC token 428: ne r9.z, l(1.000000), cb0[r7.x + 1].w
        r9.z = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x3f800000u)).xxxx) != as_type<float4>((cb[1 + ((r7).xxxx).x]).wwww))).z;
        // DXBC token 438: add r10.xy, -cb0[r7.x + 2].xy, cb0[r7.x + 2].zw
        r10.xy = (as_type<uint4>((-(as_type<float4>((cb[2 + ((r7).xxxx).x]).xyxx)) + as_type<float4>((cb[2 + ((r7).xxxx).x]).zwzz)))).xy;
        // DXBC token 452: mad r10.xy, r8.z, r10.xy, cb0[r7.x + 2].xy
        r10.xy = (as_type<uint4>((as_type<float4>((r8).zzzz) * as_type<float4>((r10).xyxx) + as_type<float4>((cb[2 + ((r7).xxxx).x]).xyxx)))).xy;
        // DXBC token 464: movc r9.zw, r9.z, r10.xxxy, r9.xxxy
        r9.zw = (select((r9).xxxy, (r10).xxxy, (r9).zzzz != uint4(0))).zw;
        // DXBC token 473: ne r10.xy, l(1.000000, 1.000000, 0.000000, 0.000000), cb0[r7.x + 6].xy
        r10.xy = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x3f800000u, 0x3f800000u, 0x00000000u, 0x00000000u)).xyzw) != as_type<float4>((cb[6 + ((r7).xxxx).x]).xyxx))).xy;
        // DXBC token 486: or r10.x, r10.y, r10.x
        r10.x = (((r10).yyyy | (r10).xxxx)).x;
        // DXBC token 493: if_nz r10.x
        if (((r10).xxxx).x != 0u) {
        // DXBC token 496: add r10.x, -cb0[r7.x + 6].x, cb0[r7.x + 6].y
        r10.x = (as_type<uint4>((-(as_type<float4>((cb[6 + ((r7).xxxx).x]).xxxx)) + as_type<float4>((cb[6 + ((r7).xxxx).x]).yyyy)))).x;
        // DXBC token 510: mad r10.x, r8.z, r10.x, cb0[r7.x + 6].x
        r10.x = (as_type<uint4>((as_type<float4>((r8).zzzz) * as_type<float4>((r10).xxxx) + as_type<float4>((cb[6 + ((r7).xxxx).x]).xxxx)))).x;
        // DXBC token 522: add r10.y, -r10.x, l(1.000000)
        r10.y = (as_type<uint4>((-(as_type<float4>((r10).xxxx)) + as_type<float4>((uint4(0x3f800000u)).xxxx)))).y;
        // DXBC token 530: mul r10.y, r10.y, l(0.500000)
        r10.y = (as_type<uint4>((as_type<float4>((r10).yyyy) * as_type<float4>((uint4(0x3f000000u)).xxxx)))).y;
        // DXBC token 537: mad r9.zw, r10.y, cb0[r7.x + 3].xxxy, r9.zzzw
        r9.zw = (as_type<uint4>((as_type<float4>((r10).yyyy) * as_type<float4>((cb[3 + ((r7).xxxx).x]).xxxy) + as_type<float4>((r9).zzzw)))).zw;
        // DXBC token 549: mul r9.xy, r10.x, cb0[r7.x + 3].xy
        r9.xy = (as_type<uint4>((as_type<float4>((r10).xxxx) * as_type<float4>((cb[3 + ((r7).xxxx).x]).xyxx)))).xy;
        // DXBC token 559: else
        } else {
        // DXBC token 560: mov r9.xy, cb0[r7.x + 3].xy
        r9.xy = ((cb[3 + ((r7).xxxx).x]).xyxx).xy;
        // DXBC token 568: endif
        }
        // DXBC token 569: ine r10.x, l(5), cb0[r7.x + 1].x
        r10.x = (select(uint4(0), uint4(0xffffffffu), as_type<int4>((uint4(0x00000005u)).xxxx) != as_type<int4>((cb[1 + ((r7).xxxx).x]).xxxx))).x;
        // DXBC token 579: if_nz r10.x
        if (((r10).xxxx).x != 0u) {
        // DXBC token 582: ne r10.xy, l(0.000000, 0.000000, 0.000000, 0.000000), cb0[r7.x + 6].zw
        r10.xy = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u)).xyzw) != as_type<float4>((cb[6 + ((r7).xxxx).x]).zwzz))).xy;
        // DXBC token 595: or r10.x, r10.y, r10.x
        r10.x = (((r10).yyyy | (r10).xxxx)).x;
        // DXBC token 602: if_nz r10.x
        if (((r10).xxxx).x != 0u) {
        // DXBC token 605: add r10.x, -cb0[r7.x + 6].z, cb0[r7.x + 6].w
        r10.x = (as_type<uint4>((-(as_type<float4>((cb[6 + ((r7).xxxx).x]).zzzz)) + as_type<float4>((cb[6 + ((r7).xxxx).x]).wwww)))).x;
        // DXBC token 619: mad r8.z, r8.z, r10.x, cb0[r7.x + 6].z
        r8.z = (as_type<uint4>((as_type<float4>((r8).zzzz) * as_type<float4>((r10).xxxx) + as_type<float4>((cb[6 + ((r7).xxxx).x]).zzzz)))).z;
        // DXBC token 631: mad r10.xy, -r9.xy, l(0.500000, 0.500000, 0.000000, 0.000000), v0.xy
        r10.xy = (as_type<uint4>((-(as_type<float4>((r9).xyxx)) * as_type<float4>((uint4(0x3f000000u, 0x3f000000u, 0x00000000u, 0x00000000u)).xyzw) + as_type<float4>((v0).xyxx)))).xy;
        // DXBC token 644: add r10.xy, -r9.zw, r10.xy
        r10.xy = (as_type<uint4>((-(as_type<float4>((r9).zwzz)) + as_type<float4>((r10).xyxx)))).xy;
        // DXBC token 652: sincos r11.x, r12.x, r8.z
        { float4 angle = as_type<float4>((r8).zzzz);
        r11.x = (as_type<uint4>(sin(angle))).x;
        r12.x = (as_type<uint4>(cos(angle))).x;
        }
        // DXBC token 659: mov r13.x, -r11.x
        r13.x = (as_type<uint4>(-(as_type<float4>((r11).xxxx)))).x;
        // DXBC token 665: mov r13.y, r12.x
        r13.y = ((r12).xxxx).y;
        // DXBC token 670: dp2 r12.x, r13.yx, r10.xy
        r12.x = (as_type<uint4>(float4(dot((as_type<float4>((r13).yxyy)).xy, (as_type<float4>((r10).xyxx)).xy)))).x;
        // DXBC token 677: mov r13.z, r11.x
        r13.z = ((r11).xxxx).z;
        // DXBC token 682: dp2 r12.y, r13.zy, r10.xy
        r12.y = (as_type<uint4>(float4(dot((as_type<float4>((r13).zyzz)).xy, (as_type<float4>((r10).xyxx)).xy)))).y;
        // DXBC token 689: mad r10.xy, r9.xy, l(0.500000, 0.500000, 0.000000, 0.000000), r12.xy
        r10.xy = (as_type<uint4>((as_type<float4>((r9).xyxx) * as_type<float4>((uint4(0x3f000000u, 0x3f000000u, 0x00000000u, 0x00000000u)).xyzw) + as_type<float4>((r12).xyxx)))).xy;
        // DXBC token 701: add r10.xy, r9.zw, r10.xy
        r10.xy = (as_type<uint4>((as_type<float4>((r9).zwzz) + as_type<float4>((r10).xyxx)))).xy;
        // DXBC token 708: else
        } else {
        // DXBC token 709: mov r10.xy, v0.xy
        r10.xy = ((v0).xyxx).xy;
        // DXBC token 714: endif
        }
        // DXBC token 715: else
        } else {
        // DXBC token 716: ge r8.z, l(2.000000), cb0[r7.x + 4].z
        r8.z = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x40000000u)).xxxx) >= as_type<float4>((cb[4 + ((r7).xxxx).x]).zzzz))).z;
        // DXBC token 726: if_nz r8.z
        if (((r8).zzzz).x != 0u) {
        // DXBC token 729: eq r11.xyzw, l(0.000000, 3.000000, 0.000000, 2.000000), cb0[r7.x + 4].zzw
        r11.xyzw = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x00000000u, 0x40400000u, 0x00000000u, 0x40000000u)).xyzw) == as_type<float4>((cb[4 + ((r7).xxxx).x]).zzww))).xyzw;
        // DXBC token 742: or r10.zw, r11.yyyw, r11.xxxz
        r10.zw = (((r11).yyyw | (r11).xxxz)).zw;
        // DXBC token 749: eq r11.xy, l(1.000000, 4.000000, 0.000000, 0.000000), cb0[r7.x + 4].z
        r11.xy = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x3f800000u, 0x40800000u, 0x00000000u, 0x00000000u)).xyzw) == as_type<float4>((cb[4 + ((r7).xxxx).x]).zzzz))).xy;
        // DXBC token 762: or r8.z, r11.y, r11.x
        r8.z = (((r11).yyyy | (r11).xxxx)).z;
        // DXBC token 769: movc r11.xy, r10.w, l(0.500000, -0.500000, 0.000000, 0.000000), l(-0.500000, 0.500000, 0.000000, 0.000000)
        r11.xy = (select((uint4(0xbf000000u, 0x3f000000u, 0x00000000u, 0x00000000u)).xyzw, (uint4(0x3f000000u, 0xbf000000u, 0x00000000u, 0x00000000u)).xyzw, (r10).wwww != uint4(0))).xy;
        // DXBC token 784: and r8.z, r8.z, r11.y
        r8.z = (((r8).zzzz & (r11).yyyy)).z;
        // DXBC token 791: movc r8.z, r10.z, r11.x, r8.z
        r8.z = (select((r8).zzzz, (r11).xxxx, (r10).zzzz != uint4(0))).z;
        // DXBC token 800: add r10.z, cb0[0].x, cb0[r7.x + 3].w
        r10.z = (as_type<uint4>((as_type<float4>((cb[0]).xxxx) + as_type<float4>((cb[3 + ((r7).xxxx).x]).wwww)))).z;
        // DXBC token 811: mul r10.z, r10.z, cb0[r7.x + 6].z
        r10.z = (as_type<uint4>((as_type<float4>((r10).zzzz) * as_type<float4>((cb[6 + ((r7).xxxx).x]).zzzz)))).z;
        // DXBC token 821: sincos r10.z, null, r10.z
        { float4 angle = as_type<float4>((r10).zzzz);
        r10.z = (as_type<uint4>(sin(angle))).z;
        }
        // DXBC token 827: mad r8.z, r10.z, l(0.500000), r8.z
        r8.z = (as_type<uint4>((as_type<float4>((r10).zzzz) * as_type<float4>((uint4(0x3f000000u)).xxxx) + as_type<float4>((r8).zzzz)))).z;
        // DXBC token 836: ftou r10.z, cb0[r7.x + 4].w
        r10.z = (dx_ftou(as_type<float4>((cb[4 + ((r7).xxxx).x]).wwww))).z;
        // DXBC token 844: switch r10.z
        switch (((r10).zzzz).x) {
        // DXBC token 847: case l(0.000000)
        case 0u:
        // DXBC token 850: add r10.z, r9.y, r9.w
        r10.z = (as_type<uint4>((as_type<float4>((r9).yyyy) + as_type<float4>((r9).wwww)))).z;
        // DXBC token 857: add r10.z, r10.z, -v0.y
        r10.z = (as_type<uint4>((as_type<float4>((r10).zzzz) + -(as_type<float4>((v0).yyyy))))).z;
        // DXBC token 865: div r10.z, r10.z, r9.y
        r10.z = (as_type<uint4>((as_type<float4>((r10).zzzz) / as_type<float4>((r9).yyyy)))).z;
        // DXBC token 872: mul r10.z, r10.z, r10.z
        r10.z = (as_type<uint4>((as_type<float4>((r10).zzzz) * as_type<float4>((r10).zzzz)))).z;
        // DXBC token 879: mul r10.z, r8.z, r10.z
        r10.z = (as_type<uint4>((as_type<float4>((r8).zzzz) * as_type<float4>((r10).zzzz)))).z;
        // DXBC token 886: mul r10.w, r10.z, cb0[r7.x + 5].w
        r10.w = (as_type<uint4>((as_type<float4>((r10).zzzz) * as_type<float4>((cb[5 + ((r7).xxxx).x]).wwww)))).w;
        // DXBC token 896: mad r10.x, -r10.w, l(120.000000), v0.x
        r10.x = (as_type<uint4>((-(as_type<float4>((r10).wwww)) * as_type<float4>((uint4(0x42f00000u)).xxxx) + as_type<float4>((v0).xxxx)))).x;
        // DXBC token 906: lt r10.w, l(0.000000), r8.z
        r10.w = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x00000000u)).xxxx) < as_type<float4>((r8).zzzz))).w;
        // DXBC token 913: mul r11.xy, r10.z, l(60.000000, -60.000000, 0.000000, 0.000000)
        r11.xy = (as_type<uint4>((as_type<float4>((r10).zzzz) * as_type<float4>((uint4(0x42700000u, 0xc2700000u, 0x00000000u, 0x00000000u)).xyzw)))).xy;
        // DXBC token 923: mul r11.xy, r11.xy, cb0[r7.x + 5].z
        r11.xy = (as_type<uint4>((as_type<float4>((r11).xyxx) * as_type<float4>((cb[5 + ((r7).xxxx).x]).zzzz)))).xy;
        // DXBC token 933: movc r10.z, r10.w, r11.x, r11.y
        r10.z = (select((r11).yyyy, (r11).xxxx, (r10).wwww != uint4(0))).z;
        // DXBC token 942: add r10.y, -r10.z, v0.y
        r10.y = (as_type<uint4>((-(as_type<float4>((r10).zzzz)) + as_type<float4>((v0).yyyy)))).y;
        // DXBC token 950: break
        break;
        // DXBC token 951: case l(0.000000)
        case 1u:
        // DXBC token 954: add r10.z, -r9.w, v0.y
        r10.z = (as_type<uint4>((-(as_type<float4>((r9).wwww)) + as_type<float4>((v0).yyyy)))).z;
        // DXBC token 962: div r10.z, r10.z, r9.y
        r10.z = (as_type<uint4>((as_type<float4>((r10).zzzz) / as_type<float4>((r9).yyyy)))).z;
        // DXBC token 969: mul r10.z, r10.z, r10.z
        r10.z = (as_type<uint4>((as_type<float4>((r10).zzzz) * as_type<float4>((r10).zzzz)))).z;
        // DXBC token 976: mul r10.z, r8.z, r10.z
        r10.z = (as_type<uint4>((as_type<float4>((r8).zzzz) * as_type<float4>((r10).zzzz)))).z;
        // DXBC token 983: mul r10.w, r10.z, cb0[r7.x + 5].w
        r10.w = (as_type<uint4>((as_type<float4>((r10).zzzz) * as_type<float4>((cb[5 + ((r7).xxxx).x]).wwww)))).w;
        // DXBC token 993: mad r10.x, -r10.w, l(120.000000), v0.x
        r10.x = (as_type<uint4>((-(as_type<float4>((r10).wwww)) * as_type<float4>((uint4(0x42f00000u)).xxxx) + as_type<float4>((v0).xxxx)))).x;
        // DXBC token 1003: lt r10.w, l(0.000000), r8.z
        r10.w = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x00000000u)).xxxx) < as_type<float4>((r8).zzzz))).w;
        // DXBC token 1010: mul r11.xy, r10.z, l(60.000000, -60.000000, 0.000000, 0.000000)
        r11.xy = (as_type<uint4>((as_type<float4>((r10).zzzz) * as_type<float4>((uint4(0x42700000u, 0xc2700000u, 0x00000000u, 0x00000000u)).xyzw)))).xy;
        // DXBC token 1020: mul r11.xy, r11.xy, cb0[r7.x + 5].z
        r11.xy = (as_type<uint4>((as_type<float4>((r11).xyxx) * as_type<float4>((cb[5 + ((r7).xxxx).x]).zzzz)))).xy;
        // DXBC token 1030: movc r10.z, r10.w, r11.x, r11.y
        r10.z = (select((r11).yyyy, (r11).xxxx, (r10).wwww != uint4(0))).z;
        // DXBC token 1039: add r10.y, r10.z, v0.y
        r10.y = (as_type<uint4>((as_type<float4>((r10).zzzz) + as_type<float4>((v0).yyyy)))).y;
        // DXBC token 1046: break
        break;
        // DXBC token 1047: case l(0.000000)
        case 2u:
        // DXBC token 1050: add r10.z, -r9.z, v0.x
        r10.z = (as_type<uint4>((-(as_type<float4>((r9).zzzz)) + as_type<float4>((v0).xxxx)))).z;
        // DXBC token 1058: div r10.z, r10.z, r9.x
        r10.z = (as_type<uint4>((as_type<float4>((r10).zzzz) / as_type<float4>((r9).xxxx)))).z;
        // DXBC token 1065: mul r10.z, r10.z, r10.z
        r10.z = (as_type<uint4>((as_type<float4>((r10).zzzz) * as_type<float4>((r10).zzzz)))).z;
        // DXBC token 1072: mul r10.z, r8.z, r10.z
        r10.z = (as_type<uint4>((as_type<float4>((r8).zzzz) * as_type<float4>((r10).zzzz)))).z;
        // DXBC token 1079: lt r10.w, l(0.000000), r8.z
        r10.w = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x00000000u)).xxxx) < as_type<float4>((r8).zzzz))).w;
        // DXBC token 1086: mul r11.xy, r10.z, l(60.000000, -60.000000, 0.000000, 0.000000)
        r11.xy = (as_type<uint4>((as_type<float4>((r10).zzzz) * as_type<float4>((uint4(0x42700000u, 0xc2700000u, 0x00000000u, 0x00000000u)).xyzw)))).xy;
        // DXBC token 1096: mul r11.xy, r11.xy, cb0[r7.x + 5].z
        r11.xy = (as_type<uint4>((as_type<float4>((r11).xyxx) * as_type<float4>((cb[5 + ((r7).xxxx).x]).zzzz)))).xy;
        // DXBC token 1106: movc r10.w, r10.w, r11.x, r11.y
        r10.w = (select((r11).yyyy, (r11).xxxx, (r10).wwww != uint4(0))).w;
        // DXBC token 1115: add r10.x, r10.w, v0.x
        r10.x = (as_type<uint4>((as_type<float4>((r10).wwww) + as_type<float4>((v0).xxxx)))).x;
        // DXBC token 1122: mul r10.z, r10.z, cb0[r7.x + 5].w
        r10.z = (as_type<uint4>((as_type<float4>((r10).zzzz) * as_type<float4>((cb[5 + ((r7).xxxx).x]).wwww)))).z;
        // DXBC token 1132: mad r10.y, -r10.z, l(120.000000), v0.y
        r10.y = (as_type<uint4>((-(as_type<float4>((r10).zzzz)) * as_type<float4>((uint4(0x42f00000u)).xxxx) + as_type<float4>((v0).yyyy)))).y;
        // DXBC token 1142: break
        break;
        // DXBC token 1143: case l(0.000000)
        case 3u:
        // DXBC token 1146: add r10.z, r9.x, r9.z
        r10.z = (as_type<uint4>((as_type<float4>((r9).xxxx) + as_type<float4>((r9).zzzz)))).z;
        // DXBC token 1153: add r10.z, r10.z, -v0.x
        r10.z = (as_type<uint4>((as_type<float4>((r10).zzzz) + -(as_type<float4>((v0).xxxx))))).z;
        // DXBC token 1161: div r10.z, r10.z, r9.x
        r10.z = (as_type<uint4>((as_type<float4>((r10).zzzz) / as_type<float4>((r9).xxxx)))).z;
        // DXBC token 1168: mul r10.z, r10.z, r10.z
        r10.z = (as_type<uint4>((as_type<float4>((r10).zzzz) * as_type<float4>((r10).zzzz)))).z;
        // DXBC token 1175: mul r10.z, r8.z, r10.z
        r10.z = (as_type<uint4>((as_type<float4>((r8).zzzz) * as_type<float4>((r10).zzzz)))).z;
        // DXBC token 1182: lt r8.z, l(0.000000), r8.z
        r8.z = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x00000000u)).xxxx) < as_type<float4>((r8).zzzz))).z;
        // DXBC token 1189: mul r11.xy, r10.z, l(60.000000, -60.000000, 0.000000, 0.000000)
        r11.xy = (as_type<uint4>((as_type<float4>((r10).zzzz) * as_type<float4>((uint4(0x42700000u, 0xc2700000u, 0x00000000u, 0x00000000u)).xyzw)))).xy;
        // DXBC token 1199: mul r11.xy, r11.xy, cb0[r7.x + 5].z
        r11.xy = (as_type<uint4>((as_type<float4>((r11).xyxx) * as_type<float4>((cb[5 + ((r7).xxxx).x]).zzzz)))).xy;
        // DXBC token 1209: movc r8.z, r8.z, r11.x, r11.y
        r8.z = (select((r11).yyyy, (r11).xxxx, (r8).zzzz != uint4(0))).z;
        // DXBC token 1218: add r10.x, -r8.z, v0.x
        r10.x = (as_type<uint4>((-(as_type<float4>((r8).zzzz)) + as_type<float4>((v0).xxxx)))).x;
        // DXBC token 1226: mul r8.z, r10.z, cb0[r7.x + 5].w
        r8.z = (as_type<uint4>((as_type<float4>((r10).zzzz) * as_type<float4>((cb[5 + ((r7).xxxx).x]).wwww)))).z;
        // DXBC token 1236: mad r10.y, -r8.z, l(120.000000), v0.y
        r10.y = (as_type<uint4>((-(as_type<float4>((r8).zzzz)) * as_type<float4>((uint4(0x42f00000u)).xxxx) + as_type<float4>((v0).yyyy)))).y;
        // DXBC token 1246: break
        break;
        // DXBC token 1247: default
        default:
        // DXBC token 1248: mov r10.xy, v0.xy
        r10.xy = ((v0).xyxx).xy;
        // DXBC token 1253: break
        break;
        // DXBC token 1254: endswitch
        }
        // DXBC token 1255: else
        } else {
        // DXBC token 1256: eq r11.xyzw, l(0.000000, 3.000000, 1.000000, 4.000000), cb0[r7.x + 4].z
        r11.xyzw = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x00000000u, 0x40400000u, 0x3f800000u, 0x40800000u)).xyzw) == as_type<float4>((cb[4 + ((r7).xxxx).x]).zzzz))).xyzw;
        // DXBC token 1269: or r10.zw, r11.yyyw, r11.xxxz
        r10.zw = (((r11).yyyw | (r11).xxxz)).zw;
        // DXBC token 1276: and r8.z, r10.w, l(0x3f800000)
        r8.z = (((r10).wwww & (uint4(0x3f800000u)).xxxx)).z;
        // DXBC token 1283: movc r8.z, r10.z, l(-1.000000), r8.z
        r8.z = (select((r8).zzzz, (uint4(0xbf800000u)).xxxx, (r10).zzzz != uint4(0))).z;
        // DXBC token 1292: ftou r10.z, cb0[r7.x + 4].w
        r10.z = (dx_ftou(as_type<float4>((cb[4 + ((r7).xxxx).x]).wwww))).z;
        // DXBC token 1300: switch r10.z
        switch (((r10).zzzz).x) {
        // DXBC token 1303: case l(0.000000)
        case 0u:
        // DXBC token 1306: add r11.y, r9.y, r9.w
        r11.y = (as_type<uint4>((as_type<float4>((r9).yyyy) + as_type<float4>((r9).wwww)))).y;
        // DXBC token 1313: add r11.x, r11.y, -v0.y
        r11.x = (as_type<uint4>((as_type<float4>((r11).yyyy) + -(as_type<float4>((v0).yyyy))))).x;
        // DXBC token 1321: mul r10.zw, r9.xxxy, l(0.000000, 0.000000, 0.500000, 1.000000)
        r10.zw = (as_type<uint4>((as_type<float4>((r9).xxxy) * as_type<float4>((uint4(0x00000000u, 0x00000000u, 0x3f000000u, 0x3f800000u)).xyzw)))).zw;
        // DXBC token 1331: break
        break;
        // DXBC token 1332: case l(0.000000)
        case 1u:
        // DXBC token 1335: mul r2.x, r9.x, l(0.500000)
        r2.x = (as_type<uint4>((as_type<float4>((r9).xxxx) * as_type<float4>((uint4(0x3f000000u)).xxxx)))).x;
        // DXBC token 1342: add r11.x, -r9.w, v0.y
        r11.x = (as_type<uint4>((-(as_type<float4>((r9).wwww)) + as_type<float4>((v0).yyyy)))).x;
        // DXBC token 1350: mov r10.zw, r2.xxxy
        r10.zw = ((r2).xxxy).zw;
        // DXBC token 1355: break
        break;
        // DXBC token 1356: case l(0.000000)
        case 2u:
        // DXBC token 1359: mul r2.w, r9.y, l(0.500000)
        r2.w = (as_type<uint4>((as_type<float4>((r9).yyyy) * as_type<float4>((uint4(0x3f000000u)).xxxx)))).w;
        // DXBC token 1366: add r11.x, -r9.z, v0.x
        r11.x = (as_type<uint4>((-(as_type<float4>((r9).zzzz)) + as_type<float4>((v0).xxxx)))).x;
        // DXBC token 1374: mov r10.zw, r2.zzzw
        r10.zw = ((r2).zzzw).zw;
        // DXBC token 1379: break
        break;
        // DXBC token 1380: case l(0.000000)
        case 3u:
        // DXBC token 1383: add r2.x, r9.x, r9.z
        r2.x = (as_type<uint4>((as_type<float4>((r9).xxxx) + as_type<float4>((r9).zzzz)))).x;
        // DXBC token 1390: add r11.x, r2.x, -v0.x
        r11.x = (as_type<uint4>((as_type<float4>((r2).xxxx) + -(as_type<float4>((v0).xxxx))))).x;
        // DXBC token 1398: mul r10.zw, r9.y, l(0.000000, 0.000000, 1.000000, 0.500000)
        r10.zw = (as_type<uint4>((as_type<float4>((r9).yyyy) * as_type<float4>((uint4(0x00000000u, 0x00000000u, 0x3f800000u, 0x3f000000u)).xyzw)))).zw;
        // DXBC token 1408: break
        break;
        // DXBC token 1409: default
        default:
        // DXBC token 1410: break
        break;
        // DXBC token 1411: endswitch
        }
        // DXBC token 1412: ge r2.x, r11.x, l(0.000000)
        r2.x = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r11).xxxx) >= as_type<float4>((uint4(0x00000000u)).xxxx))).x;
        // DXBC token 1419: add r2.w, cb0[0].x, cb0[r7.x + 3].w
        r2.w = (as_type<uint4>((as_type<float4>((cb[0]).xxxx) + as_type<float4>((cb[3 + ((r7).xxxx).x]).wwww)))).w;
        // DXBC token 1430: mul r2.w, r2.w, cb0[r7.x + 6].z
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((cb[6 + ((r7).xxxx).x]).zzzz)))).w;
        // DXBC token 1440: mul r2.w, r2.w, l(6.000000)
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((uint4(0x40c00000u)).xxxx)))).w;
        // DXBC token 1447: div r11.y, l(50.000000), cb0[r7.x + 5].z
        r11.y = (as_type<uint4>((as_type<float4>((uint4(0x42480000u)).xxxx) / as_type<float4>((cb[5 + ((r7).xxxx).x]).zzzz)))).y;
        // DXBC token 1457: mad r2.w, r2.w, r11.y, r11.x
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r11).yyyy) + as_type<float4>((r11).xxxx)))).w;
        // DXBC token 1466: mul r2.w, r2.w, l(0.003571)
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((uint4(0x3b6a0ea1u)).xxxx)))).w;
        // DXBC token 1473: sincos r2.w, null, r2.w
        { float4 angle = as_type<float4>((r2).wwww);
        r2.w = (as_type<uint4>(sin(angle))).w;
        }
        // DXBC token 1479: add r2.w, r2.w, r8.z
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) + as_type<float4>((r8).zzzz)))).w;
        // DXBC token 1486: mul r2.w, r2.w, l(0.100000)
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((uint4(0x3dcccccdu)).xxxx)))).w;
        // DXBC token 1493: mul r2.w, r2.w, cb0[r7.x + 5].w
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((cb[5 + ((r7).xxxx).x]).wwww)))).w;
        // DXBC token 1503: lt r8.z, r11.x, cb0[r7.x + 6].w
        r8.z = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r11).xxxx) < as_type<float4>((cb[6 + ((r7).xxxx).x]).wwww))).z;
        // DXBC token 1513: div r11.x, r11.x, cb0[r7.x + 6].w
        r11.x = (as_type<uint4>((as_type<float4>((r11).xxxx) / as_type<float4>((cb[6 + ((r7).xxxx).x]).wwww)))).x;
        // DXBC token 1523: min r11.x, r11.x, l(1.000000)
        r11.x = (as_type<uint4>(min(as_type<float4>((r11).xxxx), as_type<float4>((uint4(0x3f800000u)).xxxx)))).x;
        // DXBC token 1530: add r11.x, r11.x, l(-1.000000)
        r11.x = (as_type<uint4>((as_type<float4>((r11).xxxx) + as_type<float4>((uint4(0xbf800000u)).xxxx)))).x;
        // DXBC token 1537: mul r11.y, r11.x, r11.x
        r11.y = (as_type<uint4>((as_type<float4>((r11).xxxx) * as_type<float4>((r11).xxxx)))).y;
        // DXBC token 1544: mad r11.x, r11.y, r11.x, l(1.000000)
        r11.x = (as_type<uint4>((as_type<float4>((r11).yyyy) * as_type<float4>((r11).xxxx) + as_type<float4>((uint4(0x3f800000u)).xxxx)))).x;
        // DXBC token 1553: mul r11.x, r2.w, r11.x
        r11.x = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r11).xxxx)))).x;
        // DXBC token 1560: movc r2.w, r8.z, r11.x, r2.w
        r2.w = (select((r2).wwww, (r11).xxxx, (r8).zzzz != uint4(0))).w;
        // DXBC token 1569: add r11.xy, -r10.zw, v0.xy
        r11.xy = (as_type<uint4>((-(as_type<float4>((r10).zwzz)) + as_type<float4>((v0).xyxx)))).xy;
        // DXBC token 1577: add r11.xy, -r9.zw, r11.xy
        r11.xy = (as_type<uint4>((-(as_type<float4>((r9).zwzz)) + as_type<float4>((r11).xyxx)))).xy;
        // DXBC token 1585: sincos r12.x, r13.x, r2.w
        { float4 angle = as_type<float4>((r2).wwww);
        r12.x = (as_type<uint4>(sin(angle))).x;
        r13.x = (as_type<uint4>(cos(angle))).x;
        }
        // DXBC token 1592: mov r14.x, -r12.x
        r14.x = (as_type<uint4>(-(as_type<float4>((r12).xxxx)))).x;
        // DXBC token 1598: mov r14.y, r13.x
        r14.y = ((r13).xxxx).y;
        // DXBC token 1603: dp2 r13.x, r14.yx, r11.xy
        r13.x = (as_type<uint4>(float4(dot((as_type<float4>((r14).yxyy)).xy, (as_type<float4>((r11).xyxx)).xy)))).x;
        // DXBC token 1610: mov r14.z, r12.x
        r14.z = ((r12).xxxx).z;
        // DXBC token 1615: dp2 r13.y, r14.zy, r11.xy
        r13.y = (as_type<uint4>(float4(dot((as_type<float4>((r14).zyzz)).xy, (as_type<float4>((r11).xyxx)).xy)))).y;
        // DXBC token 1622: add r10.zw, r10.zzzw, r13.xxxy
        r10.zw = (as_type<uint4>((as_type<float4>((r10).zzzw) + as_type<float4>((r13).xxxy)))).zw;
        // DXBC token 1629: add r10.zw, r9.zzzw, r10.zzzw
        r10.zw = (as_type<uint4>((as_type<float4>((r9).zzzw) + as_type<float4>((r10).zzzw)))).zw;
        // DXBC token 1636: movc r10.xy, r2.x, r10.zw, v0.xy
        r10.xy = (select((v0).xyxx, (r10).zwzz, (r2).xxxx != uint4(0))).xy;
        // DXBC token 1645: endif
        }
        // DXBC token 1646: endif
        }
        // DXBC token 1647: if_nz r8.w
        if (((r8).wwww).x != 0u) {
        // DXBC token 1650: mul r9.xy, r9.xy, cb0[r7.x + 4].zw
        r9.xy = (as_type<uint4>((as_type<float4>((r9).xyxx) * as_type<float4>((cb[4 + ((r7).xxxx).x]).zwzz)))).xy;
        // DXBC token 1660: endif
        }
        // DXBC token 1661: ge r2.xw, r10.xxxy, r9.zzzw
        r2.xw = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r10).xxxy) >= as_type<float4>((r9).zzzw))).xw;
        // DXBC token 1668: add r9.zw, -r9.zzzw, r10.xxxy
        r9.zw = (as_type<uint4>((-(as_type<float4>((r9).zzzw)) + as_type<float4>((r10).xxxy)))).zw;
        // DXBC token 1676: lt r10.xy, r9.zw, r9.xy
        r10.xy = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r9).zwzz) < as_type<float4>((r9).xyxx))).xy;
        // DXBC token 1683: and r2.x, r2.x, r10.x
        r2.x = (((r2).xxxx & (r10).xxxx)).x;
        // DXBC token 1690: and r2.x, r2.w, r2.x
        r2.x = (((r2).wwww & (r2).xxxx)).x;
        // DXBC token 1697: and r2.x, r10.y, r2.x
        r2.x = (((r10).yyyy & (r2).xxxx)).x;
        // DXBC token 1704: if_nz r2.x
        if (((r2).xxxx).x != 0u) {
        // DXBC token 1707: if_nz r8.w
        if (((r8).wwww).x != 0u) {
        // DXBC token 1710: div r8.zw, r9.xxxy, cb0[r7.x + 4].zzzw
        r8.zw = (as_type<uint4>((as_type<float4>((r9).xxxy) / as_type<float4>((cb[4 + ((r7).xxxx).x]).zzzw)))).zw;
        // DXBC token 1720: div r8.zw, r9.zzzw, r8.zzzw
        r8.zw = (as_type<uint4>((as_type<float4>((r9).zzzw) / as_type<float4>((r8).zzzw)))).zw;
        // DXBC token 1727: ge r10.xy, r8.zw, -r8.zw
        r10.xy = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r8).zwzz) >= -(as_type<float4>((r8).zwzz)))).xy;
        // DXBC token 1735: movc r10.xy, r10.xy, l(1.000000, 1.000000, 0.000000, 0.000000), l(-1.000000, -1.000000, 0.000000, 0.000000)
        r10.xy = (select((uint4(0xbf800000u, 0xbf800000u, 0x00000000u, 0x00000000u)).xyzw, (uint4(0x3f800000u, 0x3f800000u, 0x00000000u, 0x00000000u)).xyzw, (r10).xyxx != uint4(0))).xy;
        // DXBC token 1750: mul r8.zw, r8.zzzw, r10.xxxy
        r8.zw = (as_type<uint4>((as_type<float4>((r8).zzzw) * as_type<float4>((r10).xxxy)))).zw;
        // DXBC token 1757: frc r8.zw, r8.zzzw
        r8.zw = (as_type<uint4>(fract(as_type<float4>((r8).zzzw)))).zw;
        // DXBC token 1762: mul r8.zw, r8.zzzw, r10.xxxy
        r8.zw = (as_type<uint4>((as_type<float4>((r8).zzzw) * as_type<float4>((r10).xxxy)))).zw;
        // DXBC token 1769: else
        } else {
        // DXBC token 1770: div r8.zw, r9.zzzw, r9.xxxy
        r8.zw = (as_type<uint4>((as_type<float4>((r9).zzzw) / as_type<float4>((r9).xxxy)))).zw;
        // DXBC token 1777: if_nz r8.y
        if (((r8).yyyy).x != 0u) {
        // DXBC token 1780: ftoi r9.xy, cb0[r7.x + 4].zw
        r9.xy = (as_type<uint4>(dx_ftoi(as_type<float4>((cb[4 + ((r7).xxxx).x]).zwzz)))).xy;
        // DXBC token 1788: iadd r2.w, r9.x, l(-1)
        r2.w = (((r9).xxxx + (uint4(0xffffffffu)).xxxx)).w;
        // DXBC token 1795: xor r8.y, r9.y, r2.w
        r8.y = (((r9).yyyy ^ (r2).wwww)).y;
        // DXBC token 1802: imax r2.w, r2.w, -r2.w
        r2.w = (as_type<uint4>(max(as_type<int4>((r2).wwww), as_type<int4>(uint4(0) - as_type<uint4>(as_type<int4>((r2).wwww)))))).w;
        // DXBC token 1810: imax r9.x, r9.y, -r9.y
        r9.x = (as_type<uint4>(max(as_type<int4>((r9).yyyy), as_type<int4>(uint4(0) - as_type<uint4>(as_type<int4>((r9).yyyy)))))).x;
        // DXBC token 1818: udiv r2.w, null, r2.w, r9.x
        { uint4 numerator = (r2).wwww, denominator = (r9).xxxx;
        r2.w = (select(numerator / max(denominator, uint4(1)), uint4(0xffffffffu), denominator == 0u)).w;
        }
        // DXBC token 1826: ineg r9.z, r2.w
        r9.z = ((uint4(0) - as_type<uint4>(as_type<int4>((r2).wwww)))).z;
        // DXBC token 1831: and r8.y, r8.y, l(0x80000000)
        r8.y = (((r8).yyyy & (uint4(0x80000000u)).xxxx)).y;
        // DXBC token 1838: movc r2.w, r8.y, r9.z, r2.w
        r2.w = (select((r2).wwww, (r9).zzzz, (r8).yyyy != uint4(0))).w;
        // DXBC token 1847: itof r2.w, r2.w
        r2.w = (as_type<uint4>(float4(as_type<int4>((r2).wwww)))).w;
        // DXBC token 1852: add r10.w, r2.w, l(1.000000)
        r10.w = (as_type<uint4>((as_type<float4>((r2).wwww) + as_type<float4>((uint4(0x3f800000u)).xxxx)))).w;
        // DXBC token 1859: div r2.w, r7.y, cb0[r7.x + 3].w
        r2.w = (as_type<uint4>((as_type<float4>((r7).yyyy) / as_type<float4>((cb[3 + ((r7).xxxx).x]).wwww)))).w;
        // DXBC token 1869: round_ni r2.w, r2.w
        r2.w = (as_type<uint4>(floor(as_type<float4>((r2).wwww)))).w;
        // DXBC token 1874: round_z r10.xyz, cb0[r7.x + 4].zw
        r10.xyz = (as_type<uint4>(trunc(as_type<float4>((cb[4 + ((r7).xxxx).x]).zwwz)))).xyz;
        // DXBC token 1882: mul r8.y, r2.w, r10.x
        r8.y = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r10).xxxx)))).y;
        // DXBC token 1889: ge r8.y, r8.y, -r8.y
        r8.y = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r8).yyyy) >= -(as_type<float4>((r8).yyyy)))).y;
        // DXBC token 1897: movc r8.y, r8.y, r10.x, -r10.x
        r8.y = (select(as_type<uint4>(-(as_type<float4>((r10).xxxx))), (r10).xxxx, (r8).yyyy != uint4(0))).y;
        // DXBC token 1907: div r9.z, l(1.000000, 1.000000, 1.000000, 1.000000), r8.y
        r9.z = (as_type<uint4>((as_type<float4>((uint4(0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u)).xyzw) / as_type<float4>((r8).yyyy)))).z;
        // DXBC token 1917: mul r2.w, r2.w, r9.z
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r9).zzzz)))).w;
        // DXBC token 1924: frc r2.w, r2.w
        r2.w = (as_type<uint4>(fract(as_type<float4>((r2).wwww)))).w;
        // DXBC token 1929: mul r2.w, r2.w, r8.y
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r8).yyyy)))).w;
        // DXBC token 1936: round_ne r2.w, r2.w
        r2.w = (as_type<uint4>(rint(as_type<float4>((r2).wwww)))).w;
        // DXBC token 1941: ftoi r2.w, r2.w
        r2.w = (as_type<uint4>(dx_ftoi(as_type<float4>((r2).wwww)))).w;
        // DXBC token 1946: div r9.zw, r8.zzzw, r10.zzzw
        r9.zw = (as_type<uint4>((as_type<float4>((r8).zzzw) / as_type<float4>((r10).zzzw)))).zw;
        // DXBC token 1953: and r8.y, r2.w, l(0x80000000)
        r8.y = (((r2).wwww & (uint4(0x80000000u)).xxxx)).y;
        // DXBC token 1960: imax r10.x, r2.w, -r2.w
        r10.x = (as_type<uint4>(max(as_type<int4>((r2).wwww), as_type<int4>(uint4(0) - as_type<uint4>(as_type<int4>((r2).wwww)))))).x;
        // DXBC token 1968: udiv r9.x, r10.x, r10.x, r9.x
        { uint4 numerator = (r10).xxxx, denominator = (r9).xxxx;
        r9.x = (select(numerator / max(denominator, uint4(1)), uint4(0xffffffffu), denominator == 0u)).x;
        r10.x = (select(numerator % max(denominator, uint4(1)), uint4(0xffffffffu), denominator == 0u)).x;
        }
        // DXBC token 1977: ineg r10.z, r10.x
        r10.z = ((uint4(0) - as_type<uint4>(as_type<int4>((r10).xxxx)))).z;
        // DXBC token 1982: movc r8.y, r8.y, r10.z, r10.x
        r8.y = (select((r10).xxxx, (r10).zzzz, (r8).yyyy != uint4(0))).y;
        // DXBC token 1991: itof r8.y, r8.y
        r8.y = (as_type<uint4>(float4(as_type<int4>((r8).yyyy)))).y;
        // DXBC token 1996: div r10.x, l(1.000000, 1.000000, 1.000000, 1.000000), r10.y
        r10.x = (as_type<uint4>((as_type<float4>((uint4(0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u)).xyzw) / as_type<float4>((r10).yyyy)))).x;
        // DXBC token 2006: mad r8.z, r8.y, r10.x, r9.z
        r8.z = (as_type<uint4>((as_type<float4>((r8).yyyy) * as_type<float4>((r10).xxxx) + as_type<float4>((r9).zzzz)))).z;
        // DXBC token 2015: xor r2.w, r9.y, r2.w
        r2.w = (((r9).yyyy ^ (r2).wwww)).w;
        // DXBC token 2022: ineg r8.y, r9.x
        r8.y = ((uint4(0) - as_type<uint4>(as_type<int4>((r9).xxxx)))).y;
        // DXBC token 2027: and r2.w, r2.w, l(0x80000000)
        r2.w = (((r2).wwww & (uint4(0x80000000u)).xxxx)).w;
        // DXBC token 2034: movc r2.w, r2.w, r8.y, r9.x
        r2.w = (select((r9).xxxx, (r8).yyyy, (r2).wwww != uint4(0))).w;
        // DXBC token 2043: itof r2.w, r2.w
        r2.w = (as_type<uint4>(float4(as_type<int4>((r2).wwww)))).w;
        // DXBC token 2048: div r8.y, l(1.000000, 1.000000, 1.000000, 1.000000), r10.w
        r8.y = (as_type<uint4>((as_type<float4>((uint4(0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u)).xyzw) / as_type<float4>((r10).wwww)))).y;
        // DXBC token 2058: mad r8.w, r2.w, r8.y, r9.w
        r8.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r8).yyyy) + as_type<float4>((r9).wwww)))).w;
        // DXBC token 2067: endif
        }
        // DXBC token 2068: endif
        }
        // DXBC token 2069: ftou r2.w, cb0[r7.x + 3].z
        r2.w = (dx_ftou(as_type<float4>((cb[3 + ((r7).xxxx).x]).zzzz))).w;
        // DXBC token 2077: switch r2.w
        switch (((r2).wwww).x) {
        // DXBC token 2080: case l(0.000000)
        case 0u:
        // DXBC token 2083: sample_indexable(texture2d)(float,float,float,float) r9.xyzw, r8.zwz, t1.xyzw, s0
        r9.xyzw = (as_type<uint4>(t1.sample(s, (as_type<float4>((r8).zwzz)).xy).xyzw)).xyzw;
        // DXBC token 2094: break
        break;
        // DXBC token 2095: case l(0.000000)
        case 1u:
        // DXBC token 2098: sample_indexable(texture2d)(float,float,float,float) r9.xyzw, r8.zwz, t2.xyzw, s0
        r9.xyzw = (as_type<uint4>(t2.sample(s, (as_type<float4>((r8).zwzz)).xy).xyzw)).xyzw;
        // DXBC token 2109: break
        break;
        // DXBC token 2110: case l(0.000000)
        case 2u:
        // DXBC token 2113: sample_indexable(texture2d)(float,float,float,float) r9.xyzw, r8.zwz, t3.xyzw, s0
        r9.xyzw = (as_type<uint4>(t3.sample(s, (as_type<float4>((r8).zwzz)).xy).xyzw)).xyzw;
        // DXBC token 2124: break
        break;
        // DXBC token 2125: case l(0.000000)
        case 3u:
        // DXBC token 2128: sample_indexable(texture2d)(float,float,float,float) r9.xyzw, r8.zwz, t4.xyzw, s0
        r9.xyzw = (as_type<uint4>(t4.sample(s, (as_type<float4>((r8).zwzz)).xy).xyzw)).xyzw;
        // DXBC token 2139: break
        break;
        // DXBC token 2140: case l(0.000000)
        case 4u:
        // DXBC token 2143: sample_indexable(texture2d)(float,float,float,float) r9.xyzw, r8.zwz, t5.xyzw, s0
        r9.xyzw = (as_type<uint4>(t5.sample(s, (as_type<float4>((r8).zwzz)).xy).xyzw)).xyzw;
        // DXBC token 2154: break
        break;
        // DXBC token 2155: case l(0.000000)
        case 5u:
        // DXBC token 2158: sample_indexable(texture2d)(float,float,float,float) r9.xyzw, r8.zwz, t6.xyzw, s0
        r9.xyzw = (as_type<uint4>(t6.sample(s, (as_type<float4>((r8).zwzz)).xy).xyzw)).xyzw;
        // DXBC token 2169: break
        break;
        // DXBC token 2170: case l(0.000000)
        case 6u:
        // DXBC token 2173: sample_indexable(texture2d)(float,float,float,float) r9.xyzw, r8.zwz, t7.xyzw, s0
        r9.xyzw = (as_type<uint4>(t7.sample(s, (as_type<float4>((r8).zwzz)).xy).xyzw)).xyzw;
        // DXBC token 2184: break
        break;
        // DXBC token 2185: default
        default:
        // DXBC token 2186: sample_indexable(texture2d)(float,float,float,float) r9.xyzw, r8.zwz, t8.xyzw, s0
        r9.xyzw = (as_type<uint4>(t8.sample(s, (as_type<float4>((r8).zwzz)).xy).xyzw)).xyzw;
        // DXBC token 2197: break
        break;
        // DXBC token 2198: endswitch
        }
        // DXBC token 2199: ne r2.w, l(0.000000), cb0[r7.x + 5].x
        r2.w = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x00000000u)).xxxx) != as_type<float4>((cb[5 + ((r7).xxxx).x]).xxxx))).w;
        // DXBC token 2209: if_nz r2.w
        if (((r2).wwww).x != 0u) {
        // DXBC token 2212: eq r2.w, l(1.000000), cb0[r7.x + 5].x
        r2.w = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x3f800000u)).xxxx) == as_type<float4>((cb[5 + ((r7).xxxx).x]).xxxx))).w;
        // DXBC token 2222: if_nz r2.w
        if (((r2).wwww).x != 0u) {
        // DXBC token 2225: lt r2.w, r7.w, cb0[r7.x + 5].y
        r2.w = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r7).wwww) < as_type<float4>((cb[5 + ((r7).xxxx).x]).yyyy))).w;
        // DXBC token 2235: if_nz r2.w
        if (((r2).wwww).x != 0u) {
        // DXBC token 2238: add r2.w, -r7.w, cb0[r7.x + 5].y
        r2.w = (as_type<uint4>((-(as_type<float4>((r7).wwww)) + as_type<float4>((cb[5 + ((r7).xxxx).x]).yyyy)))).w;
        // DXBC token 2249: div r2.w, r2.w, cb0[r7.x + 5].y
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) / as_type<float4>((cb[5 + ((r7).xxxx).x]).yyyy)))).w;
        // DXBC token 2259: add r2.w, -r2.w, l(1.000000)
        r2.w = (as_type<uint4>((-(as_type<float4>((r2).wwww)) + as_type<float4>((uint4(0x3f800000u)).xxxx)))).w;
        // DXBC token 2267: mul r2.w, r2.w, r9.w
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r9).wwww)))).w;
        // DXBC token 2274: else
        } else {
        // DXBC token 2275: mov r2.w, r9.w
        r2.w = ((r9).wwww).w;
        // DXBC token 2280: endif
        }
        // DXBC token 2281: else
        } else {
        // DXBC token 2282: eq r8.y, l(2.000000), cb0[r7.x + 5].x
        r8.y = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x40000000u)).xxxx) == as_type<float4>((cb[5 + ((r7).xxxx).x]).xxxx))).y;
        // DXBC token 2292: if_nz r8.y
        if (((r8).yyyy).x != 0u) {
        // DXBC token 2295: add r8.y, l(1.000000), -cb0[r7.x + 5].y
        r8.y = (as_type<uint4>((as_type<float4>((uint4(0x3f800000u)).xxxx) + -(as_type<float4>((cb[5 + ((r7).xxxx).x]).yyyy))))).y;
        // DXBC token 2306: lt r8.y, r8.y, r7.w
        r8.y = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r8).yyyy) < as_type<float4>((r7).wwww))).y;
        // DXBC token 2313: if_nz r8.y
        if (((r8).yyyy).x != 0u) {
        // DXBC token 2316: add r8.y, r7.w, l(-1.000000)
        r8.y = (as_type<uint4>((as_type<float4>((r7).wwww) + as_type<float4>((uint4(0xbf800000u)).xxxx)))).y;
        // DXBC token 2323: add r8.y, r8.y, cb0[r7.x + 5].y
        r8.y = (as_type<uint4>((as_type<float4>((r8).yyyy) + as_type<float4>((cb[5 + ((r7).xxxx).x]).yyyy)))).y;
        // DXBC token 2333: div r8.y, r8.y, cb0[r7.x + 5].y
        r8.y = (as_type<uint4>((as_type<float4>((r8).yyyy) / as_type<float4>((cb[5 + ((r7).xxxx).x]).yyyy)))).y;
        // DXBC token 2343: add r8.y, -r8.y, l(1.000000)
        r8.y = (as_type<uint4>((-(as_type<float4>((r8).yyyy)) + as_type<float4>((uint4(0x3f800000u)).xxxx)))).y;
        // DXBC token 2351: mul r2.w, r8.y, r9.w
        r2.w = (as_type<uint4>((as_type<float4>((r8).yyyy) * as_type<float4>((r9).wwww)))).w;
        // DXBC token 2358: else
        } else {
        // DXBC token 2359: mov r2.w, r9.w
        r2.w = ((r9).wwww).w;
        // DXBC token 2364: endif
        }
        // DXBC token 2365: else
        } else {
        // DXBC token 2366: eq r8.y, l(3.000000), cb0[r7.x + 5].x
        r8.y = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x40400000u)).xxxx) == as_type<float4>((cb[5 + ((r7).xxxx).x]).xxxx))).y;
        // DXBC token 2376: if_nz r8.y
        if (((r8).yyyy).x != 0u) {
        // DXBC token 2379: lt r8.y, r7.w, l(0.500000)
        r8.y = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r7).wwww) < as_type<float4>((uint4(0x3f000000u)).xxxx))).y;
        // DXBC token 2386: if_nz r8.y
        if (((r8).yyyy).x != 0u) {
        // DXBC token 2389: lt r8.y, r7.w, cb0[r7.x + 5].y
        r8.y = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r7).wwww) < as_type<float4>((cb[5 + ((r7).xxxx).x]).yyyy))).y;
        // DXBC token 2399: if_nz r8.y
        if (((r8).yyyy).x != 0u) {
        // DXBC token 2402: add r8.y, -r7.w, cb0[r7.x + 5].y
        r8.y = (as_type<uint4>((-(as_type<float4>((r7).wwww)) + as_type<float4>((cb[5 + ((r7).xxxx).x]).yyyy)))).y;
        // DXBC token 2413: div r8.y, r8.y, cb0[r7.x + 5].y
        r8.y = (as_type<uint4>((as_type<float4>((r8).yyyy) / as_type<float4>((cb[5 + ((r7).xxxx).x]).yyyy)))).y;
        // DXBC token 2423: add r8.y, -r8.y, l(1.000000)
        r8.y = (as_type<uint4>((-(as_type<float4>((r8).yyyy)) + as_type<float4>((uint4(0x3f800000u)).xxxx)))).y;
        // DXBC token 2431: mul r2.w, r8.y, r9.w
        r2.w = (as_type<uint4>((as_type<float4>((r8).yyyy) * as_type<float4>((r9).wwww)))).w;
        // DXBC token 2438: else
        } else {
        // DXBC token 2439: mov r2.w, r9.w
        r2.w = ((r9).wwww).w;
        // DXBC token 2444: endif
        }
        // DXBC token 2445: else
        } else {
        // DXBC token 2446: add r8.y, l(1.000000), -cb0[r7.x + 5].y
        r8.y = (as_type<uint4>((as_type<float4>((uint4(0x3f800000u)).xxxx) + -(as_type<float4>((cb[5 + ((r7).xxxx).x]).yyyy))))).y;
        // DXBC token 2457: lt r8.y, r8.y, r7.w
        r8.y = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r8).yyyy) < as_type<float4>((r7).wwww))).y;
        // DXBC token 2464: if_nz r8.y
        if (((r8).yyyy).x != 0u) {
        // DXBC token 2467: add r8.y, r7.w, l(-1.000000)
        r8.y = (as_type<uint4>((as_type<float4>((r7).wwww) + as_type<float4>((uint4(0xbf800000u)).xxxx)))).y;
        // DXBC token 2474: add r8.y, r8.y, cb0[r7.x + 5].y
        r8.y = (as_type<uint4>((as_type<float4>((r8).yyyy) + as_type<float4>((cb[5 + ((r7).xxxx).x]).yyyy)))).y;
        // DXBC token 2484: div r8.y, r8.y, cb0[r7.x + 5].y
        r8.y = (as_type<uint4>((as_type<float4>((r8).yyyy) / as_type<float4>((cb[5 + ((r7).xxxx).x]).yyyy)))).y;
        // DXBC token 2494: add r8.y, -r8.y, l(1.000000)
        r8.y = (as_type<uint4>((-(as_type<float4>((r8).yyyy)) + as_type<float4>((uint4(0x3f800000u)).xxxx)))).y;
        // DXBC token 2502: mul r2.w, r8.y, r9.w
        r2.w = (as_type<uint4>((as_type<float4>((r8).yyyy) * as_type<float4>((r9).wwww)))).w;
        // DXBC token 2509: else
        } else {
        // DXBC token 2510: mov r2.w, r9.w
        r2.w = ((r9).wwww).w;
        // DXBC token 2515: endif
        }
        // DXBC token 2516: endif
        }
        // DXBC token 2517: else
        } else {
        // DXBC token 2518: eq r8.y, l(4.000000), cb0[r7.x + 5].x
        r8.y = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x40800000u)).xxxx) == as_type<float4>((cb[5 + ((r7).xxxx).x]).xxxx))).y;
        // DXBC token 2528: if_nz r8.y
        if (((r8).yyyy).x != 0u) {
        // DXBC token 2531: lt r8.y, r7.w, l(0.500000)
        r8.y = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r7).wwww) < as_type<float4>((uint4(0x3f000000u)).xxxx))).y;
        // DXBC token 2538: if_nz r8.y
        if (((r8).yyyy).x != 0u) {
        // DXBC token 2541: lt r8.y, r7.w, cb0[r7.x + 5].y
        r8.y = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r7).wwww) < as_type<float4>((cb[5 + ((r7).xxxx).x]).yyyy))).y;
        // DXBC token 2551: if_nz r8.y
        if (((r8).yyyy).x != 0u) {
        // DXBC token 2554: add r8.y, -r7.w, cb0[r7.x + 5].y
        r8.y = (as_type<uint4>((-(as_type<float4>((r7).wwww)) + as_type<float4>((cb[5 + ((r7).xxxx).x]).yyyy)))).y;
        // DXBC token 2565: div r8.y, r8.y, cb0[r7.x + 5].y
        r8.y = (as_type<uint4>((as_type<float4>((r8).yyyy) / as_type<float4>((cb[5 + ((r7).xxxx).x]).yyyy)))).y;
        // DXBC token 2575: mul r2.w, r8.y, r9.w
        r2.w = (as_type<uint4>((as_type<float4>((r8).yyyy) * as_type<float4>((r9).wwww)))).w;
        // DXBC token 2582: else
        } else {
        // DXBC token 2583: mov r2.w, l(0.000000)
        r2.w = ((uint4(0x00000000u)).xxxx).w;
        // DXBC token 2588: endif
        }
        // DXBC token 2589: else
        } else {
        // DXBC token 2590: add r8.y, l(1.000000), -cb0[r7.x + 5].y
        r8.y = (as_type<uint4>((as_type<float4>((uint4(0x3f800000u)).xxxx) + -(as_type<float4>((cb[5 + ((r7).xxxx).x]).yyyy))))).y;
        // DXBC token 2601: lt r10.x, r8.y, r7.w
        r10.x = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r8).yyyy) < as_type<float4>((r7).wwww))).x;
        // DXBC token 2608: if_nz r10.x
        if (((r10).xxxx).x != 0u) {
        // DXBC token 2611: add r7.w, r7.w, -r8.y
        r7.w = (as_type<uint4>((as_type<float4>((r7).wwww) + -(as_type<float4>((r8).yyyy))))).w;
        // DXBC token 2619: div r7.w, r7.w, cb0[r7.x + 5].y
        r7.w = (as_type<uint4>((as_type<float4>((r7).wwww) / as_type<float4>((cb[5 + ((r7).xxxx).x]).yyyy)))).w;
        // DXBC token 2629: mul r2.w, r7.w, r9.w
        r2.w = (as_type<uint4>((as_type<float4>((r7).wwww) * as_type<float4>((r9).wwww)))).w;
        // DXBC token 2636: else
        } else {
        // DXBC token 2637: mov r2.w, l(0.000000)
        r2.w = ((uint4(0x00000000u)).xxxx).w;
        // DXBC token 2642: endif
        }
        // DXBC token 2643: endif
        }
        // DXBC token 2644: else
        } else {
        // DXBC token 2645: mov r2.w, r9.w
        r2.w = ((r9).wwww).w;
        // DXBC token 2650: endif
        }
        // DXBC token 2651: endif
        }
        // DXBC token 2652: endif
        }
        // DXBC token 2653: endif
        }
        // DXBC token 2654: else
        } else {
        // DXBC token 2655: mov r2.w, r9.w
        r2.w = ((r9).wwww).w;
        // DXBC token 2660: endif
        }
        // DXBC token 2661: if_nz r7.z
        if (((r7).zzzz).x != 0u) {
        // DXBC token 2664: eq r7.z, l(0.000000), cb0[r7.x + 4].z
        r7.z = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x00000000u)).xxxx) == as_type<float4>((cb[4 + ((r7).xxxx).x]).zzzz))).z;
        // DXBC token 2674: if_nz r7.z
        if (((r7).zzzz).x != 0u) {
        // DXBC token 2677: ftou r7.z, cb0[r7.x + 3].w
        r7.z = (dx_ftou(as_type<float4>((cb[3 + ((r7).xxxx).x]).wwww))).z;
        // DXBC token 2685: switch r7.z
        switch (((r7).zzzz).x) {
        // DXBC token 2688: case l(0.000000)
        case 0u:
        // DXBC token 2691: sample_indexable(texture2d)(float,float,float,float) r7.z, r8.zwz, t9.yzxw, s0
        r7.z = (as_type<uint4>(t9.sample(s, (as_type<float4>((r8).zwzz)).xy).yzxw)).z;
        // DXBC token 2702: mov r7.w, l(0xFFFFFFFF)
        r7.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 2707: break
        break;
        // DXBC token 2708: case l(0.000000)
        case 1u:
        // DXBC token 2711: sample_indexable(texture2d)(float,float,float,float) r7.z, r8.zwz, t10.yzxw, s0
        r7.z = (as_type<uint4>(t10.sample(s, (as_type<float4>((r8).zwzz)).xy).yzxw)).z;
        // DXBC token 2722: mov r7.w, l(0xFFFFFFFF)
        r7.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 2727: break
        break;
        // DXBC token 2728: case l(0.000000)
        case 2u:
        // DXBC token 2731: sample_indexable(texture2d)(float,float,float,float) r7.z, r8.zwz, t11.yzxw, s0
        r7.z = (as_type<uint4>(t11.sample(s, (as_type<float4>((r8).zwzz)).xy).yzxw)).z;
        // DXBC token 2742: mov r7.w, l(0xFFFFFFFF)
        r7.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 2747: break
        break;
        // DXBC token 2748: default
        default:
        // DXBC token 2749: mov r7.w, l(0.000000)
        r7.w = ((uint4(0x00000000u)).xxxx).w;
        // DXBC token 2754: break
        break;
        // DXBC token 2755: endswitch
        }
        // DXBC token 2756: and r7.z, r7.z, r7.w
        r7.z = (((r7).zzzz & (r7).wwww)).z;
        // DXBC token 2763: mul r2.w, r2.w, r7.z
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r7).zzzz)))).w;
        // DXBC token 2770: else
        } else {
        // DXBC token 2771: eq r7.z, l(1.000000), cb0[r7.x + 4].z
        r7.z = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x3f800000u)).xxxx) == as_type<float4>((cb[4 + ((r7).xxxx).x]).zzzz))).z;
        // DXBC token 2781: if_nz r7.z
        if (((r7).zzzz).x != 0u) {
        // DXBC token 2784: add r7.zw, l(0.000000, 0.000000, 1.000000, 1.000000), -cb0[r7.x + 5].zzzw
        r7.zw = (as_type<uint4>((as_type<float4>((uint4(0x00000000u, 0x00000000u, 0x3f800000u, 0x3f800000u)).xyzw) + -(as_type<float4>((cb[5 + ((r7).xxxx).x]).zzzw))))).zw;
        // DXBC token 2798: mul r10.xy, r8.zw, cb0[r7.x + 5].zw
        r10.xy = (as_type<uint4>((as_type<float4>((r8).zwzz) * as_type<float4>((cb[5 + ((r7).xxxx).x]).zwzz)))).xy;
        // DXBC token 2808: div r8.y, cb0[0].x, cb0[r7.x + 4].w
        r8.y = (as_type<uint4>((as_type<float4>((cb[0]).xxxx) / as_type<float4>((cb[4 + ((r7).xxxx).x]).wwww)))).y;
        // DXBC token 2819: ge r10.z, r8.y, -r8.y
        r10.z = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r8).yyyy) >= -(as_type<float4>((r8).yyyy)))).z;
        // DXBC token 2827: movc r10.z, r10.z, l(1.000000), l(-1.000000)
        r10.z = (select((uint4(0xbf800000u)).xxxx, (uint4(0x3f800000u)).xxxx, (r10).zzzz != uint4(0))).z;
        // DXBC token 2836: mul r8.y, r8.y, r10.z
        r8.y = (as_type<uint4>((as_type<float4>((r8).yyyy) * as_type<float4>((r10).zzzz)))).y;
        // DXBC token 2843: frc r8.y, r8.y
        r8.y = (as_type<uint4>(fract(as_type<float4>((r8).yyyy)))).y;
        // DXBC token 2848: mul r10.w, r8.y, r10.z
        r10.w = (as_type<uint4>((as_type<float4>((r8).yyyy) * as_type<float4>((r10).zzzz)))).w;
        // DXBC token 2855: lt r11.x, r10.w, l(0.250000)
        r11.x = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r10).wwww) < as_type<float4>((uint4(0x3e800000u)).xxxx))).x;
        // DXBC token 2862: if_nz r11.x
        if (((r11).xxxx).x != 0u) {
        // DXBC token 2865: mul r11.x, r10.w, l(4.000000)
        r11.x = (as_type<uint4>((as_type<float4>((r10).wwww) * as_type<float4>((uint4(0x40800000u)).xxxx)))).x;
        // DXBC token 2872: mad r11.yz, r8.zzw, cb0[r7.x + 5].zzw, r7.zzw
        r11.yz = (as_type<uint4>((as_type<float4>((r8).zzwz) * as_type<float4>((cb[5 + ((r7).xxxx).x]).zzwz) + as_type<float4>((r7).zzwz)))).yz;
        // DXBC token 2884: ftou r11.w, cb0[r7.x + 3].w
        r11.w = (dx_ftou(as_type<float4>((cb[3 + ((r7).xxxx).x]).wwww))).w;
        // DXBC token 2892: switch r11.w
        switch (((r11).wwww).x) {
        // DXBC token 2895: case l(0.000000)
        case 0u:
        // DXBC token 2898: sample_indexable(texture2d)(float,float,float,float) r12.x, r10.xyx, t9.xyzw, s0
        r12.x = (as_type<uint4>(t9.sample(s, (as_type<float4>((r10).xyxx)).xy).xyzw)).x;
        // DXBC token 2909: mov r12.y, l(0xFFFFFFFF)
        r12.y = ((uint4(0xffffffffu)).xxxx).y;
        // DXBC token 2914: break
        break;
        // DXBC token 2915: case l(0.000000)
        case 1u:
        // DXBC token 2918: sample_indexable(texture2d)(float,float,float,float) r12.x, r10.xyx, t10.xyzw, s0
        r12.x = (as_type<uint4>(t10.sample(s, (as_type<float4>((r10).xyxx)).xy).xyzw)).x;
        // DXBC token 2929: mov r12.y, l(0xFFFFFFFF)
        r12.y = ((uint4(0xffffffffu)).xxxx).y;
        // DXBC token 2934: break
        break;
        // DXBC token 2935: case l(0.000000)
        case 2u:
        // DXBC token 2938: sample_indexable(texture2d)(float,float,float,float) r12.x, r10.xyx, t11.xyzw, s0
        r12.x = (as_type<uint4>(t11.sample(s, (as_type<float4>((r10).xyxx)).xy).xyzw)).x;
        // DXBC token 2949: mov r12.y, l(0xFFFFFFFF)
        r12.y = ((uint4(0xffffffffu)).xxxx).y;
        // DXBC token 2954: break
        break;
        // DXBC token 2955: default
        default:
        // DXBC token 2956: mov r12.y, l(0.000000)
        r12.y = ((uint4(0x00000000u)).xxxx).y;
        // DXBC token 2961: break
        break;
        // DXBC token 2962: endswitch
        }
        // DXBC token 2963: and r12.x, r12.x, r12.y
        r12.x = (((r12).xxxx & (r12).yyyy)).x;
        // DXBC token 2970: switch r11.w
        switch (((r11).wwww).x) {
        // DXBC token 2973: case l(0.000000)
        case 0u:
        // DXBC token 2976: sample_indexable(texture2d)(float,float,float,float) r11.w, r11.yzy, t9.yzwx, s0
        r11.w = (as_type<uint4>(t9.sample(s, (as_type<float4>((r11).yzyy)).xy).yzwx)).w;
        // DXBC token 2987: mov r12.y, l(0xFFFFFFFF)
        r12.y = ((uint4(0xffffffffu)).xxxx).y;
        // DXBC token 2992: break
        break;
        // DXBC token 2993: case l(0.000000)
        case 1u:
        // DXBC token 2996: sample_indexable(texture2d)(float,float,float,float) r11.w, r11.yzy, t10.yzwx, s0
        r11.w = (as_type<uint4>(t10.sample(s, (as_type<float4>((r11).yzyy)).xy).yzwx)).w;
        // DXBC token 3007: mov r12.y, l(0xFFFFFFFF)
        r12.y = ((uint4(0xffffffffu)).xxxx).y;
        // DXBC token 3012: break
        break;
        // DXBC token 3013: case l(0.000000)
        case 2u:
        // DXBC token 3016: sample_indexable(texture2d)(float,float,float,float) r11.w, r11.yzy, t11.yzwx, s0
        r11.w = (as_type<uint4>(t11.sample(s, (as_type<float4>((r11).yzyy)).xy).yzwx)).w;
        // DXBC token 3027: mov r12.y, l(0xFFFFFFFF)
        r12.y = ((uint4(0xffffffffu)).xxxx).y;
        // DXBC token 3032: break
        break;
        // DXBC token 3033: default
        default:
        // DXBC token 3034: mov r12.y, l(0.000000)
        r12.y = ((uint4(0x00000000u)).xxxx).y;
        // DXBC token 3039: break
        break;
        // DXBC token 3040: endswitch
        }
        // DXBC token 3041: and r11.y, r11.w, r12.y
        r11.y = (((r11).wwww & (r12).yyyy)).y;
        // DXBC token 3048: add r11.y, -r12.x, r11.y
        r11.y = (as_type<uint4>((-(as_type<float4>((r12).xxxx)) + as_type<float4>((r11).yyyy)))).y;
        // DXBC token 3056: mad r11.x, r11.x, r11.y, r12.x
        r11.x = (as_type<uint4>((as_type<float4>((r11).xxxx) * as_type<float4>((r11).yyyy) + as_type<float4>((r12).xxxx)))).x;
        // DXBC token 3065: mul r2.w, r2.w, r11.x
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r11).xxxx)))).w;
        // DXBC token 3072: else
        } else {
        // DXBC token 3073: lt r11.x, r10.w, l(0.500000)
        r11.x = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r10).wwww) < as_type<float4>((uint4(0x3f000000u)).xxxx))).x;
        // DXBC token 3080: if_nz r11.x
        if (((r11).xxxx).x != 0u) {
        // DXBC token 3083: mad r11.x, r10.z, r8.y, l(-0.250000)
        r11.x = (as_type<uint4>((as_type<float4>((r10).zzzz) * as_type<float4>((r8).yyyy) + as_type<float4>((uint4(0xbe800000u)).xxxx)))).x;
        // DXBC token 3092: mul r11.x, r11.x, l(4.000000)
        r11.x = (as_type<uint4>((as_type<float4>((r11).xxxx) * as_type<float4>((uint4(0x40800000u)).xxxx)))).x;
        // DXBC token 3099: add r4.x, l(1.000000), -cb0[r7.x + 5].z
        r4.x = (as_type<uint4>((as_type<float4>((uint4(0x3f800000u)).xxxx) + -(as_type<float4>((cb[5 + ((r7).xxxx).x]).zzzz))))).x;
        // DXBC token 3110: mad r11.yz, r8.zzw, cb0[r7.x + 5].zzw, r4.xxy
        r11.yz = (as_type<uint4>((as_type<float4>((r8).zzwz) * as_type<float4>((cb[5 + ((r7).xxxx).x]).zzwz) + as_type<float4>((r4).xxyx)))).yz;
        // DXBC token 3122: mad r7.zw, r8.zzzw, cb0[r7.x + 5].zzzw, r7.zzzw
        r7.zw = (as_type<uint4>((as_type<float4>((r8).zzzw) * as_type<float4>((cb[5 + ((r7).xxxx).x]).zzzw) + as_type<float4>((r7).zzzw)))).zw;
        // DXBC token 3134: ftou r4.x, cb0[r7.x + 3].w
        r4.x = (dx_ftou(as_type<float4>((cb[3 + ((r7).xxxx).x]).wwww))).x;
        // DXBC token 3142: switch r4.x
        switch (((r4).xxxx).x) {
        // DXBC token 3145: case l(0.000000)
        case 0u:
        // DXBC token 3148: sample_indexable(texture2d)(float,float,float,float) r11.w, r7.zwz, t9.yzwx, s0
        r11.w = (as_type<uint4>(t9.sample(s, (as_type<float4>((r7).zwzz)).xy).yzwx)).w;
        // DXBC token 3159: mov r12.x, l(0xFFFFFFFF)
        r12.x = ((uint4(0xffffffffu)).xxxx).x;
        // DXBC token 3164: break
        break;
        // DXBC token 3165: case l(0.000000)
        case 1u:
        // DXBC token 3168: sample_indexable(texture2d)(float,float,float,float) r11.w, r7.zwz, t10.yzwx, s0
        r11.w = (as_type<uint4>(t10.sample(s, (as_type<float4>((r7).zwzz)).xy).yzwx)).w;
        // DXBC token 3179: mov r12.x, l(0xFFFFFFFF)
        r12.x = ((uint4(0xffffffffu)).xxxx).x;
        // DXBC token 3184: break
        break;
        // DXBC token 3185: case l(0.000000)
        case 2u:
        // DXBC token 3188: sample_indexable(texture2d)(float,float,float,float) r11.w, r7.zwz, t11.yzwx, s0
        r11.w = (as_type<uint4>(t11.sample(s, (as_type<float4>((r7).zwzz)).xy).yzwx)).w;
        // DXBC token 3199: mov r12.x, l(0xFFFFFFFF)
        r12.x = ((uint4(0xffffffffu)).xxxx).x;
        // DXBC token 3204: break
        break;
        // DXBC token 3205: default
        default:
        // DXBC token 3206: mov r12.x, l(0.000000)
        r12.x = ((uint4(0x00000000u)).xxxx).x;
        // DXBC token 3211: break
        break;
        // DXBC token 3212: endswitch
        }
        // DXBC token 3213: and r7.z, r11.w, r12.x
        r7.z = (((r11).wwww & (r12).xxxx)).z;
        // DXBC token 3220: switch r4.x
        switch (((r4).xxxx).x) {
        // DXBC token 3223: case l(0.000000)
        case 0u:
        // DXBC token 3226: sample_indexable(texture2d)(float,float,float,float) r4.x, r11.yzy, t9.xyzw, s0
        r4.x = (as_type<uint4>(t9.sample(s, (as_type<float4>((r11).yzyy)).xy).xyzw)).x;
        // DXBC token 3237: mov r7.w, l(0xFFFFFFFF)
        r7.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 3242: break
        break;
        // DXBC token 3243: case l(0.000000)
        case 1u:
        // DXBC token 3246: sample_indexable(texture2d)(float,float,float,float) r4.x, r11.yzy, t10.xyzw, s0
        r4.x = (as_type<uint4>(t10.sample(s, (as_type<float4>((r11).yzyy)).xy).xyzw)).x;
        // DXBC token 3257: mov r7.w, l(0xFFFFFFFF)
        r7.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 3262: break
        break;
        // DXBC token 3263: case l(0.000000)
        case 2u:
        // DXBC token 3266: sample_indexable(texture2d)(float,float,float,float) r4.x, r11.yzy, t11.xyzw, s0
        r4.x = (as_type<uint4>(t11.sample(s, (as_type<float4>((r11).yzyy)).xy).xyzw)).x;
        // DXBC token 3277: mov r7.w, l(0xFFFFFFFF)
        r7.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 3282: break
        break;
        // DXBC token 3283: default
        default:
        // DXBC token 3284: mov r7.w, l(0.000000)
        r7.w = ((uint4(0x00000000u)).xxxx).w;
        // DXBC token 3289: break
        break;
        // DXBC token 3290: endswitch
        }
        // DXBC token 3291: and r4.x, r4.x, r7.w
        r4.x = (((r4).xxxx & (r7).wwww)).x;
        // DXBC token 3298: add r4.x, -r7.z, r4.x
        r4.x = (as_type<uint4>((-(as_type<float4>((r7).zzzz)) + as_type<float4>((r4).xxxx)))).x;
        // DXBC token 3306: mad r4.x, r11.x, r4.x, r7.z
        r4.x = (as_type<uint4>((as_type<float4>((r11).xxxx) * as_type<float4>((r4).xxxx) + as_type<float4>((r7).zzzz)))).x;
        // DXBC token 3315: mul r2.w, r2.w, r4.x
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r4).xxxx)))).w;
        // DXBC token 3322: else
        } else {
        // DXBC token 3323: lt r4.x, r10.w, l(0.750000)
        r4.x = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r10).wwww) < as_type<float4>((uint4(0x3f400000u)).xxxx))).x;
        // DXBC token 3330: if_nz r4.x
        if (((r4).xxxx).x != 0u) {
        // DXBC token 3333: mad r4.x, r10.z, r8.y, l(-0.500000)
        r4.x = (as_type<uint4>((as_type<float4>((r10).zzzz) * as_type<float4>((r8).yyyy) + as_type<float4>((uint4(0xbf000000u)).xxxx)))).x;
        // DXBC token 3342: mul r4.x, r4.x, l(4.000000)
        r4.x = (as_type<uint4>((as_type<float4>((r4).xxxx) * as_type<float4>((uint4(0x40800000u)).xxxx)))).x;
        // DXBC token 3349: add r4.w, l(1.000000), -cb0[r7.x + 5].w
        r4.w = (as_type<uint4>((as_type<float4>((uint4(0x3f800000u)).xxxx) + -(as_type<float4>((cb[5 + ((r7).xxxx).x]).wwww))))).w;
        // DXBC token 3360: mad r7.zw, r8.zzzw, cb0[r7.x + 5].zzzw, r4.zzzw
        r7.zw = (as_type<uint4>((as_type<float4>((r8).zzzw) * as_type<float4>((cb[5 + ((r7).xxxx).x]).zzzw) + as_type<float4>((r4).zzzw)))).zw;
        // DXBC token 3372: add r5.x, l(1.000000), -cb0[r7.x + 5].z
        r5.x = (as_type<uint4>((as_type<float4>((uint4(0x3f800000u)).xxxx) + -(as_type<float4>((cb[5 + ((r7).xxxx).x]).zzzz))))).x;
        // DXBC token 3383: mad r11.xy, r8.zw, cb0[r7.x + 5].zw, r5.xy
        r11.xy = (as_type<uint4>((as_type<float4>((r8).zwzz) * as_type<float4>((cb[5 + ((r7).xxxx).x]).zwzz) + as_type<float4>((r5).xyxx)))).xy;
        // DXBC token 3395: ftou r4.w, cb0[r7.x + 3].w
        r4.w = (dx_ftou(as_type<float4>((cb[3 + ((r7).xxxx).x]).wwww))).w;
        // DXBC token 3403: switch r4.w
        switch (((r4).wwww).x) {
        // DXBC token 3406: case l(0.000000)
        case 0u:
        // DXBC token 3409: sample_indexable(texture2d)(float,float,float,float) r5.x, r11.xyx, t9.xyzw, s0
        r5.x = (as_type<uint4>(t9.sample(s, (as_type<float4>((r11).xyxx)).xy).xyzw)).x;
        // DXBC token 3420: mov r10.w, l(0xFFFFFFFF)
        r10.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 3425: break
        break;
        // DXBC token 3426: case l(0.000000)
        case 1u:
        // DXBC token 3429: sample_indexable(texture2d)(float,float,float,float) r5.x, r11.xyx, t10.xyzw, s0
        r5.x = (as_type<uint4>(t10.sample(s, (as_type<float4>((r11).xyxx)).xy).xyzw)).x;
        // DXBC token 3440: mov r10.w, l(0xFFFFFFFF)
        r10.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 3445: break
        break;
        // DXBC token 3446: case l(0.000000)
        case 2u:
        // DXBC token 3449: sample_indexable(texture2d)(float,float,float,float) r5.x, r11.xyx, t11.xyzw, s0
        r5.x = (as_type<uint4>(t11.sample(s, (as_type<float4>((r11).xyxx)).xy).xyzw)).x;
        // DXBC token 3460: mov r10.w, l(0xFFFFFFFF)
        r10.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 3465: break
        break;
        // DXBC token 3466: default
        default:
        // DXBC token 3467: mov r10.w, l(0.000000)
        r10.w = ((uint4(0x00000000u)).xxxx).w;
        // DXBC token 3472: break
        break;
        // DXBC token 3473: endswitch
        }
        // DXBC token 3474: and r5.x, r5.x, r10.w
        r5.x = (((r5).xxxx & (r10).wwww)).x;
        // DXBC token 3481: switch r4.w
        switch (((r4).wwww).x) {
        // DXBC token 3484: case l(0.000000)
        case 0u:
        // DXBC token 3487: sample_indexable(texture2d)(float,float,float,float) r4.w, r7.zwz, t9.yzwx, s0
        r4.w = (as_type<uint4>(t9.sample(s, (as_type<float4>((r7).zwzz)).xy).yzwx)).w;
        // DXBC token 3498: mov r10.w, l(0xFFFFFFFF)
        r10.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 3503: break
        break;
        // DXBC token 3504: case l(0.000000)
        case 1u:
        // DXBC token 3507: sample_indexable(texture2d)(float,float,float,float) r4.w, r7.zwz, t10.yzwx, s0
        r4.w = (as_type<uint4>(t10.sample(s, (as_type<float4>((r7).zwzz)).xy).yzwx)).w;
        // DXBC token 3518: mov r10.w, l(0xFFFFFFFF)
        r10.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 3523: break
        break;
        // DXBC token 3524: case l(0.000000)
        case 2u:
        // DXBC token 3527: sample_indexable(texture2d)(float,float,float,float) r4.w, r7.zwz, t11.yzwx, s0
        r4.w = (as_type<uint4>(t11.sample(s, (as_type<float4>((r7).zwzz)).xy).yzwx)).w;
        // DXBC token 3538: mov r10.w, l(0xFFFFFFFF)
        r10.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 3543: break
        break;
        // DXBC token 3544: default
        default:
        // DXBC token 3545: mov r10.w, l(0.000000)
        r10.w = ((uint4(0x00000000u)).xxxx).w;
        // DXBC token 3550: break
        break;
        // DXBC token 3551: endswitch
        }
        // DXBC token 3552: and r4.w, r4.w, r10.w
        r4.w = (((r4).wwww & (r10).wwww)).w;
        // DXBC token 3559: add r4.w, -r5.x, r4.w
        r4.w = (as_type<uint4>((-(as_type<float4>((r5).xxxx)) + as_type<float4>((r4).wwww)))).w;
        // DXBC token 3567: mad r4.x, r4.x, r4.w, r5.x
        r4.x = (as_type<uint4>((as_type<float4>((r4).xxxx) * as_type<float4>((r4).wwww) + as_type<float4>((r5).xxxx)))).x;
        // DXBC token 3576: mul r2.w, r2.w, r4.x
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r4).xxxx)))).w;
        // DXBC token 3583: else
        } else {
        // DXBC token 3584: mad r4.x, r10.z, r8.y, l(-0.750000)
        r4.x = (as_type<uint4>((as_type<float4>((r10).zzzz) * as_type<float4>((r8).yyyy) + as_type<float4>((uint4(0xbf400000u)).xxxx)))).x;
        // DXBC token 3593: mul r4.x, r4.x, l(4.000000)
        r4.x = (as_type<uint4>((as_type<float4>((r4).xxxx) * as_type<float4>((uint4(0x40800000u)).xxxx)))).x;
        // DXBC token 3600: add r5.w, l(1.000000), -cb0[r7.x + 5].w
        r5.w = (as_type<uint4>((as_type<float4>((uint4(0x3f800000u)).xxxx) + -(as_type<float4>((cb[5 + ((r7).xxxx).x]).wwww))))).w;
        // DXBC token 3611: mad r5.xw, r8.zzzw, cb0[r7.x + 5].zzzw, r5.zzzw
        r5.xw = (as_type<uint4>((as_type<float4>((r8).zzzw) * as_type<float4>((cb[5 + ((r7).xxxx).x]).zzzw) + as_type<float4>((r5).zzzw)))).xw;
        // DXBC token 3623: ftou r4.w, cb0[r7.x + 3].w
        r4.w = (dx_ftou(as_type<float4>((cb[3 + ((r7).xxxx).x]).wwww))).w;
        // DXBC token 3631: switch r4.w
        switch (((r4).wwww).x) {
        // DXBC token 3634: case l(0.000000)
        case 0u:
        // DXBC token 3637: sample_indexable(texture2d)(float,float,float,float) r7.z, r5.xwx, t9.yzxw, s0
        r7.z = (as_type<uint4>(t9.sample(s, (as_type<float4>((r5).xwxx)).xy).yzxw)).z;
        // DXBC token 3648: mov r7.w, l(0xFFFFFFFF)
        r7.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 3653: break
        break;
        // DXBC token 3654: case l(0.000000)
        case 1u:
        // DXBC token 3657: sample_indexable(texture2d)(float,float,float,float) r7.z, r5.xwx, t10.yzxw, s0
        r7.z = (as_type<uint4>(t10.sample(s, (as_type<float4>((r5).xwxx)).xy).yzxw)).z;
        // DXBC token 3668: mov r7.w, l(0xFFFFFFFF)
        r7.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 3673: break
        break;
        // DXBC token 3674: case l(0.000000)
        case 2u:
        // DXBC token 3677: sample_indexable(texture2d)(float,float,float,float) r7.z, r5.xwx, t11.yzxw, s0
        r7.z = (as_type<uint4>(t11.sample(s, (as_type<float4>((r5).xwxx)).xy).yzxw)).z;
        // DXBC token 3688: mov r7.w, l(0xFFFFFFFF)
        r7.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 3693: break
        break;
        // DXBC token 3694: default
        default:
        // DXBC token 3695: mov r7.w, l(0.000000)
        r7.w = ((uint4(0x00000000u)).xxxx).w;
        // DXBC token 3700: break
        break;
        // DXBC token 3701: endswitch
        }
        // DXBC token 3702: and r5.x, r7.z, r7.w
        r5.x = (((r7).zzzz & (r7).wwww)).x;
        // DXBC token 3709: switch r4.w
        switch (((r4).wwww).x) {
        // DXBC token 3712: case l(0.000000)
        case 0u:
        // DXBC token 3715: sample_indexable(texture2d)(float,float,float,float) r4.w, r10.xyx, t9.yzwx, s0
        r4.w = (as_type<uint4>(t9.sample(s, (as_type<float4>((r10).xyxx)).xy).yzwx)).w;
        // DXBC token 3726: mov r5.w, l(0xFFFFFFFF)
        r5.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 3731: break
        break;
        // DXBC token 3732: case l(0.000000)
        case 1u:
        // DXBC token 3735: sample_indexable(texture2d)(float,float,float,float) r4.w, r10.xyx, t10.yzwx, s0
        r4.w = (as_type<uint4>(t10.sample(s, (as_type<float4>((r10).xyxx)).xy).yzwx)).w;
        // DXBC token 3746: mov r5.w, l(0xFFFFFFFF)
        r5.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 3751: break
        break;
        // DXBC token 3752: case l(0.000000)
        case 2u:
        // DXBC token 3755: sample_indexable(texture2d)(float,float,float,float) r4.w, r10.xyx, t11.yzwx, s0
        r4.w = (as_type<uint4>(t11.sample(s, (as_type<float4>((r10).xyxx)).xy).yzwx)).w;
        // DXBC token 3766: mov r5.w, l(0xFFFFFFFF)
        r5.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 3771: break
        break;
        // DXBC token 3772: default
        default:
        // DXBC token 3773: mov r5.w, l(0.000000)
        r5.w = ((uint4(0x00000000u)).xxxx).w;
        // DXBC token 3778: break
        break;
        // DXBC token 3779: endswitch
        }
        // DXBC token 3780: and r4.w, r4.w, r5.w
        r4.w = (((r4).wwww & (r5).wwww)).w;
        // DXBC token 3787: add r4.w, -r5.x, r4.w
        r4.w = (as_type<uint4>((-(as_type<float4>((r5).xxxx)) + as_type<float4>((r4).wwww)))).w;
        // DXBC token 3795: mad r4.x, r4.x, r4.w, r5.x
        r4.x = (as_type<uint4>((as_type<float4>((r4).xxxx) * as_type<float4>((r4).wwww) + as_type<float4>((r5).xxxx)))).x;
        // DXBC token 3804: mul r2.w, r2.w, r4.x
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r4).xxxx)))).w;
        // DXBC token 3811: endif
        }
        // DXBC token 3812: endif
        }
        // DXBC token 3813: endif
        }
        // DXBC token 3814: else
        } else {
        // DXBC token 3815: eq r4.x, l(2.000000), cb0[r7.x + 4].z
        r4.x = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x40000000u)).xxxx) == as_type<float4>((cb[4 + ((r7).xxxx).x]).zzzz))).x;
        // DXBC token 3825: if_nz r4.x
        if (((r4).xxxx).x != 0u) {
        // DXBC token 3828: add r4.xw, l(1.000000, 0.000000, 0.000000, 1.000000), -cb0[r7.x + 5].zzzw
        r4.xw = (as_type<uint4>((as_type<float4>((uint4(0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u)).xyzw) + -(as_type<float4>((cb[5 + ((r7).xxxx).x]).zzzw))))).xw;
        // DXBC token 3842: div r5.x, cb0[0].x, cb0[r7.x + 4].w
        r5.x = (as_type<uint4>((as_type<float4>((cb[0]).xxxx) / as_type<float4>((cb[4 + ((r7).xxxx).x]).wwww)))).x;
        // DXBC token 3853: ge r5.w, r5.x, -r5.x
        r5.w = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r5).xxxx) >= -(as_type<float4>((r5).xxxx)))).w;
        // DXBC token 3861: movc r5.w, r5.w, l(1.000000), l(-1.000000)
        r5.w = (select((uint4(0xbf800000u)).xxxx, (uint4(0x3f800000u)).xxxx, (r5).wwww != uint4(0))).w;
        // DXBC token 3870: mul r5.x, r5.w, r5.x
        r5.x = (as_type<uint4>((as_type<float4>((r5).wwww) * as_type<float4>((r5).xxxx)))).x;
        // DXBC token 3877: frc r5.x, r5.x
        r5.x = (as_type<uint4>(fract(as_type<float4>((r5).xxxx)))).x;
        // DXBC token 3882: mul r7.z, r5.x, r5.w
        r7.z = (as_type<uint4>((as_type<float4>((r5).xxxx) * as_type<float4>((r5).wwww)))).z;
        // DXBC token 3889: lt r7.w, r7.z, l(0.500000)
        r7.w = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r7).zzzz) < as_type<float4>((uint4(0x3f000000u)).xxxx))).w;
        // DXBC token 3896: add r7.z, r7.z, r7.z
        r7.z = (as_type<uint4>((as_type<float4>((r7).zzzz) + as_type<float4>((r7).zzzz)))).z;
        // DXBC token 3903: mad r5.x, r5.w, r5.x, l(-0.500000)
        r5.x = (as_type<uint4>((as_type<float4>((r5).wwww) * as_type<float4>((r5).xxxx) + as_type<float4>((uint4(0xbf000000u)).xxxx)))).x;
        // DXBC token 3912: mad r5.x, -r5.x, l(2.000000), l(1.000000)
        r5.x = (as_type<uint4>((-(as_type<float4>((r5).xxxx)) * as_type<float4>((uint4(0x40000000u)).xxxx) + as_type<float4>((uint4(0x3f800000u)).xxxx)))).x;
        // DXBC token 3922: movc_sat r5.x, r7.w, r7.z, r5.x
        r5.x = (as_type<uint4>(dx_saturate(as_type<float4>(select((r5).xxxx, (r7).zzzz, (r7).wwww != uint4(0)))))).x;
        // DXBC token 3931: mad r5.w, r5.x, l(-2.000000), l(3.000000)
        r5.w = (as_type<uint4>((as_type<float4>((r5).xxxx) * as_type<float4>((uint4(0xc0000000u)).xxxx) + as_type<float4>((uint4(0x40400000u)).xxxx)))).w;
        // DXBC token 3940: mul r5.x, r5.x, r5.x
        r5.x = (as_type<uint4>((as_type<float4>((r5).xxxx) * as_type<float4>((r5).xxxx)))).x;
        // DXBC token 3947: mul r5.x, r5.x, r5.w
        r5.x = (as_type<uint4>((as_type<float4>((r5).xxxx) * as_type<float4>((r5).wwww)))).x;
        // DXBC token 3954: mul r4.xw, r4.xxxw, r5.x
        r4.xw = (as_type<uint4>((as_type<float4>((r4).xxxw) * as_type<float4>((r5).xxxx)))).xw;
        // DXBC token 3961: mad r4.xw, r8.zzzw, cb0[r7.x + 5].zzzw, r4.xxxw
        r4.xw = (as_type<uint4>((as_type<float4>((r8).zzzw) * as_type<float4>((cb[5 + ((r7).xxxx).x]).zzzw) + as_type<float4>((r4).xxxw)))).xw;
        // DXBC token 3973: ftou r5.x, cb0[r7.x + 3].w
        r5.x = (dx_ftou(as_type<float4>((cb[3 + ((r7).xxxx).x]).wwww))).x;
        // DXBC token 3981: switch r5.x
        switch (((r5).xxxx).x) {
        // DXBC token 3984: case l(0.000000)
        case 0u:
        // DXBC token 3987: sample_indexable(texture2d)(float,float,float,float) r5.x, r4.xwx, t9.xyzw, s0
        r5.x = (as_type<uint4>(t9.sample(s, (as_type<float4>((r4).xwxx)).xy).xyzw)).x;
        // DXBC token 3998: mov r5.w, l(0xFFFFFFFF)
        r5.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 4003: break
        break;
        // DXBC token 4004: case l(0.000000)
        case 1u:
        // DXBC token 4007: sample_indexable(texture2d)(float,float,float,float) r5.x, r4.xwx, t10.xyzw, s0
        r5.x = (as_type<uint4>(t10.sample(s, (as_type<float4>((r4).xwxx)).xy).xyzw)).x;
        // DXBC token 4018: mov r5.w, l(0xFFFFFFFF)
        r5.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 4023: break
        break;
        // DXBC token 4024: case l(0.000000)
        case 2u:
        // DXBC token 4027: sample_indexable(texture2d)(float,float,float,float) r5.x, r4.xwx, t11.xyzw, s0
        r5.x = (as_type<uint4>(t11.sample(s, (as_type<float4>((r4).xwxx)).xy).xyzw)).x;
        // DXBC token 4038: mov r5.w, l(0xFFFFFFFF)
        r5.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 4043: break
        break;
        // DXBC token 4044: default
        default:
        // DXBC token 4045: mov r5.w, l(0.000000)
        r5.w = ((uint4(0x00000000u)).xxxx).w;
        // DXBC token 4050: break
        break;
        // DXBC token 4051: endswitch
        }
        // DXBC token 4052: and r4.x, r5.x, r5.w
        r4.x = (((r5).xxxx & (r5).wwww)).x;
        // DXBC token 4059: mul r2.w, r2.w, r4.x
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r4).xxxx)))).w;
        // DXBC token 4066: else
        } else {
        // DXBC token 4067: eq r4.x, l(3.000000), cb0[r7.x + 4].z
        r4.x = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x40400000u)).xxxx) == as_type<float4>((cb[4 + ((r7).xxxx).x]).zzzz))).x;
        // DXBC token 4077: if_nz r4.x
        if (((r4).xxxx).x != 0u) {
        // DXBC token 4080: div r4.x, r0.z, cb0[r7.x + 4].w
        r4.x = (as_type<uint4>((as_type<float4>((r0).zzzz) / as_type<float4>((cb[4 + ((r7).xxxx).x]).wwww)))).x;
        // DXBC token 4090: mul r4.w, r4.x, l(6.283180)
        r4.w = (as_type<uint4>((as_type<float4>((r4).xxxx) * as_type<float4>((uint4(0x40c90fd0u)).xxxx)))).w;
        // DXBC token 4097: ge r4.w, r4.w, -r4.w
        r4.w = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r4).wwww) >= -(as_type<float4>((r4).wwww)))).w;
        // DXBC token 4105: movc r5.xw, r4.w, l(6.283180, 0.000000, 0.000000, 0.159155), l(-6.283180, 0.000000, 0.000000, -0.159155)
        r5.xw = (select((uint4(0xc0c90fd0u, 0x00000000u, 0x00000000u, 0xbe22f98cu)).xyzw, (uint4(0x40c90fd0u, 0x00000000u, 0x00000000u, 0x3e22f98cu)).xyzw, (r4).wwww != uint4(0))).xw;
        // DXBC token 4120: mul r4.x, r4.x, r5.w
        r4.x = (as_type<uint4>((as_type<float4>((r4).xxxx) * as_type<float4>((r5).wwww)))).x;
        // DXBC token 4127: frc r4.x, r4.x
        r4.x = (as_type<uint4>(fract(as_type<float4>((r4).xxxx)))).x;
        // DXBC token 4132: mul r4.x, r4.x, r5.x
        r4.x = (as_type<uint4>((as_type<float4>((r4).xxxx) * as_type<float4>((r5).xxxx)))).x;
        // DXBC token 4139: sincos null, r4.w, r4.x
        { float4 angle = as_type<float4>((r4).xxxx);
        r4.w = (as_type<uint4>(cos(angle))).w;
        }
        // DXBC token 4145: mov r10.x, -r4.w
        r10.x = (as_type<uint4>(-(as_type<float4>((r4).wwww)))).x;
        // DXBC token 4151: sincos r10.y, null, -r4.x
        { float4 angle = -(as_type<float4>((r4).xxxx));
        r10.y = (as_type<uint4>(sin(angle))).y;
        }
        // DXBC token 4158: add r4.xw, l(1.000000, 0.000000, 0.000000, 1.000000), -cb0[r7.x + 5].zzzw
        r4.xw = (as_type<uint4>((as_type<float4>((uint4(0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u)).xyzw) + -(as_type<float4>((cb[5 + ((r7).xxxx).x]).zzzw))))).xw;
        // DXBC token 4172: mul r4.xw, r4.xxxw, l(0.500000, 0.000000, 0.000000, 0.500000)
        r4.xw = (as_type<uint4>((as_type<float4>((r4).xxxw) * as_type<float4>((uint4(0x3f000000u, 0x00000000u, 0x00000000u, 0x3f000000u)).xyzw)))).xw;
        // DXBC token 4182: mad r4.xw, r4.xxxw, r10.xxxy, r4.xxxw
        r4.xw = (as_type<uint4>((as_type<float4>((r4).xxxw) * as_type<float4>((r10).xxxy) + as_type<float4>((r4).xxxw)))).xw;
        // DXBC token 4191: mad r4.xw, r8.zzzw, cb0[r7.x + 5].zzzw, r4.xxxw
        r4.xw = (as_type<uint4>((as_type<float4>((r8).zzzw) * as_type<float4>((cb[5 + ((r7).xxxx).x]).zzzw) + as_type<float4>((r4).xxxw)))).xw;
        // DXBC token 4203: ftou r5.x, cb0[r7.x + 3].w
        r5.x = (dx_ftou(as_type<float4>((cb[3 + ((r7).xxxx).x]).wwww))).x;
        // DXBC token 4211: switch r5.x
        switch (((r5).xxxx).x) {
        // DXBC token 4214: case l(0.000000)
        case 0u:
        // DXBC token 4217: sample_indexable(texture2d)(float,float,float,float) r5.x, r4.xwx, t9.xyzw, s0
        r5.x = (as_type<uint4>(t9.sample(s, (as_type<float4>((r4).xwxx)).xy).xyzw)).x;
        // DXBC token 4228: mov r5.w, l(0xFFFFFFFF)
        r5.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 4233: break
        break;
        // DXBC token 4234: case l(0.000000)
        case 1u:
        // DXBC token 4237: sample_indexable(texture2d)(float,float,float,float) r5.x, r4.xwx, t10.xyzw, s0
        r5.x = (as_type<uint4>(t10.sample(s, (as_type<float4>((r4).xwxx)).xy).xyzw)).x;
        // DXBC token 4248: mov r5.w, l(0xFFFFFFFF)
        r5.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 4253: break
        break;
        // DXBC token 4254: case l(0.000000)
        case 2u:
        // DXBC token 4257: sample_indexable(texture2d)(float,float,float,float) r5.x, r4.xwx, t11.xyzw, s0
        r5.x = (as_type<uint4>(t11.sample(s, (as_type<float4>((r4).xwxx)).xy).xyzw)).x;
        // DXBC token 4268: mov r5.w, l(0xFFFFFFFF)
        r5.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 4273: break
        break;
        // DXBC token 4274: default
        default:
        // DXBC token 4275: mov r5.w, l(0.000000)
        r5.w = ((uint4(0x00000000u)).xxxx).w;
        // DXBC token 4280: break
        break;
        // DXBC token 4281: endswitch
        }
        // DXBC token 4282: and r4.x, r5.x, r5.w
        r4.x = (((r5).xxxx & (r5).wwww)).x;
        // DXBC token 4289: mul r2.w, r2.w, r4.x
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r4).xxxx)))).w;
        // DXBC token 4296: else
        } else {
        // DXBC token 4297: eq r4.x, l(4.000000), cb0[r7.x + 4].z
        r4.x = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x40800000u)).xxxx) == as_type<float4>((cb[4 + ((r7).xxxx).x]).zzzz))).x;
        // DXBC token 4307: if_nz r4.x
        if (((r4).xxxx).x != 0u) {
        // DXBC token 4310: mad r4.xw, r8.zzzw, l(0.700000, 0.000000, 0.000000, 0.700000), l(-0.350000, 0.000000, 0.000000, -0.350000)
        r4.xw = (as_type<uint4>((as_type<float4>((r8).zzzw) * as_type<float4>((uint4(0x3f333333u, 0x00000000u, 0x00000000u, 0x3f333333u)).xyzw) + as_type<float4>((uint4(0xbeb33333u, 0x00000000u, 0x00000000u, 0xbeb33333u)).xyzw)))).xw;
        // DXBC token 4325: div r5.x, cb0[0].x, cb0[r7.x + 4].w
        r5.x = (as_type<uint4>((as_type<float4>((cb[0]).xxxx) / as_type<float4>((cb[4 + ((r7).xxxx).x]).wwww)))).x;
        // DXBC token 4336: sincos r5.x, r10.x, r5.x
        { float4 angle = as_type<float4>((r5).xxxx);
        r5.x = (as_type<uint4>(sin(angle))).x;
        r10.x = (as_type<uint4>(cos(angle))).x;
        }
        // DXBC token 4343: mov r11.x, -r5.x
        r11.x = (as_type<uint4>(-(as_type<float4>((r5).xxxx)))).x;
        // DXBC token 4349: mov r11.y, r10.x
        r11.y = ((r10).xxxx).y;
        // DXBC token 4354: dp2 r10.x, r11.yx, r4.xw
        r10.x = (as_type<uint4>(float4(dot((as_type<float4>((r11).yxyy)).xy, (as_type<float4>((r4).xwxx)).xy)))).x;
        // DXBC token 4361: mov r11.z, r5.x
        r11.z = ((r5).xxxx).z;
        // DXBC token 4366: dp2 r10.y, r11.zy, r4.xw
        r10.y = (as_type<uint4>(float4(dot((as_type<float4>((r11).zyzz)).xy, (as_type<float4>((r4).xwxx)).xy)))).y;
        // DXBC token 4373: add r4.xw, r10.xxxy, l(0.500000, 0.000000, 0.000000, 0.500000)
        r4.xw = (as_type<uint4>((as_type<float4>((r10).xxxy) + as_type<float4>((uint4(0x3f000000u, 0x00000000u, 0x00000000u, 0x3f000000u)).xyzw)))).xw;
        // DXBC token 4383: ftou r5.x, cb0[r7.x + 3].w
        r5.x = (dx_ftou(as_type<float4>((cb[3 + ((r7).xxxx).x]).wwww))).x;
        // DXBC token 4391: switch r5.x
        switch (((r5).xxxx).x) {
        // DXBC token 4394: case l(0.000000)
        case 0u:
        // DXBC token 4397: sample_indexable(texture2d)(float,float,float,float) r5.x, r4.xwx, t9.xyzw, s0
        r5.x = (as_type<uint4>(t9.sample(s, (as_type<float4>((r4).xwxx)).xy).xyzw)).x;
        // DXBC token 4408: mov r5.w, l(0xFFFFFFFF)
        r5.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 4413: break
        break;
        // DXBC token 4414: case l(0.000000)
        case 1u:
        // DXBC token 4417: sample_indexable(texture2d)(float,float,float,float) r5.x, r4.xwx, t10.xyzw, s0
        r5.x = (as_type<uint4>(t10.sample(s, (as_type<float4>((r4).xwxx)).xy).xyzw)).x;
        // DXBC token 4428: mov r5.w, l(0xFFFFFFFF)
        r5.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 4433: break
        break;
        // DXBC token 4434: case l(0.000000)
        case 2u:
        // DXBC token 4437: sample_indexable(texture2d)(float,float,float,float) r5.x, r4.xwx, t11.xyzw, s0
        r5.x = (as_type<uint4>(t11.sample(s, (as_type<float4>((r4).xwxx)).xy).xyzw)).x;
        // DXBC token 4448: mov r5.w, l(0xFFFFFFFF)
        r5.w = ((uint4(0xffffffffu)).xxxx).w;
        // DXBC token 4453: break
        break;
        // DXBC token 4454: default
        default:
        // DXBC token 4455: mov r5.w, l(0.000000)
        r5.w = ((uint4(0x00000000u)).xxxx).w;
        // DXBC token 4460: break
        break;
        // DXBC token 4461: endswitch
        }
        // DXBC token 4462: and r4.x, r5.x, r5.w
        r4.x = (((r5).xxxx & (r5).wwww)).x;
        // DXBC token 4469: mul r2.w, r2.w, r4.x
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r4).xxxx)))).w;
        // DXBC token 4476: else
        } else {
        // DXBC token 4477: eq r4.x, l(5.000000), cb0[r7.x + 4].z
        r4.x = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x40a00000u)).xxxx) == as_type<float4>((cb[4 + ((r7).xxxx).x]).zzzz))).x;
        // DXBC token 4487: if_nz r4.x
        if (((r4).xxxx).x != 0u) {
        // DXBC token 4490: div r4.x, r7.y, cb0[r7.x + 4].w
        r4.x = (as_type<uint4>((as_type<float4>((r7).yyyy) / as_type<float4>((cb[4 + ((r7).xxxx).x]).wwww)))).x;
        // DXBC token 4500: lt r4.w, r4.x, l(1.000000)
        r4.w = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r4).xxxx) < as_type<float4>((uint4(0x3f800000u)).xxxx))).w;
        // DXBC token 4507: if_nz r4.w
        if (((r4).wwww).x != 0u) {
        // DXBC token 4510: mad r4.x, r4.x, l(2.000000), l(-1.000000)
        r4.x = (as_type<uint4>((as_type<float4>((r4).xxxx) * as_type<float4>((uint4(0x40000000u)).xxxx) + as_type<float4>((uint4(0xbf800000u)).xxxx)))).x;
        // DXBC token 4519: ftou r4.w, cb0[r7.x + 3].w
        r4.w = (dx_ftou(as_type<float4>((cb[3 + ((r7).xxxx).x]).wwww))).w;
        // DXBC token 4527: switch r4.w
        switch (((r4).wwww).x) {
        // DXBC token 4530: case l(0.000000)
        case 0u:
        // DXBC token 4533: sample_indexable(texture2d)(float,float,float,float) r4.w, r8.zwz, t9.yzwx, s0
        r4.w = (as_type<uint4>(t9.sample(s, (as_type<float4>((r8).zwzz)).xy).yzwx)).w;
        // DXBC token 4544: mov r5.x, l(0xFFFFFFFF)
        r5.x = ((uint4(0xffffffffu)).xxxx).x;
        // DXBC token 4549: break
        break;
        // DXBC token 4550: case l(0.000000)
        case 1u:
        // DXBC token 4553: sample_indexable(texture2d)(float,float,float,float) r4.w, r8.zwz, t10.yzwx, s0
        r4.w = (as_type<uint4>(t10.sample(s, (as_type<float4>((r8).zwzz)).xy).yzwx)).w;
        // DXBC token 4564: mov r5.x, l(0xFFFFFFFF)
        r5.x = ((uint4(0xffffffffu)).xxxx).x;
        // DXBC token 4569: break
        break;
        // DXBC token 4570: case l(0.000000)
        case 2u:
        // DXBC token 4573: sample_indexable(texture2d)(float,float,float,float) r4.w, r8.zwz, t11.yzwx, s0
        r4.w = (as_type<uint4>(t11.sample(s, (as_type<float4>((r8).zwzz)).xy).yzwx)).w;
        // DXBC token 4584: mov r5.x, l(0xFFFFFFFF)
        r5.x = ((uint4(0xffffffffu)).xxxx).x;
        // DXBC token 4589: break
        break;
        // DXBC token 4590: default
        default:
        // DXBC token 4591: mov r5.x, l(0.000000)
        r5.x = ((uint4(0x00000000u)).xxxx).x;
        // DXBC token 4596: break
        break;
        // DXBC token 4597: endswitch
        }
        // DXBC token 4598: and r4.w, r4.w, r5.x
        r4.w = (((r4).wwww & (r5).xxxx)).w;
        // DXBC token 4605: add_sat r4.x, r4.x, r4.w
        r4.x = (as_type<uint4>(dx_saturate((as_type<float4>((r4).xxxx) + as_type<float4>((r4).wwww))))).x;
        // DXBC token 4612: mul r2.w, r2.w, r4.x
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r4).xxxx)))).w;
        // DXBC token 4619: endif
        }
        // DXBC token 4620: else
        } else {
        // DXBC token 4621: eq r4.x, l(6.000000), cb0[r7.x + 4].z
        r4.x = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x40c00000u)).xxxx) == as_type<float4>((cb[4 + ((r7).xxxx).x]).zzzz))).x;
        // DXBC token 4631: if_nz r4.x
        if (((r4).xxxx).x != 0u) {
        // DXBC token 4634: div r4.x, r7.y, cb0[r7.x + 4].w
        r4.x = (as_type<uint4>((as_type<float4>((r7).yyyy) / as_type<float4>((cb[4 + ((r7).xxxx).x]).wwww)))).x;
        // DXBC token 4644: lt r4.w, r4.x, l(1.000000)
        r4.w = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r4).xxxx) < as_type<float4>((uint4(0x3f800000u)).xxxx))).w;
        // DXBC token 4651: if_nz r4.w
        if (((r4).wwww).x != 0u) {
        // DXBC token 4654: add r4.x, -r4.x, l(1.000000)
        r4.x = (as_type<uint4>((-(as_type<float4>((r4).xxxx)) + as_type<float4>((uint4(0x3f800000u)).xxxx)))).x;
        // DXBC token 4662: mad r4.x, r4.x, l(2.000000), l(-1.000000)
        r4.x = (as_type<uint4>((as_type<float4>((r4).xxxx) * as_type<float4>((uint4(0x40000000u)).xxxx) + as_type<float4>((uint4(0xbf800000u)).xxxx)))).x;
        // DXBC token 4671: ftou r4.w, cb0[r7.x + 3].w
        r4.w = (dx_ftou(as_type<float4>((cb[3 + ((r7).xxxx).x]).wwww))).w;
        // DXBC token 4679: switch r4.w
        switch (((r4).wwww).x) {
        // DXBC token 4682: case l(0.000000)
        case 0u:
        // DXBC token 4685: sample_indexable(texture2d)(float,float,float,float) r4.w, r8.zwz, t9.yzwx, s0
        r4.w = (as_type<uint4>(t9.sample(s, (as_type<float4>((r8).zwzz)).xy).yzwx)).w;
        // DXBC token 4696: mov r5.x, l(0xFFFFFFFF)
        r5.x = ((uint4(0xffffffffu)).xxxx).x;
        // DXBC token 4701: break
        break;
        // DXBC token 4702: case l(0.000000)
        case 1u:
        // DXBC token 4705: sample_indexable(texture2d)(float,float,float,float) r4.w, r8.zwz, t10.yzwx, s0
        r4.w = (as_type<uint4>(t10.sample(s, (as_type<float4>((r8).zwzz)).xy).yzwx)).w;
        // DXBC token 4716: mov r5.x, l(0xFFFFFFFF)
        r5.x = ((uint4(0xffffffffu)).xxxx).x;
        // DXBC token 4721: break
        break;
        // DXBC token 4722: case l(0.000000)
        case 2u:
        // DXBC token 4725: sample_indexable(texture2d)(float,float,float,float) r4.w, r8.zwz, t11.yzwx, s0
        r4.w = (as_type<uint4>(t11.sample(s, (as_type<float4>((r8).zwzz)).xy).yzwx)).w;
        // DXBC token 4736: mov r5.x, l(0xFFFFFFFF)
        r5.x = ((uint4(0xffffffffu)).xxxx).x;
        // DXBC token 4741: break
        break;
        // DXBC token 4742: default
        default:
        // DXBC token 4743: mov r5.x, l(0.000000)
        r5.x = ((uint4(0x00000000u)).xxxx).x;
        // DXBC token 4748: break
        break;
        // DXBC token 4749: endswitch
        }
        // DXBC token 4750: and r4.w, r4.w, r5.x
        r4.w = (((r4).wwww & (r5).xxxx)).w;
        // DXBC token 4757: add_sat r4.x, r4.x, r4.w
        r4.x = (as_type<uint4>(dx_saturate((as_type<float4>((r4).xxxx) + as_type<float4>((r4).wwww))))).x;
        // DXBC token 4764: mul r2.w, r2.w, r4.x
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r4).xxxx)))).w;
        // DXBC token 4771: else
        } else {
        // DXBC token 4772: mov r2.w, l(0.000000)
        r2.w = ((uint4(0x00000000u)).xxxx).w;
        // DXBC token 4777: endif
        }
        // DXBC token 4778: endif
        }
        // DXBC token 4779: endif
        }
        // DXBC token 4780: endif
        }
        // DXBC token 4781: endif
        }
        // DXBC token 4782: endif
        }
        // DXBC token 4783: endif
        }
        // DXBC token 4784: endif
        }
        // DXBC token 4785: endif
        }
        // DXBC token 4786: ne r4.x, r2.w, l(1.000000)
        r4.x = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r2).wwww) != as_type<float4>((uint4(0x3f800000u)).xxxx))).x;
        // DXBC token 4793: add r10.xyzw, -r6.xyzw, r9.xyzw
        r10.xyzw = (as_type<uint4>((-(as_type<float4>((r6).xyzw)) + as_type<float4>((r9).xyzw)))).xyzw;
        // DXBC token 4801: mad r10.xyzw, r2.w, r10.xyzw, r6.xyzw
        r10.xyzw = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r10).xyzw) + as_type<float4>((r6).xyzw)))).xyzw;
        // DXBC token 4810: movc r9.xyzw, r4.x, r10.xyzw, r9.xyzw
        r9.xyzw = (select((r9).xyzw, (r10).xyzw, (r4).xxxx != uint4(0))).xyzw;
        // DXBC token 4819: else
        } else {
        // DXBC token 4820: mov r9.xyzw, r6.xyzw
        r9.xyzw = ((r6).xyzw).xyzw;
        // DXBC token 4825: endif
        }
        // DXBC token 4826: else
        } else {
        // DXBC token 4827: mov r9.xyzw, r6.xyzw
        r9.xyzw = ((r6).xyzw).xyzw;
        // DXBC token 4832: mov r2.x, l(0xFFFFFFFF)
        r2.x = ((uint4(0xffffffffu)).xxxx).x;
        // DXBC token 4837: endif
        }
        // DXBC token 4838: or r2.x, r8.x, r2.x
        r2.x = (((r8).xxxx | (r2).xxxx)).x;
        // DXBC token 4845: else
        } else {
        // DXBC token 4846: ieq r2.w, l(2), cb0[r7.x + 1].x
        r2.w = (select(uint4(0), uint4(0xffffffffu), as_type<int4>((uint4(0x00000002u)).xxxx) == as_type<int4>((cb[1 + ((r7).xxxx).x]).xxxx))).w;
        // DXBC token 4856: if_nz r2.w
        if (((r2).wwww).x != 0u) {
        // DXBC token 4859: add r2.w, -v0.y, cb0[r7.x + 2].y
        r2.w = (as_type<uint4>((-(as_type<float4>((v0).yyyy)) + as_type<float4>((cb[2 + ((r7).xxxx).x]).yyyy)))).w;
        // DXBC token 4870: lt r4.x, l(0.000000), r2.w
        r4.x = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x00000000u)).xxxx) < as_type<float4>((r2).wwww))).x;
        // DXBC token 4877: if_nz r4.x
        if (((r4).xxxx).x != 0u) {
        // DXBC token 4880: add r4.x, v0.x, -cb0[r7.x + 2].x
        r4.x = (as_type<uint4>((as_type<float4>((v0).xxxx) + -(as_type<float4>((cb[2 + ((r7).xxxx).x]).xxxx))))).x;
        // DXBC token 4891: lt r4.w, |r4.x|, cb0[r7.x + 1].w
        r4.w = (select(uint4(0), uint4(0xffffffffu), abs(as_type<float4>((r4).xxxx)) < as_type<float4>((cb[1 + ((r7).xxxx).x]).wwww))).w;
        // DXBC token 4902: if_nz r4.w
        if (((r4).wwww).x != 0u) {
        // DXBC token 4905: add r4.w, cb0[0].x, -cb0[r7.x + 1].y
        r4.w = (as_type<uint4>((as_type<float4>((cb[0]).xxxx) + -(as_type<float4>((cb[1 + ((r7).xxxx).x]).yyyy))))).w;
        // DXBC token 4917: div r4.w, r4.w, cb0[r7.x + 1].z
        r4.w = (as_type<uint4>((as_type<float4>((r4).wwww) / as_type<float4>((cb[1 + ((r7).xxxx).x]).zzzz)))).w;
        // DXBC token 4927: lt r5.x, r4.w, l(1.000000)
        r5.x = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r4).wwww) < as_type<float4>((uint4(0x3f800000u)).xxxx))).x;
        // DXBC token 4934: if_nz r5.x
        if (((r5).xxxx).x != 0u) {
        // DXBC token 4937: add r4.w, r4.w, l(-1.000000)
        r4.w = (as_type<uint4>((as_type<float4>((r4).wwww) + as_type<float4>((uint4(0xbf800000u)).xxxx)))).w;
        // DXBC token 4944: mul r5.x, r4.w, r4.w
        r5.x = (as_type<uint4>((as_type<float4>((r4).wwww) * as_type<float4>((r4).wwww)))).x;
        // DXBC token 4951: mad r7.yzw, r5.x, r4.w, l(0.000000, 1.000000, 0.150000, 0.050000)
        r7.yzw = (as_type<uint4>((as_type<float4>((r5).xxxx) * as_type<float4>((r4).wwww) + as_type<float4>((uint4(0x00000000u, 0x3f800000u, 0x3e199998u, 0x3d4cccd0u)).xyzw)))).yzw;
        // DXBC token 4963: add r4.w, -cb0[r7.x + 2].z, cb0[r7.x + 2].y
        r4.w = (as_type<uint4>((-(as_type<float4>((cb[2 + ((r7).xxxx).x]).zzzz)) + as_type<float4>((cb[2 + ((r7).xxxx).x]).yyyy)))).w;
        // DXBC token 4977: mad r8.y, -r4.w, r7.y, cb0[r7.x + 2].y
        r8.y = (as_type<uint4>((-(as_type<float4>((r4).wwww)) * as_type<float4>((r7).yyyy) + as_type<float4>((cb[2 + ((r7).xxxx).x]).yyyy)))).y;
        // DXBC token 4990: add r4.w, -r8.y, v0.y
        r4.w = (as_type<uint4>((-(as_type<float4>((r8).yyyy)) + as_type<float4>((v0).yyyy)))).w;
        // DXBC token 4998: lt r5.x, |r4.w|, cb0[r7.x + 1].w
        r5.x = (select(uint4(0), uint4(0xffffffffu), abs(as_type<float4>((r4).wwww)) < as_type<float4>((cb[1 + ((r7).xxxx).x]).wwww))).x;
        // DXBC token 5009: mov r8.x, cb0[r7.x + 2].x
        r8.x = ((cb[2 + ((r7).xxxx).x]).xxxx).x;
        // DXBC token 5017: add r8.xy, -r8.xy, v0.xy
        r8.xy = (as_type<uint4>((-(as_type<float4>((r8).xyxx)) + as_type<float4>((v0).xyxx)))).xy;
        // DXBC token 5025: dp2 r5.w, r8.xy, r8.xy
        r5.w = (as_type<uint4>(float4(dot((as_type<float4>((r8).xyxx)).xy, (as_type<float4>((r8).xyxx)).xy)))).w;
        // DXBC token 5032: sqrt r5.w, r5.w
        r5.w = (as_type<uint4>(sqrt(as_type<float4>((r5).wwww)))).w;
        // DXBC token 5037: div r5.w, r5.w, cb0[r7.x + 1].w
        r5.w = (as_type<uint4>((as_type<float4>((r5).wwww) / as_type<float4>((cb[1 + ((r7).xxxx).x]).wwww)))).w;
        // DXBC token 5047: add r5.w, -r5.w, l(1.000000)
        r5.w = (as_type<uint4>((-(as_type<float4>((r5).wwww)) + as_type<float4>((uint4(0x3f800000u)).xxxx)))).w;
        // DXBC token 5055: mul r5.w, r5.w, l(0.800000)
        r5.w = (as_type<uint4>((as_type<float4>((r5).wwww) * as_type<float4>((uint4(0x3f4ccccdu)).xxxx)))).w;
        // DXBC token 5062: and r5.x, r5.w, r5.x
        r5.x = (((r5).wwww & (r5).xxxx)).x;
        // DXBC token 5069: lt r5.w, l(0.000000), r4.w
        r5.w = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x00000000u)).xxxx) < as_type<float4>((r4).wwww))).w;
        // DXBC token 5076: lt r8.x, r4.w, cb0[r7.x + 3].x
        r8.x = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r4).wwww) < as_type<float4>((cb[3 + ((r7).xxxx).x]).xxxx))).x;
        // DXBC token 5086: and r5.w, r5.w, r8.x
        r5.w = (((r5).wwww & (r8).xxxx)).w;
        // DXBC token 5093: lt r8.xy, l(0.850000, 0.950000, 0.000000, 0.000000), r7.y
        r8.xy = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x3f59999au, 0x3f733333u, 0x00000000u, 0x00000000u)).xyzw) < as_type<float4>((r7).yyyy))).xy;
        // DXBC token 5103: mul r7.y, r4.w, r7.z
        r7.y = (as_type<uint4>((as_type<float4>((r4).wwww) * as_type<float4>((r7).zzzz)))).y;
        // DXBC token 5110: mad r7.y, r7.y, l(6.666667), r4.w
        r7.y = (as_type<uint4>((as_type<float4>((r7).yyyy) * as_type<float4>((uint4(0x40d55555u)).xxxx) + as_type<float4>((r4).wwww)))).y;
        // DXBC token 5119: min r7.y, r7.y, cb0[r7.x + 3].x
        r7.y = (as_type<uint4>(min(as_type<float4>((r7).yyyy), as_type<float4>((cb[3 + ((r7).xxxx).x]).xxxx)))).y;
        // DXBC token 5129: movc r4.w, r8.x, r7.y, r4.w
        r4.w = (select((r4).wwww, (r7).yyyy, (r8).xxxx != uint4(0))).w;
        // DXBC token 5138: div r4.w, r4.w, cb0[r7.x + 3].x
        r4.w = (as_type<uint4>((as_type<float4>((r4).wwww) / as_type<float4>((cb[3 + ((r7).xxxx).x]).xxxx)))).w;
        // DXBC token 5148: div r4.x, |r4.x|, cb0[r7.x + 1].w
        r4.x = (as_type<uint4>((abs(as_type<float4>((r4).xxxx)) / as_type<float4>((cb[1 + ((r7).xxxx).x]).wwww)))).x;
        // DXBC token 5159: add r4.xw, -r4.xxxw, l(1.000000, 0.000000, 0.000000, 1.000000)
        r4.xw = (as_type<uint4>((-(as_type<float4>((r4).xxxw)) + as_type<float4>((uint4(0x3f800000u, 0x00000000u, 0x00000000u, 0x3f800000u)).xyzw)))).xw;
        // DXBC token 5170: mul r4.x, r4.x, r4.w
        r4.x = (as_type<uint4>((as_type<float4>((r4).xxxx) * as_type<float4>((r4).wwww)))).x;
        // DXBC token 5177: mul r4.x, r4.x, r4.x
        r4.x = (as_type<uint4>((as_type<float4>((r4).xxxx) * as_type<float4>((r4).xxxx)))).x;
        // DXBC token 5184: max r4.x, r4.x, r5.x
        r4.x = (as_type<uint4>(max(as_type<float4>((r4).xxxx), as_type<float4>((r5).xxxx)))).x;
        // DXBC token 5191: movc r4.x, r5.w, r4.x, r5.x
        r4.x = (select((r5).xxxx, (r4).xxxx, (r5).wwww != uint4(0))).x;
        // DXBC token 5200: lt r4.w, r2.w, l(5.000000)
        r4.w = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r2).wwww) < as_type<float4>((uint4(0x40a00000u)).xxxx))).w;
        // DXBC token 5207: mul r2.w, r2.w, r4.x
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r4).xxxx)))).w;
        // DXBC token 5214: mul r2.w, r2.w, l(0.200000)
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((uint4(0x3e4ccccdu)).xxxx)))).w;
        // DXBC token 5221: movc r2.w, r4.w, r2.w, r4.x
        r2.w = (select((r4).xxxx, (r2).wwww, (r4).wwww != uint4(0))).w;
        // DXBC token 5230: mad r4.x, -r7.w, l(20.000000), l(1.000000)
        r4.x = (as_type<uint4>((-(as_type<float4>((r7).wwww)) * as_type<float4>((uint4(0x41a00000u)).xxxx) + as_type<float4>((uint4(0x3f800000u)).xxxx)))).x;
        // DXBC token 5240: mul r4.x, r2.w, r4.x
        r4.x = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r4).xxxx)))).x;
        // DXBC token 5247: movc r2.w, r8.y, r4.x, r2.w
        r2.w = (select((r2).wwww, (r4).xxxx, (r8).yyyy != uint4(0))).w;
        // DXBC token 5256: lt r4.x, l(0.000000), r2.w
        r4.x = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x00000000u)).xxxx) < as_type<float4>((r2).wwww))).x;
        // DXBC token 5263: if_nz r4.x
        if (((r4).xxxx).x != 0u) {
        // DXBC token 5266: mul r2.w, r2.w, r2.w
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r2).wwww)))).w;
        // DXBC token 5273: mov r3.xyz, cb0[r7.x + 3].yzw
        r3.xyz = ((cb[3 + ((r7).xxxx).x]).yzwy).xyz;
        // DXBC token 5281: add r8.xyzw, r3.xyzw, -r6.xyzw
        r8.xyzw = (as_type<uint4>((as_type<float4>((r3).xyzw) + -(as_type<float4>((r6).xyzw))))).xyzw;
        // DXBC token 5289: mad r6.xyzw, r2.w, r8.xyzw, r6.xyzw
        r6.xyzw = (as_type<uint4>((as_type<float4>((r2).wwww) * as_type<float4>((r8).xyzw) + as_type<float4>((r6).xyzw)))).xyzw;
        // DXBC token 5298: endif
        }
        // DXBC token 5299: endif
        }
        // DXBC token 5300: endif
        }
        // DXBC token 5301: endif
        }
        // DXBC token 5302: else
        } else {
        // DXBC token 5303: ieq r2.w, l(3), cb0[r7.x + 1].x
        r2.w = (select(uint4(0), uint4(0xffffffffu), as_type<int4>((uint4(0x00000003u)).xxxx) == as_type<int4>((cb[1 + ((r7).xxxx).x]).xxxx))).w;
        // DXBC token 5313: if_nz r2.w
        if (((r2).wwww).x != 0u) {
        // DXBC token 5316: add r3.xy, v0.xy, -cb0[r7.x + 2].xy
        r3.xy = (as_type<uint4>((as_type<float4>((v0).xyxx) + -(as_type<float4>((cb[2 + ((r7).xxxx).x]).xyxx))))).xy;
        // DXBC token 5327: sincos r4.x, r5.x, cb0[r7.x + 1].w
        { float4 angle = as_type<float4>((cb[1 + ((r7).xxxx).x]).wwww);
        r4.x = (as_type<uint4>(sin(angle))).x;
        r5.x = (as_type<uint4>(cos(angle))).x;
        }
        // DXBC token 5337: mov r8.x, -r4.x
        r8.x = (as_type<uint4>(-(as_type<float4>((r4).xxxx)))).x;
        // DXBC token 5343: mov r8.y, r5.x
        r8.y = ((r5).xxxx).y;
        // DXBC token 5348: dp2 r10.x, r8.yx, r3.xy
        r10.x = (as_type<uint4>(float4(dot((as_type<float4>((r8).yxyy)).xy, (as_type<float4>((r3).xyxx)).xy)))).x;
        // DXBC token 5355: mov r8.z, r4.x
        r8.z = ((r4).xxxx).z;
        // DXBC token 5360: dp2 r10.y, r8.zy, r3.xy
        r10.y = (as_type<uint4>(float4(dot((as_type<float4>((r8).zyzz)).xy, (as_type<float4>((r3).xyxx)).xy)))).y;
        // DXBC token 5367: mul r3.xy, r10.xy, r10.xy
        r3.xy = (as_type<uint4>((as_type<float4>((r10).xyxx) * as_type<float4>((r10).xyxx)))).xy;
        // DXBC token 5374: mul r4.xw, cb0[r7.x + 2].zzzw, cb0[r7.x + 2].zzzw
        r4.xw = (as_type<uint4>((as_type<float4>((cb[2 + ((r7).xxxx).x]).zzzw) * as_type<float4>((cb[2 + ((r7).xxxx).x]).zzzw)))).xw;
        // DXBC token 5387: div r3.xy, r3.xy, r4.xw
        r3.xy = (as_type<uint4>((as_type<float4>((r3).xyxx) / as_type<float4>((r4).xwxx)))).xy;
        // DXBC token 5394: add r2.w, r3.y, r3.x
        r2.w = (as_type<uint4>((as_type<float4>((r3).yyyy) + as_type<float4>((r3).xxxx)))).w;
        // DXBC token 5401: ge r3.x, l(1.000000), r2.w
        r3.x = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((uint4(0x3f800000u)).xxxx) >= as_type<float4>((r2).wwww))).x;
        // DXBC token 5408: if_nz r3.x
        if (((r3).xxxx).x != 0u) {
        // DXBC token 5411: mul r3.x, cb0[0].x, cb0[r7.x + 3].y
        r3.x = (as_type<uint4>((as_type<float4>((cb[0]).xxxx) * as_type<float4>((cb[3 + ((r7).xxxx).x]).yyyy)))).x;
        // DXBC token 5422: mad r3.yz, v0.xxy, l(0.000000, 0.000521, 0.000926, 0.000000), r3.x
        r3.yz = (as_type<uint4>((as_type<float4>((v0).xxyx) * as_type<float4>((uint4(0x00000000u, 0x3a088889u, 0x3a72b9d6u, 0x00000000u)).xyzw) + as_type<float4>((r3).xxxx)))).yz;
        // DXBC token 5434: ge r4.xw, r3.yyyz, -r3.yyyz
        r4.xw = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r3).yyyz) >= -(as_type<float4>((r3).yyyz)))).xw;
        // DXBC token 5442: frc r3.yz, |r3.yyz|
        r3.yz = (as_type<uint4>(fract(abs(as_type<float4>((r3).yyzy))))).yz;
        // DXBC token 5448: movc r3.yz, r4.xxw, r3.yyz, -r3.yyz
        r3.yz = (select(as_type<uint4>(-(as_type<float4>((r3).yyzy))), (r3).yyzy, (r4).xxwx != uint4(0))).yz;
        // DXBC token 5458: mad r4.xw, v0.xxxy, l(0.000694, 0.000000, 0.000000, 0.001234), -r3.x
        r4.xw = (as_type<uint4>((as_type<float4>((v0).xxxy) * as_type<float4>((uint4(0x3a35ffbau, 0x00000000u, 0x00000000u, 0x3aa1c6deu)).xyzw) + -(as_type<float4>((r3).xxxx))))).xw;
        // DXBC token 5471: ge r5.xw, r4.xxxw, -r4.xxxw
        r5.xw = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r4).xxxw) >= -(as_type<float4>((r4).xxxw)))).xw;
        // DXBC token 5479: frc r4.xw, |r4.xxxw|
        r4.xw = (as_type<uint4>(fract(abs(as_type<float4>((r4).xxxw))))).xw;
        // DXBC token 5485: movc r4.xw, r5.xxxw, r4.xxxw, -r4.xxxw
        r4.xw = (select(as_type<uint4>(-(as_type<float4>((r4).xxxw))), (r4).xxxw, (r5).xxxw != uint4(0))).xw;
        // DXBC token 5495: sample_indexable(texture2d)(float,float,float,float) r3.xyz, r3.yzy, t12.xyzw, s0
        r3.xyz = (as_type<uint4>(t12.sample(s, (as_type<float4>((r3).yzyy)).xy).xyzw)).xyz;
        // DXBC token 5506: mad r3.xyz, r3.xyz, l(2.000000, 2.000000, 2.000000, 0.000000), l(-1.000000, -1.000000, -1.000000, 0.000000)
        r3.xyz = (as_type<uint4>((as_type<float4>((r3).xyzx) * as_type<float4>((uint4(0x40000000u, 0x40000000u, 0x40000000u, 0x00000000u)).xyzw) + as_type<float4>((uint4(0xbf800000u, 0xbf800000u, 0xbf800000u, 0x00000000u)).xyzw)))).xyz;
        // DXBC token 5521: sample_indexable(texture2d)(float,float,float,float) r4.xw, r4.xwx, t12.xzwy, s0
        r4.xw = (as_type<uint4>(t12.sample(s, (as_type<float4>((r4).xwxx)).xy).xzwy)).xw;
        // DXBC token 5532: mad r4.xw, r4.xxxw, l(2.000000, 0.000000, 0.000000, 2.000000), r3.xxxy
        r4.xw = (as_type<uint4>((as_type<float4>((r4).xxxw) * as_type<float4>((uint4(0x40000000u, 0x00000000u, 0x00000000u, 0x40000000u)).xyzw) + as_type<float4>((r3).xxxy)))).xw;
        // DXBC token 5544: add r3.xy, r4.xw, l(-1.000000, -1.000000, 0.000000, 0.000000)
        r3.xy = (as_type<uint4>((as_type<float4>((r4).xwxx) + as_type<float4>((uint4(0xbf800000u, 0xbf800000u, 0x00000000u, 0x00000000u)).xyzw)))).xy;
        // DXBC token 5554: dp3 r3.z, r3.xyz, r3.xyz
        r3.z = (as_type<uint4>(float4(dot((as_type<float4>((r3).xyzx)).xyz, (as_type<float4>((r3).xyzx)).xyz)))).z;
        // DXBC token 5561: rsq r3.z, r3.z
        r3.z = (as_type<uint4>(rsqrt(as_type<float4>((r3).zzzz)))).z;
        // DXBC token 5566: mul r3.xy, r3.z, r3.xy
        r3.xy = (as_type<uint4>((as_type<float4>((r3).zzzz) * as_type<float4>((r3).xyxx)))).xy;
        // DXBC token 5573: add r2.w, -r2.w, l(1.000000)
        r2.w = (as_type<uint4>((-(as_type<float4>((r2).wwww)) + as_type<float4>((uint4(0x3f800000u)).xxxx)))).w;
        // DXBC token 5581: lt r3.z, r2.w, cb0[r7.x + 3].z
        r3.z = (select(uint4(0), uint4(0xffffffffu), as_type<float4>((r2).wwww) < as_type<float4>((cb[3 + ((r7).xxxx).x]).zzzz))).z;
        // DXBC token 5591: div r2.w, r2.w, cb0[r7.x + 3].z
        r2.w = (as_type<uint4>((as_type<float4>((r2).wwww) / as_type<float4>((cb[3 + ((r7).xxxx).x]).zzzz)))).w;
        // DXBC token 5601: movc r2.w, r3.z, r2.w, l(1.000000)
        r2.w = (select((uint4(0x3f800000u)).xxxx, (r2).wwww, (r3).zzzz != uint4(0))).w;
        // DXBC token 5610: mul r3.xy, r3.xy, cb0[r7.x + 3].x
        r3.xy = (as_type<uint4>((as_type<float4>((r3).xyxx) * as_type<float4>((cb[3 + ((r7).xxxx).x]).xxxx)))).xy;
        // DXBC token 5620: mad r3.xy, r3.xy, r2.w, r0.xy
        r3.xy = (as_type<uint4>((as_type<float4>((r3).xyxx) * as_type<float4>((r2).wwww) + as_type<float4>((r0).xyxx)))).xy;
        // DXBC token 5629: sample_indexable(texture2d)(float,float,float,float) r6.xyzw, r3.xyx, t0.xyzw, s0
        r6.xyzw = (as_type<uint4>(t0.sample(s, (as_type<float4>((r3).xyxx)).xy).xyzw)).xyzw;
        // DXBC token 5640: endif
        }
        // DXBC token 5641: endif
        }
        // DXBC token 5642: endif
        }
        // DXBC token 5643: mov r2.x, l(0.000000)
        r2.x = ((uint4(0x00000000u)).xxxx).x;
        // DXBC token 5648: endif
        }
        // DXBC token 5649: movc r6.xyzw, r2.x, r9.xyzw, r6.xyzw
        r6.xyzw = (select((r6).xyzw, (r9).xyzw, (r2).xxxx != uint4(0))).xyzw;
        // DXBC token 5658: endif
        }
        // DXBC token 5659: iadd r0.w, r0.w, l(1)
        r0.w = (((r0).wwww + (uint4(0x00000001u)).xxxx)).w;
        // DXBC token 5666: endloop
        }
        // DXBC token 5667: mov o0.xyzw, r6.xyzw
        o0.xyzw = ((r6).xyzw).xyzw;
        // DXBC token 5672: ret
        return as_type<float4>(o0);
    }
    """
}

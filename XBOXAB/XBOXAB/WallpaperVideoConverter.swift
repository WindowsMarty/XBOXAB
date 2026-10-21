import AVFoundation
import CoreVideo
import Metal
import VideoToolbox

/// Renderer state stays on its owning actor. Encoder backpressure suspends the
/// task instead of spinning a CPU or blocking the thread with sleep().
@MainActor
enum WallpaperVideoConverter {
    static func convert(folder: URL, progress: (Double) -> Void) async throws -> URL {
        let project = WallpaperProject()
        try project.load(from: folder, loadPreviewImages: false)
        // Preserve gradient precision before HEVC Main10 encoding. The old
        // BGRA8 intermediate discarded precision before the encoder saw it.
        let renderer = try ProjectMetalRenderer(project: project, pixelFormat: .rgba16Float)
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("XBOXAB/Converted/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(folder.lastPathComponent).appendingPathExtension("mp4")
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: directory) } }
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 100_000_000,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                AVVideoExpectedSourceFrameRateKey: 60
            ]
        ])
        guard writer.canAdd(input) else { throw failure("无法创建视频编码器") }
        let attributes = CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_64RGBAHalf),
            size: CVImageSize(width: 1920, height: 1080), compatibility: [.metalTexture])
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        do {
            var cache: CVMetalTextureCache?
            guard CVMetalTextureCacheCreate(nil, nil, renderer.device, nil, &cache) == kCVReturnSuccess,
                  let cache else { throw failure("无法创建视频纹理缓存") }
            let fps: Int32 = 60
            let count = max(1, Int(ceil(renderer.duration * Double(fps))))
            var lastProgressUpdate = DispatchTime.now().uptimeNanoseconds
            for frame in 0..<count {
                try Task.checkCancellation()
                let readOnlyBuffer = try autoreleasepool { () throws -> CVReadOnlyPixelBuffer in
                    guard let pool = receiver.pixelBufferPool else { throw failure("无法创建视频帧池") }
                    let pixelBuffer = try pool.makeMutablePixelBuffer()
                    var image: CVMetalTexture?
                    let status = pixelBuffer.withUnsafeBuffer { rawBuffer in
                        CVMetalTextureCacheCreateTextureFromImage(nil, cache, rawBuffer, nil,
                            .rgba16Float, 1920, 1080, 0, &image)
                    }
                    guard status == kCVReturnSuccess,
                          let image, let texture = CVMetalTextureGetTexture(image) else {
                        throw failure("无法创建视频帧纹理")
                    }
                    try renderer.render(to: texture, at: Double(frame) / Double(fps), waitUntilCompleted: true)
                    // Transfer ownership only after the GPU has finished writing.
                    return CVReadOnlyPixelBuffer(pixelBuffer)
                }
                try await receiver.append(readOnlyBuffer, with: CMTime(value: Int64(frame), timescale: fps))
                let now = DispatchTime.now().uptimeNanoseconds
                if now - lastProgressUpdate >= 33_000_000 || frame == count - 1 {
                    progress(Double(frame + 1) / Double(count))
                    lastProgressUpdate = now
                }
                // Keep cancellation and UI responsive without delaying each frame.
                await Task.yield()
            }
            writer.endSession(atSourceTime: CMTime(seconds: renderer.duration, preferredTimescale: 60000))
            receiver.finish()
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? failure("视频转换失败") }
            succeeded = true
            return output
        } catch {
            writer.cancelWriting()
            throw error
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "WallpaperVideoConverter", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

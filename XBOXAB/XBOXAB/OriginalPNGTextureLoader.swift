import Foundation
import Metal
import zlib

/// PNG samples stay unassociated with alpha and are never passed through ColorSync.
/// Matches the original WIC loader's supported PNG format conversions and sRGB flags.
enum OriginalPNGTextureLoader {
    private struct PNGError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The input buffer must remain pinned until close(). Only one PNG scanline
    /// is inflated at a time; the stream never owns a full unfiltered image copy.
    private struct PNGInflator {
        private let stream: UnsafeMutablePointer<z_stream>
        private let input: UnsafeBufferPointer<UInt8>
        private var inputOffset = 0
        private var outputCount = 0
        private var ended = false

        init(input: UnsafeBufferPointer<UInt8>) throws {
            self.input = input
            stream = .allocate(capacity: 1)
            stream.initialize(to: z_stream())
            let status = inflateInit_(stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
            guard status == Z_OK else {
                stream.deinitialize(count: 1)
                stream.deallocate()
                throw PNGError(message: "PNG：无法初始化 zlib 解压流")
            }
        }

        func close() {
            inflateEnd(stream)
            stream.deinitialize(count: 1)
            stream.deallocate()
        }

        private mutating func advance(into output: UnsafeMutableBufferPointer<UInt8>) throws -> Int {
            if stream.pointee.avail_in == 0, inputOffset < input.count {
                let length = min(input.count - inputOffset, Int(uInt.max))
                stream.pointee.next_in = UnsafeMutablePointer(mutating: input.baseAddress!.advanced(by: inputOffset))
                stream.pointee.avail_in = uInt(length)
                inputOffset += length
            }
            let capacity = min(output.count, Int(uInt.max))
            stream.pointee.next_out = output.baseAddress!
            stream.pointee.avail_out = uInt(capacity)
            let availableInput = stream.pointee.avail_in
            let status = inflate(stream, Z_NO_FLUSH)
            let produced = capacity - Int(stream.pointee.avail_out)
            // Do not retain a pointer into a Swift scanline after its scope ends.
            stream.pointee.next_out = nil
            stream.pointee.avail_out = 0
            guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                throw PNGError(message: "PNG：zlib 数据错误（\(status)）")
            }
            if status == Z_STREAM_END { ended = true }
            guard ended || produced > 0 || stream.pointee.avail_in < availableInput else {
                throw PNGError(message: "PNG：zlib 数据被截断或解压流无法继续")
            }
            outputCount += produced
            return produced
        }

        mutating func read(count: Int) throws -> [UInt8] {
            var row = [UInt8](repeating: 0, count: count)
            try row.withUnsafeMutableBufferPointer { output in
                var offset = 0
                while offset < output.count {
                    guard !ended else { throw PNGError(message: "PNG：解压数据长度不足") }
                    let remaining = UnsafeMutableBufferPointer(start: output.baseAddress!.advanced(by: offset),
                                                               count: output.count - offset)
                    offset += try advance(into: remaining)
                }
            }
            return row
        }

        mutating func finish(expectedCount: Int) throws {
            guard outputCount == expectedCount else { throw PNGError(message: "PNG：解压长度错误") }
            // With an exactly full last scanline, zlib can still need to consume
            // its checksum before reporting STREAM_END. An extra output byte is
            // always an error, rather than silently ignoring a longer image.
            var scratch = [UInt8](repeating: 0, count: 1)
            while !ended {
                let produced = try scratch.withUnsafeMutableBufferPointer { try advance(into: $0) }
                guard produced == 0 else { throw PNGError(message: "PNG：解压数据超过图像尺寸") }
            }
            guard stream.pointee.avail_in == 0, inputOffset == input.count else {
                throw PNGError(message: "PNG：zlib 结束标记后仍有多余数据")
            }
        }
    }

    static func load(url: URL, device: MTLDevice, ignoreSRGB: Bool = true) throws -> MTLTexture {
        let bytes = [UInt8](try Data(contentsOf: url))
        let decoded = try decode(bytes)
        let size = FantResampler.fittedSize(width: decoded.width, height: decoded.height)
        let pixels = FantResampler.resize(decoded.pixels, width: decoded.width, height: decoded.height,
                                          channels: decoded.channels, depth: decoded.depth,
                                          toWidth: size.width, toHeight: size.height)
        let image = Image(width: size.width, height: size.height, depth: decoded.depth,
                          channels: decoded.channels, srgb: decoded.srgb, pixels: pixels)
        let srgb = !ignoreSRGB && image.srgb && image.depth == 8 && image.channels == 4
        let format: MTLPixelFormat
        switch (image.channels, image.depth) {
        case (1, 8): format = .r8Unorm
        case (1, 16): format = .r16Unorm
        case (4, 8): format = srgb ? .rgba8Unorm_srgb : .rgba8Unorm
        case (4, 16): format = .rgba16Unorm
        default: throw PNGError(message: "不支持的 PNG 纹理格式：\(url.lastPathComponent)")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: image.width, height: image.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PNGError(message: "无法创建 PNG 纹理：\(url.lastPathComponent)")
        }
        image.pixels.withUnsafeBytes { buffer in
            texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                            withBytes: buffer.baseAddress!, bytesPerRow: image.width * image.channels * image.depth / 8)
        }
        texture.label = url.lastPathComponent
        return texture
    }

    private struct Image {
        let width: Int
        let height: Int
        let depth: Int
        let channels: Int
        let srgb: Bool
        let pixels: [UInt8]
    }

    private static func decode(_ bytes: [UInt8]) throws -> Image {
        func fail(_ message: String) -> PNGError { PNGError(message: "PNG：" + message) }
        func word(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 |
                UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }
        guard bytes.count >= 8, Array(bytes.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10] else {
            throw fail("无效的文件签名")
        }
        var width = 0, height = 0, depth = 0, color = 0, interlace = 0
        var palette: [UInt8] = [], transparency: [UInt8] = [], compressed: [UInt8] = []
        var hasHeader = false, hasEnd = false, hasIDAT = false, endedIDAT = false
        var hasPalette = false, hasTransparency = false, hasSRGB = false
        var gamma: UInt32?
        var offset = 8
        while offset < bytes.count {
            guard bytes.count - offset >= 12 else { throw fail("chunk 头部被截断") }
            let length = Int(word(offset))
            guard length <= 0x7fffffff, length <= bytes.count - offset - 12 else { throw fail("chunk 数据被截断或过长") }
            let start = offset + 8, end = start + length
            let kind = String(bytes: bytes[(offset + 4)..<start], encoding: .ascii) ?? ""
            let actualCRC = bytes.withUnsafeBytes { raw in
                crc32(0, raw.bindMemory(to: Bytef.self).baseAddress!.advanced(by: offset + 4), uInt(length + 4))
            }
            guard UInt32(truncatingIfNeeded: actualCRC) == word(end) else { throw fail("\(kind) CRC 不匹配") }
            guard hasHeader || kind == "IHDR" else { throw fail("缺少 IHDR") }
            if hasIDAT && kind != "IDAT" { endedIDAT = true }
            switch kind {
            case "IHDR":
                guard !hasHeader, offset == 8, length == 13 else { throw fail("无效的 IHDR") }
                width = Int(word(start)); height = Int(word(start + 4))
                depth = Int(bytes[start + 8]); color = Int(bytes[start + 9])
                interlace = Int(bytes[start + 12])
                guard width > 0, height > 0, width <= 0x7fffffff, height <= 0x7fffffff else {
                    throw fail("尺寸超出 PNG 规范允许的范围")
                }
                let validDepths: [Int]
                switch color {
                case 0: validDepths = [1, 2, 4, 8, 16]
                case 2, 4, 6: validDepths = [8, 16]
                case 3: validDepths = [1, 2, 4, 8]
                default: throw fail("不支持的颜色类型")
                }
                guard validDepths.contains(depth), bytes[start + 10] == 0,
                      bytes[start + 11] == 0, interlace <= 1 else { throw fail("无效的编码参数") }
                hasHeader = true
            case "PLTE":
                guard !hasPalette, !hasIDAT, color != 0, color != 4,
                      length > 0, length <= 768, length % 3 == 0 else { throw fail("无效的调色板") }
                guard color != 3 || length / 3 <= 1 << depth else { throw fail("调色板超出位深") }
                palette = Array(bytes[start..<end]); hasPalette = true
            case "tRNS":
                guard !hasTransparency, !hasIDAT else { throw fail("重复或位置错误的 tRNS") }
                guard (color == 0 && length == 2) || (color == 2 && length == 6) ||
                        (color == 3 && hasPalette && length > 0 && length <= palette.count / 3) else {
                    throw fail("无效的透明度数据")
                }
                transparency = Array(bytes[start..<end]); hasTransparency = true
            case "IDAT":
                guard !endedIDAT, color != 3 || hasPalette else { throw fail("IDAT 顺序或调色板错误") }
                compressed.append(contentsOf: bytes[start..<end]); hasIDAT = true
            case "sRGB":
                guard !hasIDAT, !hasSRGB, length == 1, bytes[start] <= 3 else { throw fail("无效的 sRGB") }
                hasSRGB = true
            case "gAMA":
                guard !hasIDAT, gamma == nil, length == 4, word(start) > 0 else { throw fail("无效的 gAMA") }
                gamma = word(start)
            case "IEND":
                guard length == 0, hasIDAT else { throw fail("无效的 IEND") }
                // IEND terminates the PNG stream. File padding or container data
                // after its validated CRC is not another PNG chunk.
                hasEnd = true
            default:
                // PNG critical chunks cannot be ignored; ancillary color profiles deliberately can.
                guard bytes[offset + 4] & 0x20 != 0 else { throw fail("未知的 critical chunk：\(kind)") }
            }
            offset = end + 4
            if hasEnd { break }
        }
        guard hasEnd, !compressed.isEmpty else { throw fail("缺少图像数据或 IEND") }
        let inputChannels: Int
        switch color {
        case 0, 3: inputChannels = 1
        case 2: inputChannels = 3
        case 4: inputChannels = 2
        default: inputChannels = 4
        }
        let passes = interlace == 0 ? [(0, 0, 1, 1)] :
            [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
             (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
        func passSize(_ total: Int, _ start: Int, _ step: Int) -> Int {
            total > start ? (total - start + step - 1) / step : 0
        }
        func allocationSize(_ factors: Int...) throws -> Int {
            var size = 1
            for factor in factors {
                let product = size.multipliedReportingOverflow(by: factor)
                guard !product.overflow else { throw fail("图像解码缓冲区尺寸溢出") }
                size = product.partialValue
            }
            return size
        }
        var inflatedCount = 0
        for (x, y, dx, dy) in passes {
            let w = passSize(width, x, dx), h = passSize(height, y, dy)
            if w > 0, h > 0 {
                let rowBits = try allocationSize(w, inputChannels, depth)
                let passBytes = try allocationSize(h, 1 + (rowBits + 7) / 8)
                let total = inflatedCount.addingReportingOverflow(passBytes)
                guard !total.overflow else { throw fail("图像解压缓冲区尺寸溢出") }
                inflatedCount = total.partialValue
            }
        }
        let outputChannels = color == 0 && !hasTransparency ? 1 : 4
        let outputDepth = depth == 16 ? 16 : 8
        let componentBytes = outputDepth / 8
        let outputSize = try allocationSize(width, height, outputChannels, componentBytes)
        var output = [UInt8](repeating: 0, count: outputSize)
        let filterStride = max(1, (inputChannels * depth + 7) / 8)
        func key(_ component: Int) -> UInt16 {
            UInt16(transparency[component * 2]) << 8 | UInt16(transparency[component * 2 + 1])
        }
        return try compressed.withUnsafeBufferPointer { input in
            var inflater = try PNGInflator(input: input)
            defer { inflater.close() }
            for (startX, startY, stepX, stepY) in passes {
                let w = passSize(width, startX, stepX), h = passSize(height, startY, stepY)
                if w == 0 || h == 0 { continue }
                let rowBytes = (w * inputChannels * depth + 7) / 8
                var previous = [UInt8](repeating: 0, count: rowBytes)
                for rowIndex in 0..<h {
                    var row = try inflater.read(count: rowBytes + 1)
                    let filter = row.removeFirst()
                    guard filter <= 4 else { throw fail("无效的扫描行滤波器") }
                    for index in 0..<(filter == 0 ? 0 : rowBytes) {
                        let left = index >= filterStride ? Int(row[index - filterStride]) : 0
                        let above = Int(previous[index])
                        let upperLeft = index >= filterStride ? Int(previous[index - filterStride]) : 0
                        let predictor: Int
                        switch filter {
                        case 1: predictor = left
                        case 2: predictor = above
                        case 3: predictor = (left + above) / 2
                        case 4:
                            let p = left + above - upperLeft
                            let a = abs(p - left), b = abs(p - above), c = abs(p - upperLeft)
                            predictor = a <= b && a <= c ? left : b <= c ? above : upperLeft
                        default: predictor = 0
                        }
                        row[index] = row[index] &+ UInt8(predictor)
                    }
                    // These samples already have the texture's byte layout.
                    // Copy an entire scanline instead of converting each pixel.
                    // Adam7's scattered columns still use the general path.
                    if depth == 8, stepX == 1,
                       (color == 6 || (color == 0 && !hasTransparency)) {
                        let target = ((startY + rowIndex * stepY) * width + startX) * outputChannels
                        output.withUnsafeMutableBufferPointer { destination in
                            row.withUnsafeBufferPointer { source in
                                destination.baseAddress!.advanced(by: target)
                                    .update(from: source.baseAddress!, count: rowBytes)
                            }
                        }
                        previous = row
                        continue
                    }
                    // RGB8 without tRNS only needs an opaque alpha byte; no
                    // sample expansion or per-component format dispatch.
                    if depth == 8, color == 2, !hasTransparency {
                        output.withUnsafeMutableBufferPointer { destination in
                            row.withUnsafeBufferPointer { source in
                                var target = ((startY + rowIndex * stepY) * width + startX) * 4
                                for column in 0..<w {
                                    let input = column * 3
                                    destination[target] = source[input]
                                    destination[target + 1] = source[input + 1]
                                    destination[target + 2] = source[input + 2]
                                    destination[target + 3] = 255
                                    target += stepX * 4
                                }
                            }
                        }
                        previous = row
                        continue
                    }
                    func sample(_ index: Int) -> UInt16 {
                        if depth == 16 { return UInt16(row[index * 2]) << 8 | UInt16(row[index * 2 + 1]) }
                        if depth == 8 { return UInt16(row[index]) }
                        let bit = index * depth
                        return UInt16((row[bit / 8] >> (8 - depth - bit % 8)) & UInt8((1 << depth) - 1))
                    }
                    for column in 0..<w {
                        let base = column * inputChannels
                        let maximum: UInt16 = depth == 16 ? 65535 : UInt16((1 << depth) - 1)
                        var values = SIMD4<UInt16>(repeating: 0)
                        switch color {
                        case 0:
                            let gray = sample(base)
                            let expanded = outputDepth == 8 ? gray * 255 / maximum : gray
                            if outputChannels == 1 { values[0] = expanded }
                            else {
                                values = SIMD4(expanded, expanded, expanded,
                                               gray == key(0) ? 0 : outputDepth == 16 ? 65535 : 255)
                            }
                        case 2:
                            let r = sample(base), g = sample(base + 1), b = sample(base + 2)
                            let transparent = hasTransparency && r == key(0) && g == key(1) && b == key(2)
                            values = SIMD4(r, g, b, transparent ? 0 : maximum)
                        case 3:
                            let index = Int(sample(base))
                            guard index < palette.count / 3 else { throw fail("调色板索引越界") }
                            values = SIMD4(UInt16(palette[index * 3]), UInt16(palette[index * 3 + 1]),
                                           UInt16(palette[index * 3 + 2]), UInt16(index < transparency.count ? transparency[index] : 255))
                        case 4:
                            let gray = sample(base)
                            values = SIMD4(gray, gray, gray, sample(base + 1))
                        default:
                            values = SIMD4(sample(base), sample(base + 1), sample(base + 2), sample(base + 3))
                        }
                        let x = startX + column * stepX, y = startY + rowIndex * stepY
                        let target = (y * width + x) * outputChannels * componentBytes
                        for component in 0..<outputChannels {
                            let value = values[component]
                            output[target + component * componentBytes] = UInt8(truncatingIfNeeded: value)
                            if outputDepth == 16 { output[target + component * 2 + 1] = UInt8(value >> 8) }
                        }
                    }
                    previous = row
                }
            }
            try inflater.finish(expectedCount: inflatedCount)
            return Image(width: width, height: height, depth: outputDepth, channels: outputChannels,
                         srgb: hasSRGB || gamma == 45455, pixels: output)
        }
    }
}

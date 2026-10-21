import Foundation

/// Coverage-area Fant reduction. Each destination pixel integrates every source
/// pixel intersecting its footprint; filtering stays in the stored sample space.
enum FantResampler {
    static let maximumDimension = 16384

    static func fittedSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > maximumDimension || height > maximumDimension else { return (width, height) }
        // Match the native loader's float32 aspect ratio, truncation and minimum 1.
        let aspect = Float(height) / Float(width)
        if width > height {
            return (maximumDimension, max(1, Int(Float(maximumDimension) * aspect)))
        }
        return (max(1, Int(Float(maximumDimension) / aspect)), maximumDimension)
    }

    static func resize(_ pixels: [UInt8], width: Int, height: Int, channels: Int, depth: Int,
                       toWidth targetWidth: Int, toHeight targetHeight: Int) -> [UInt8] {
        precondition(width > 0 && height > 0 && (channels == 1 || channels == 4))
        precondition(depth == 8 || depth == 16)
        precondition(targetWidth > 0 && targetWidth <= width && targetHeight > 0 && targetHeight <= height)
        let componentBytes = depth / 8
        let pixelBytes = channels * componentBytes
        precondition(pixels.count / pixelBytes / width == height)
        guard width != targetWidth || height != targetHeight else { return pixels }

        // Coordinates are integer numerators over targetWidth/targetHeight.
        // This avoids accumulated floating-point edge drift and includes partial
        // first/last source pixels, even for a non-integral reduction ratio.
        struct Span {
            let lower: Int
            let upper: Int
            let first: Int
            let last: Int
        }
        let horizontalSpans = (0..<targetWidth).map { x in
            let lower = x * width, upper = (x + 1) * width
            return Span(lower: lower, upper: upper, first: lower / targetWidth,
                        last: (upper - 1) / targetWidth)
        }
        let maximumSample = depth == 16 ? 65535.0 : 255.0
        var output = [UInt8](repeating: 0, count: targetWidth * targetHeight * pixelBytes)
        var horizontal = [SIMD4<Double>](repeating: .zero, count: targetWidth)
        var accumulated = [SIMD4<Double>](repeating: .zero, count: targetWidth)
        var cachedSourceY = -1

        func sample(at offset: Int) -> Double {
            if componentBytes == 1 { return Double(pixels[offset]) }
            return Double(UInt16(pixels[offset]) | UInt16(pixels[offset + 1]) << 8)
        }
        for destinationY in 0..<targetHeight {
            for x in 0..<targetWidth { accumulated[x] = .zero }
            let top = destinationY * height, bottom = (destinationY + 1) * height
            for sourceY in (top / targetHeight)...((bottom - 1) / targetHeight) {
                if cachedSourceY != sourceY {
                    let rowOffset = sourceY * width * pixelBytes
                    for (x, span) in horizontalSpans.enumerated() {
                        var sum = SIMD4<Double>.zero
                        for sourceX in span.first...span.last {
                            let overlap = min(span.upper, (sourceX + 1) * targetWidth) -
                                max(span.lower, sourceX * targetWidth)
                            let offset = rowOffset + sourceX * pixelBytes
                            var value = SIMD4<Double>(sample(at: offset), 0, 0, 0)
                            if channels == 4 {
                                value.y = sample(at: offset + componentBytes)
                                value.z = sample(at: offset + componentBytes * 2)
                                value.w = sample(at: offset + componentBytes * 3)
                            }
                            sum += value * Double(overlap)
                        }
                        // Keep fractional samples between passes, including alpha.
                        horizontal[x] = sum / Double(width)
                    }
                    cachedSourceY = sourceY
                }
                let overlap = min(bottom, (sourceY + 1) * targetHeight) - max(top, sourceY * targetHeight)
                let weight = Double(overlap) / Double(height)
                for x in 0..<targetWidth { accumulated[x] += horizontal[x] * weight }
            }
            for x in 0..<targetWidth {
                let offset = (destinationY * targetWidth + x) * pixelBytes
                for component in 0..<channels {
                    let sample = min(maximumSample, max(0, accumulated[x][component]))
                    let integer = UInt16(sample.rounded(.toNearestOrAwayFromZero))
                    output[offset + component * componentBytes] = UInt8(truncatingIfNeeded: integer)
                    if componentBytes == 2 { output[offset + component * 2 + 1] = UInt8(integer >> 8) }
                }
            }
        }
        return output
    }
}

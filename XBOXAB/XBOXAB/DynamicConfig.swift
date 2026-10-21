import Foundation

extension EditorConfig {
    /// REA: ImageEffectsShader::Initialize reads a 20-byte header followed by
    /// records containing an int32 track plus the original 96-byte GPU payload.
    static func decodeDynamicConfig(_ data: Data) throws -> EditorConfig {
        func malformed() -> NSError {
            NSError(domain: "WallpaperProject", code: 401,
                    userInfo: [NSLocalizedDescriptionKey: "DynamicConfig 格式无效或数据不完整"])
        }
        guard data.count >= 20 else { throw malformed() }
        func word(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        }
        let count = Int(word(12))
        let recordSize = Int(word(16))
        guard recordSize == 100, count <= (data.count - 20) / recordSize,
              word(8) > 0 else { throw malformed() }
        var segments: [EffectSegment] = []
        for index in 0..<count {
            let offset = 20 + index * recordSize
            let track = Int(Int32(bitPattern: word(offset)))
            guard (0..<8).contains(track) else { throw malformed() }
            func f(_ relativeOffset: Int) -> Double {
                Double(Float(bitPattern: word(offset + relativeOffset)))
            }
            segments.append(EffectSegment(
                title: "Track \(track + 1)", trackIndex: track,
                effectType: Int(Int32(bitPattern: word(offset + 4))),
                startTime: f(8), duration: f(12), effectData1: f(16),
                floats1_0: f(20), floats1_1: f(24), floats1_2: f(28), floats1_3: f(32),
                floats2_0: f(36), floats2_1: f(40), floats2_2: f(44), floats2_3: f(48),
                floats3_0: f(52), floats3_1: f(56), floats3_2: f(60), floats3_3: f(64),
                floats4_0: f(68), floats4_1: f(72), floats4_2: f(76), floats4_3: f(80),
                floats5_0: f(84), floats5_1: f(88), floats5_2: f(92), floats5_3: f(96)))
        }
        return EditorConfig(timelineLength: Double(word(8)), effectSegments: segments)
    }
}

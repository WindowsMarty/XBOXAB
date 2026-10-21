import Foundation
import SwiftUI
import AppKit
import Combine

// MARK: - Effect Segment Model
public struct EffectSegment: Identifiable, Codable {
    public var id = UUID()
    public var title: String
    public var trackIndex: Int
    public var effectType: Int
    public var startTime: Double
    public var duration: Double
    public var effectData1: Double
    
    // Floats 1: StartPos X, StartPos Y, EndPos X, EndPos Y
    public var floats1_0: Double
    public var floats1_1: Double
    public var floats1_2: Double
    public var floats1_3: Double
    
    // Floats 2: Width, Height, SubImgIndex, Unused
    public var floats2_0: Double
    public var floats2_1: Double
    public var floats2_2: Double
    public var floats2_3: Double
    
    // Floats 3: MidPos or CellCols, CellTotal, etc.
    public var floats3_0: Double
    public var floats3_1: Double
    public var floats3_2: Double
    public var floats3_3: Double
    
    // Floats 4: OpacityMode, OpacityPercent, Scale/Tile X, Y
    public var floats4_0: Double
    public var floats4_1: Double
    public var floats4_2: Double
    public var floats4_3: Double
    
    // Floats 5: ScaleStart, ScaleEnd, RotateStart, RotateEnd
    public var floats5_0: Double
    public var floats5_1: Double
    public var floats5_2: Double
    public var floats5_3: Double
    
    // UI state
    public var isVisible: Bool = true
    
    enum CodingKeys: String, CodingKey {
        case title = "Title"
        case trackIndex = "TrackIndex"
        case effectType = "EffectType"
        case startTime = "StartTime"
        case duration = "Duration"
        case effectData1 = "EffectData1"
        
        case floats1_0 = "EffectDataFloats1_0"
        case floats1_1 = "EffectDataFloats1_1"
        case floats1_2 = "EffectDataFloats1_2"
        case floats1_3 = "EffectDataFloats1_3"
        
        case floats2_0 = "EffectDataFloats2_0"
        case floats2_1 = "EffectDataFloats2_1"
        case floats2_2 = "EffectDataFloats2_2"
        case floats2_3 = "EffectDataFloats2_3"
        
        case floats3_0 = "EffectDataFloats3_0"
        case floats3_1 = "EffectDataFloats3_1"
        case floats3_2 = "EffectDataFloats3_2"
        case floats3_3 = "EffectDataFloats3_3"
        
        case floats4_0 = "EffectDataFloats4_0"
        case floats4_1 = "EffectDataFloats4_1"
        case floats4_2 = "EffectDataFloats4_2"
        case floats4_3 = "EffectDataFloats4_3"
        
        case floats5_0 = "EffectDataFloats5_0"
        case floats5_1 = "EffectDataFloats5_1"
        case floats5_2 = "EffectDataFloats5_2"
        case floats5_3 = "EffectDataFloats5_3"
    }
}

extension EffectSegment {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decode(String.self, forKey: .title)
        trackIndex = try values.decode(Int.self, forKey: .trackIndex)
        effectType = try values.decode(Int.self, forKey: .effectType)
        startTime = try values.decode(Double.self, forKey: .startTime)
        duration = try values.decode(Double.self, forKey: .duration)
        effectData1 = try values.decode(Double.self, forKey: .effectData1)
        floats1_0 = try values.decode(Double.self, forKey: .floats1_0)
        floats1_1 = try values.decode(Double.self, forKey: .floats1_1)
        floats1_2 = try values.decode(Double.self, forKey: .floats1_2)
        floats1_3 = try values.decode(Double.self, forKey: .floats1_3)
        floats2_0 = try values.decode(Double.self, forKey: .floats2_0)
        floats2_1 = try values.decode(Double.self, forKey: .floats2_1)
        floats2_2 = try values.decode(Double.self, forKey: .floats2_2)
        floats2_3 = try values.decode(Double.self, forKey: .floats2_3)
        // Native JSON reader accepts old configurations without these groups.
        let hasGroup3 = values.contains(.floats3_0)
        floats3_0 = hasGroup3 ? try values.decode(Double.self, forKey: .floats3_0) : 0
        floats3_1 = hasGroup3 ? try values.decode(Double.self, forKey: .floats3_1) : 0
        floats3_2 = hasGroup3 ? try values.decode(Double.self, forKey: .floats3_2) : 0
        floats3_3 = hasGroup3 ? try values.decode(Double.self, forKey: .floats3_3) : 0
        let hasGroup4 = values.contains(.floats4_0)
        floats4_0 = hasGroup4 ? try values.decode(Double.self, forKey: .floats4_0) : 0
        floats4_1 = hasGroup4 ? try values.decode(Double.self, forKey: .floats4_1) : 0
        floats4_2 = hasGroup4 ? try values.decode(Double.self, forKey: .floats4_2) : 0
        floats4_3 = hasGroup4 ? try values.decode(Double.self, forKey: .floats4_3) : 0
        floats5_0 = hasGroup4 ? try values.decode(Double.self, forKey: .floats5_0) : 0
        floats5_1 = hasGroup4 ? try values.decode(Double.self, forKey: .floats5_1) : 0
        floats5_2 = hasGroup4 ? try values.decode(Double.self, forKey: .floats5_2) : 0
        floats5_3 = hasGroup4 ? try values.decode(Double.self, forKey: .floats5_3) : 0
    }
}

// MARK: - Editor Config
public struct EditorConfig: Codable {
    public var timelineLength: Double
    public var effectSegments: [EffectSegment]
    
    enum CodingKeys: String, CodingKey {
        case timelineLength = "TimelineLength"
        case effectSegments = "EffectSegments"
    }
}

extension EditorConfig {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let seconds = try values.decode(Double.self, forKey: .timelineLength)
        // Native JSON import truncates via dtol3, then stores a uint32 timeline
        // length before the runtime converts it to float32 seconds.
        guard let nativeSeconds = UInt32(exactly: seconds.rounded(.towardZero)), nativeSeconds > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .timelineLength, in: values,
                                                   debugDescription: "TimelineLength 必须表示有效的正整数秒数")
        }
        timelineLength = Double(nativeSeconds)
        effectSegments = try values.decode([EffectSegment].self, forKey: .effectSegments)
    }
}

// MARK: - Wallpaper Project Manager
@MainActor
public class WallpaperProject: ObservableObject {
    @Published public var folderURL: URL?
    @Published public var config: EditorConfig?
    public private(set) var usesBinaryConfig = false
    @Published public var bgImage: NSImage?
    @Published public var subImages: [Int: NSImage] = [:]
    @Published public var alphaMasks: [Int: NSImage] = [:]
    @Published public var rippleNormal: NSImage?
    
    // Playback state
    @Published public var currentTime: Double = 0.0
    @Published public var isPlaying: Bool = true
    @Published public var playbackSpeed: Double = 1.0
    @Published public var isLooping: Bool = true
    @Published public var segments: [EffectSegment] = []
    @Published public var selectedSegmentID: UUID?
    
    // Video mode state
    @Published public var isVideoMode: Bool = false
    @Published public var videoURL: URL? = nil
    @Published public var isExportingVideo: Bool = false
    @Published public var exportProgress: Double = 0.0
    
    public init() {
        // Try to load bundled or local ripple normal texture
        loadRippleNormal()
    }
    
    private func loadRippleNormal() {
        let possiblePaths = [
            Bundle.main.url(forResource: "waterripplenormal", withExtension: "png"),
            URL(fileURLWithPath: "/Users/marty/Downloads/Xbox.Dashboard.AnimatedBackgrounds_1.0.40.0_x64_AnimationEditorRelease/Shaders/waterripplenormal.png"),
            URL(fileURLWithPath: "/Users/marty/Downloads/XBOXAB/XBOXAB/waterripplenormal.png")
        ]
        for url in possiblePaths.compactMap({ $0 }) {
            if let img = NSImage(contentsOf: url) {
                self.rippleNormal = img
                break
            }
        }
    }
    
    public func load(from folder: URL, loadPreviewImages: Bool = true) throws {
        let isAccessing = folder.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                folder.stopAccessingSecurityScopedResource()
            }
        }
        
        // Release previous project's images to free memory before loading new ones
        self.bgImage = nil
        self.subImages.removeAll()
        self.alphaMasks.removeAll()
        self.videoURL = nil
        self.isVideoMode = false
        
        self.folderURL = folder
        
        // The native player consumes DynamicConfig, not the editor's JSON.
        let binaryURL = folder.appendingPathComponent("DynamicConfig")
        let decodedConfig: EditorConfig
        usesBinaryConfig = FileManager.default.fileExists(atPath: binaryURL.path)
        if usesBinaryConfig {
            decodedConfig = try EditorConfig.decodeDynamicConfig(Data(contentsOf: binaryURL))
        } else {
            let configURL = folder.appendingPathComponent("EditorConfig.json")
            let rawData = try Data(contentsOf: configURL)
            let encodings: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian]
            guard let jsonString = encodings.compactMap({ String(data: rawData, encoding: $0) })
                .first(where: { $0.contains("TimelineLength") }),
                  let validData = jsonString.data(using: .utf8) else {
                throw NSError(domain: "WallpaperProject", code: 400,
                              userInfo: [NSLocalizedDescriptionKey: "无法解码 EditorConfig.json 文件编码"])
            }
            decodedConfig = try JSONDecoder().decode(EditorConfig.self, from: validData)
        }
        self.config = decodedConfig
        self.segments = decodedConfig.effectSegments
        self.currentTime = 0.0

        // Metal loads the referenced PNGs directly, with the original sample
        // values. Avoid loading a second set through AppKit for that caller.
        guard loadPreviewImages else { return }
        
        // 2. Load DynamicBg.png
        let bgURL = folder.appendingPathComponent("DynamicBg.png")
        if FileManager.default.fileExists(atPath: bgURL.path) {
            self.bgImage = NSImage(contentsOf: bgURL)
        } else {
            self.bgImage = nil
        }
        
        // 3. Load DynamicSubImg1.png ~ DynamicSubImg16.png
        var subs: [Int: NSImage] = [:]
        for i in 0..<16 {
            let subURL = folder.appendingPathComponent("DynamicSubImg\(i + 1).png")
            if FileManager.default.fileExists(atPath: subURL.path), let img = NSImage(contentsOf: subURL) {
                subs[i] = img
            }
        }
        self.subImages = subs
        
        // 4. Load AlphaMask1.png ~ AlphaMask8.png
        var masks: [Int: NSImage] = [:]
        for i in 0..<8 {
            let maskURL = folder.appendingPathComponent("AlphaMask\(i + 1).png")
            if FileManager.default.fileExists(atPath: maskURL.path), let rawImg = NSImage(contentsOf: maskURL) {
                // The original shader samples the PNG red channel directly.
                masks[i] = rawImg
            }
        }
        self.alphaMasks = masks
    }
    
    public func advance(deltaTime: Double) {
        guard isPlaying, let config = config, config.timelineLength > 0 else { return }
        currentTime += deltaTime * playbackSpeed
        if currentTime > config.timelineLength {
            if isLooping {
                currentTime = currentTime.truncatingRemainder(dividingBy: config.timelineLength)
            } else {
                currentTime = config.timelineLength
                isPlaying = false
            }
        }
    }
    
    public func toggleVisibility(for id: UUID) {
        if let idx = segments.firstIndex(where: { $0.id == id }) {
            segments[idx].isVisible.toggle()
        }
    }
}

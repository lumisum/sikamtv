import CoreGraphics
import Foundation

enum AspectRatio: String, CaseIterable, Identifiable, Codable, Sendable {
    case portrait = "9:16"
    case landscape = "16:9"
    case square = "1:1"

    var id: String { rawValue }

    var size1080: CGSize {
        switch self {
        case .portrait: return CGSize(width: 1080, height: 1920)
        case .landscape: return CGSize(width: 1920, height: 1080)
        case .square: return CGSize(width: 1080, height: 1080)
        }
    }

    /// Preview and export share normalized scene coordinates. Only the render target
    /// size differs, so composition stays identical without a full 1080p UI redraw.
    var previewSize: CGSize {
        switch self {
        case .portrait: return CGSize(width: 540, height: 960)
        case .landscape: return CGSize(width: 960, height: 540)
        case .square: return CGSize(width: 720, height: 720)
        }
    }

    var realtimePreviewSize: CGSize {
        switch self {
        case .portrait: return CGSize(width: 360, height: 640)
        case .landscape: return CGSize(width: 640, height: 360)
        case .square: return CGSize(width: 480, height: 480)
        }
    }
}

enum MediaKind: Sendable { case image, video }

struct BackgroundMedia: Sendable {
    let url: URL
    let kind: MediaKind
    let duration: Double
    let hasAudio: Bool

    init(url: URL, kind: MediaKind, duration: Double, hasAudio: Bool = false) {
        self.url = url
        self.kind = kind
        self.duration = duration
        self.hasAudio = hasAudio
    }

    /// Videos loop inside their assigned timeline segment. For a single video,
    /// that segment spans the full song, so the background repeats until export ends.
    func playbackTime(for localTime: Double) -> Double {
        guard kind == .video, duration > 0 else { return max(0, localTime) }
        return max(0, localTime).truncatingRemainder(dividingBy: duration)
    }
}

enum BackgroundTransition: String, CaseIterable, Identifiable, Codable, Sendable {
    case crossfade = "淡入淡出"
    case slide = "横向滑动"
    case zoom = "缩放叠化"
    case none = "直接切换"

    var id: String { rawValue }
}

struct BackgroundTimelineState: Equatable, Sendable {
    let currentIndex: Int
    let nextIndex: Int?
    let currentLocalTime: Double
    let nextLocalTime: Double
    let segmentDuration: Double
    let transitionProgress: Double
}

enum BackgroundTimeline {
    static func state(at time: Double, duration: Double, itemCount: Int, transition: BackgroundTransition, transitionDuration: Double, singleVideoDuration: Double? = nil) -> BackgroundTimelineState? {
        guard itemCount > 0 else { return nil }
        if itemCount == 1, let videoDuration = singleVideoDuration, videoDuration > 0 {
            return singleVideoState(at: time, videoDuration: videoDuration, transitionDuration: transitionDuration)
        }
        guard itemCount > 1, duration > 0 else {
            return BackgroundTimelineState(currentIndex: 0, nextIndex: nil, currentLocalTime: max(0, time), nextLocalTime: 0, segmentDuration: max(duration, 1), transitionProgress: 0)
        }
        let segmentDuration = duration / Double(itemCount)
        let clampedTime = min(max(0, time), max(0, duration - 0.000_001))
        let activeIndex = min(itemCount - 1, Int(clampedTime / segmentDuration))
        let localTime = clampedTime - Double(activeIndex) * segmentDuration
        let actualTransitionDuration = min(max(0.05, transitionDuration), segmentDuration * 0.45)
        if transition != .none, activeIndex > 0, localTime < actualTransitionDuration {
            let progress = min(1, max(0, localTime / actualTransitionDuration))
            return BackgroundTimelineState(
                currentIndex: activeIndex - 1,
                nextIndex: activeIndex,
                currentLocalTime: segmentDuration,
                nextLocalTime: localTime,
                segmentDuration: segmentDuration,
                transitionProgress: progress
            )
        }
        return BackgroundTimelineState(currentIndex: activeIndex, nextIndex: nil, currentLocalTime: localTime, nextLocalTime: 0, segmentDuration: segmentDuration, transitionProgress: 0)
    }

    private static func singleVideoState(at time: Double, videoDuration: Double, transitionDuration: Double) -> BackgroundTimelineState {
        let safeTime = max(0, time)
        let blendDuration = min(max(0.2, transitionDuration), videoDuration * 0.25)
        let cycleDuration = max(0.001, videoDuration - blendDuration)
        let playhead: Double
        if safeTime < videoDuration {
            playhead = safeTime
        } else {
            // After the first pass, each cycle resumes where the incoming blend
            // finished instead of jumping back to the video's first frame.
            playhead = (safeTime - videoDuration).truncatingRemainder(dividingBy: cycleDuration) + blendDuration
        }

        let blendStart = videoDuration - blendDuration
        if playhead >= blendStart {
            let progress = min(1, max(0, (playhead - blendStart) / blendDuration))
            return BackgroundTimelineState(
                currentIndex: 0,
                nextIndex: 0,
                currentLocalTime: playhead,
                nextLocalTime: progress * blendDuration,
                segmentDuration: videoDuration,
                transitionProgress: progress
            )
        }
        return BackgroundTimelineState(currentIndex: 0, nextIndex: nil, currentLocalTime: playhead, nextLocalTime: 0, segmentDuration: videoDuration, transitionProgress: 0)
    }
}

struct LRCLine: Identifiable, Equatable, Sendable {
    let id = UUID()
    let time: Double
    let text: String
}

enum VisualizerKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case wave = "Wave"
    case spectrum = "Spectrum"
    case mirror = "Mirror"
    case circle = "Circle"
    case ripple = "Ripple"
    case aurora = "Aurora"
    case prism = "Prism"
    case nebula = "Nebula"
    case kaleidoscope = "Kaleidoscope"
    case starfield = "Starfield"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .wave: return "丝绸波形"
        case .spectrum: return "动态频谱"
        case .mirror: return "镜像地平线"
        case .circle: return "呼吸光环"
        case .ripple: return "液态水波"
        case .aurora: return "极光帷幕"
        case .prism: return "棱镜隧道"
        case .nebula: return "星尘星云"
        case .kaleidoscope: return "万象花镜"
        case .starfield: return "星河跃迁"
        }
    }

    var subtitle: String {
        switch self {
        case .wave: return "多层波形随人声与旋律柔和流动"
        case .spectrum: return "频段能量驱动经典彩色频谱柱"
        case .mirror: return "上下对称的频谱包络与地平线光带"
        case .circle: return "频谱环绕中心形成呼吸式能量光环"
        case .ripple: return "低频推动椭圆水波向外连续扩散"
        case .aurora: return "不同频段分别驱动多层半透明极光"
        case .prism: return "节拍穿行于旋转的彩色几何隧道"
        case .nebula: return "高频点亮星尘，低频推动星云呼吸"
        case .kaleidoscope: return "镜像频段生成旋转绽放的对称花瓣"
        case .starfield: return "响度控制纵深，高频化作跃迁星轨"
        }
    }
}

enum VisualTemplate: String, CaseIterable, Identifiable, Codable, Sendable {
    case zen = "Zen"
    case ethereal = "Ethereal"
    case minimal = "Minimal"
    case cinema = "Cinema"
    case electronic = "Electronic"

    var id: String { rawValue }
    var title: String { rawValue }
    var subtitle: String {
        switch self {
        case .zen: return "碧金水波 · 节拍光晕"
        case .ethereal: return "紫粉极光 · 空灵帷幕"
        case .minimal: return "冷银波形 · 克制留白"
        case .cinema: return "琥珀棱镜 · 电影字幕"
        case .electronic: return "青洋红频谱 · 强节奏"
        }
    }
    var defaultVisualizer: VisualizerKind {
        switch self {
        case .zen: return .ripple
        case .ethereal: return .aurora
        case .minimal: return .wave
        case .cinema: return .prism
        case .electronic: return .spectrum
        }
    }
    var accent: CGColor { palette.accent }
    var palette: VisualPalette {
        switch self {
        case .zen:
            return VisualPalette(
                accent: CGColor(red: 0.46, green: 0.97, blue: 0.78, alpha: 1),
                secondary: CGColor(red: 0.99, green: 0.84, blue: 0.38, alpha: 1),
                highlight: CGColor(red: 0.88, green: 1.00, blue: 0.94, alpha: 1),
                lyric: CGColor(red: 0.82, green: 1.00, blue: 0.90, alpha: 1),
                warm: CGColor(red: 0.38, green: 0.86, blue: 0.62, alpha: 1),
                cool: CGColor(red: 0.55, green: 0.90, blue: 1.00, alpha: 1)
            )
        case .ethereal:
            return VisualPalette(
                accent: CGColor(red: 0.73, green: 0.54, blue: 1.00, alpha: 1),
                secondary: CGColor(red: 1.00, green: 0.46, blue: 0.82, alpha: 1),
                highlight: CGColor(red: 0.90, green: 0.94, blue: 1.00, alpha: 1),
                lyric: CGColor(red: 0.95, green: 0.88, blue: 1.00, alpha: 1),
                warm: CGColor(red: 0.98, green: 0.52, blue: 0.78, alpha: 1),
                cool: CGColor(red: 0.48, green: 0.78, blue: 1.00, alpha: 1)
            )
        case .minimal:
            return VisualPalette(
                accent: CGColor(red: 0.96, green: 0.97, blue: 1.00, alpha: 1),
                secondary: CGColor(red: 0.70, green: 0.82, blue: 0.96, alpha: 1),
                highlight: CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1),
                lyric: CGColor(red: 0.98, green: 0.99, blue: 1.00, alpha: 1),
                warm: CGColor(red: 0.90, green: 0.88, blue: 0.84, alpha: 1),
                cool: CGColor(red: 0.76, green: 0.86, blue: 0.98, alpha: 1)
            )
        case .cinema:
            return VisualPalette(
                accent: CGColor(red: 1.00, green: 0.72, blue: 0.34, alpha: 1),
                secondary: CGColor(red: 1.00, green: 0.38, blue: 0.46, alpha: 1),
                highlight: CGColor(red: 1.00, green: 0.93, blue: 0.72, alpha: 1),
                lyric: CGColor(red: 1.00, green: 0.94, blue: 0.82, alpha: 1),
                warm: CGColor(red: 1.00, green: 0.50, blue: 0.22, alpha: 1),
                cool: CGColor(red: 0.98, green: 0.78, blue: 0.52, alpha: 1)
            )
        case .electronic:
            return VisualPalette(
                accent: CGColor(red: 0.10, green: 0.96, blue: 1.00, alpha: 1),
                secondary: CGColor(red: 1.00, green: 0.18, blue: 0.72, alpha: 1),
                highlight: CGColor(red: 0.62, green: 1.00, blue: 0.42, alpha: 1),
                lyric: CGColor(red: 0.82, green: 1.00, blue: 1.00, alpha: 1),
                warm: CGColor(red: 1.00, green: 0.32, blue: 0.52, alpha: 1),
                cool: CGColor(red: 0.18, green: 0.82, blue: 1.00, alpha: 1)
            )
        }
    }
}

struct VisualPalette: Sendable {
    let accent: CGColor
    let secondary: CGColor
    let highlight: CGColor
    let lyric: CGColor
    let warm: CGColor
    let cool: CGColor

    func tone(at progress: CGFloat) -> CGColor {
        let p = min(1, max(0, progress))
        if p < 0.5 { return Self.mix(warm, accent, p * 2) }
        return Self.mix(accent, cool, (p - 0.5) * 2)
    }

    func ribbon(_ index: Int) -> CGColor {
        switch index % 5 {
        case 0: return cool
        case 1: return secondary
        case 2: return accent
        case 3: return highlight
        default: return warm
        }
    }

    static func mix(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
        let clamped = min(1, max(0, t))
        let ac = rgba(a)
        let bc = rgba(b)
        return CGColor(
            red: ac.0 + (bc.0 - ac.0) * clamped,
            green: ac.1 + (bc.1 - ac.1) * clamped,
            blue: ac.2 + (bc.2 - ac.2) * clamped,
            alpha: ac.3 + (bc.3 - ac.3) * clamped
        )
    }

    static func rgba(_ color: CGColor) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let converted = color.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil) ?? color
        let c = converted.components ?? [1, 1, 1, 1]
        if c.count >= 4 { return (c[0], c[1], c[2], c[3]) }
        if c.count == 2 { return (c[0], c[0], c[0], c[1]) }
        return (1, 1, 1, 1)
    }
}

enum LyricAnimation: String, CaseIterable, Identifiable, Codable, Sendable {
    case scroll = "向上滚动"
    case fade = "柔和淡入"
    case scale = "呼吸缩放"
    case karaoke = "逐字点亮"
    case bloom = "光晕绽放"
    case none = "无动画"
    var id: String { rawValue }
}

enum LyricAlignment: String, CaseIterable, Identifiable, Codable, Sendable {
    case leading = "左对齐"
    case center = "居中"
    case trailing = "右对齐"
    var id: String { rawValue }
}

struct RenderSettings: Codable, Equatable, Sendable {
    var aspectRatio: AspectRatio = .portrait
    var template: VisualTemplate = .ethereal
    var visualizer: VisualizerKind = .aurora
    var blur: Double = 18
    var darkness: Double = 0.34
    var saturation: Double = 1.16
    var backgroundTransition: BackgroundTransition = .crossfade
    var backgroundTransitionDuration: Double = 1.35

    var visualizerStrength: Double = 0.86
    var visualizerPositionY: Double = 0.31
    var visualizerScale: Double = 1.08
    var visualizerGlow: Double = 0.96
    var visualizerSmoothing: Double = 0.72
    var visualizerDensity: Double = 0.86
    var visualizerBrilliance: Double = 0.88
    var visualizerIntegration: Double = 0.78
    var visualizerTrail: Double = 0.42
    var visualizerColorRichness: Double = 0.92
    var visualizerDepth: Double = 0.74
    var visualizerBeatImpact: Double = 0.76
    var musicAwareness: Double = 0.92

    var lyricSize: Double = 42
    var lyricPositionY: Double = 0.60
    var lyricWidth: Double = 0.82
    var lyricLineSpacing: Double = 1.85
    var lyricInactiveOpacity: Double = 0.24
    var lyricGlow: Double = 0.82
    var lyricAnimationDuration: Double = 0.52
    var lyricAnimation: LyricAnimation = .bloom
    var lyricAlignment: LyricAlignment = .center
    var fontPostScriptName: String = FontManager.defaultPostScriptName

    init() {}

    private enum CodingKeys: String, CodingKey {
        case aspectRatio, template, visualizer, blur, darkness, saturation
        case backgroundTransition, backgroundTransitionDuration
        case visualizerStrength, visualizerPositionY, visualizerScale, visualizerGlow, visualizerSmoothing, visualizerDensity
        case visualizerBrilliance, visualizerIntegration, visualizerTrail, visualizerColorRichness, visualizerDepth, visualizerBeatImpact, musicAwareness
        case lyricSize, lyricPositionY, lyricWidth, lyricLineSpacing, lyricInactiveOpacity, lyricGlow, lyricAnimationDuration
        case lyricAnimation, lyricAlignment, fontPostScriptName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RenderSettings()
        aspectRatio = try container.decodeIfPresent(AspectRatio.self, forKey: .aspectRatio) ?? defaults.aspectRatio
        template = try container.decodeIfPresent(VisualTemplate.self, forKey: .template) ?? defaults.template
        visualizer = try container.decodeIfPresent(VisualizerKind.self, forKey: .visualizer) ?? defaults.visualizer
        blur = try container.decodeIfPresent(Double.self, forKey: .blur) ?? defaults.blur
        darkness = try container.decodeIfPresent(Double.self, forKey: .darkness) ?? defaults.darkness
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? defaults.saturation
        backgroundTransition = try container.decodeIfPresent(BackgroundTransition.self, forKey: .backgroundTransition) ?? defaults.backgroundTransition
        backgroundTransitionDuration = try container.decodeIfPresent(Double.self, forKey: .backgroundTransitionDuration) ?? defaults.backgroundTransitionDuration
        visualizerStrength = try container.decodeIfPresent(Double.self, forKey: .visualizerStrength) ?? defaults.visualizerStrength
        visualizerPositionY = try container.decodeIfPresent(Double.self, forKey: .visualizerPositionY) ?? defaults.visualizerPositionY
        visualizerScale = try container.decodeIfPresent(Double.self, forKey: .visualizerScale) ?? defaults.visualizerScale
        visualizerGlow = try container.decodeIfPresent(Double.self, forKey: .visualizerGlow) ?? defaults.visualizerGlow
        visualizerSmoothing = try container.decodeIfPresent(Double.self, forKey: .visualizerSmoothing) ?? defaults.visualizerSmoothing
        visualizerDensity = try container.decodeIfPresent(Double.self, forKey: .visualizerDensity) ?? defaults.visualizerDensity
        visualizerBrilliance = try container.decodeIfPresent(Double.self, forKey: .visualizerBrilliance) ?? defaults.visualizerBrilliance
        visualizerIntegration = try container.decodeIfPresent(Double.self, forKey: .visualizerIntegration) ?? defaults.visualizerIntegration
        visualizerTrail = try container.decodeIfPresent(Double.self, forKey: .visualizerTrail) ?? defaults.visualizerTrail
        visualizerColorRichness = try container.decodeIfPresent(Double.self, forKey: .visualizerColorRichness) ?? defaults.visualizerColorRichness
        visualizerDepth = try container.decodeIfPresent(Double.self, forKey: .visualizerDepth) ?? defaults.visualizerDepth
        visualizerBeatImpact = try container.decodeIfPresent(Double.self, forKey: .visualizerBeatImpact) ?? defaults.visualizerBeatImpact
        musicAwareness = try container.decodeIfPresent(Double.self, forKey: .musicAwareness) ?? defaults.musicAwareness
        lyricSize = try container.decodeIfPresent(Double.self, forKey: .lyricSize) ?? defaults.lyricSize
        lyricPositionY = try container.decodeIfPresent(Double.self, forKey: .lyricPositionY) ?? defaults.lyricPositionY
        lyricWidth = try container.decodeIfPresent(Double.self, forKey: .lyricWidth) ?? defaults.lyricWidth
        lyricLineSpacing = try container.decodeIfPresent(Double.self, forKey: .lyricLineSpacing) ?? defaults.lyricLineSpacing
        lyricInactiveOpacity = try container.decodeIfPresent(Double.self, forKey: .lyricInactiveOpacity) ?? defaults.lyricInactiveOpacity
        lyricGlow = try container.decodeIfPresent(Double.self, forKey: .lyricGlow) ?? defaults.lyricGlow
        lyricAnimationDuration = try container.decodeIfPresent(Double.self, forKey: .lyricAnimationDuration) ?? defaults.lyricAnimationDuration
        lyricAnimation = try container.decodeIfPresent(LyricAnimation.self, forKey: .lyricAnimation) ?? defaults.lyricAnimation
        lyricAlignment = try container.decodeIfPresent(LyricAlignment.self, forKey: .lyricAlignment) ?? defaults.lyricAlignment
        fontPostScriptName = try container.decodeIfPresent(String.self, forKey: .fontPostScriptName) ?? defaults.fontPostScriptName
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(aspectRatio, forKey: .aspectRatio)
        try container.encode(template, forKey: .template)
        try container.encode(visualizer, forKey: .visualizer)
        try container.encode(blur, forKey: .blur)
        try container.encode(darkness, forKey: .darkness)
        try container.encode(saturation, forKey: .saturation)
        try container.encode(backgroundTransition, forKey: .backgroundTransition)
        try container.encode(backgroundTransitionDuration, forKey: .backgroundTransitionDuration)
        try container.encode(visualizerStrength, forKey: .visualizerStrength)
        try container.encode(visualizerPositionY, forKey: .visualizerPositionY)
        try container.encode(visualizerScale, forKey: .visualizerScale)
        try container.encode(visualizerGlow, forKey: .visualizerGlow)
        try container.encode(visualizerSmoothing, forKey: .visualizerSmoothing)
        try container.encode(visualizerDensity, forKey: .visualizerDensity)
        try container.encode(visualizerBrilliance, forKey: .visualizerBrilliance)
        try container.encode(visualizerIntegration, forKey: .visualizerIntegration)
        try container.encode(visualizerTrail, forKey: .visualizerTrail)
        try container.encode(visualizerColorRichness, forKey: .visualizerColorRichness)
        try container.encode(visualizerDepth, forKey: .visualizerDepth)
        try container.encode(visualizerBeatImpact, forKey: .visualizerBeatImpact)
        try container.encode(musicAwareness, forKey: .musicAwareness)
        try container.encode(lyricSize, forKey: .lyricSize)
        try container.encode(lyricPositionY, forKey: .lyricPositionY)
        try container.encode(lyricWidth, forKey: .lyricWidth)
        try container.encode(lyricLineSpacing, forKey: .lyricLineSpacing)
        try container.encode(lyricInactiveOpacity, forKey: .lyricInactiveOpacity)
        try container.encode(lyricGlow, forKey: .lyricGlow)
        try container.encode(lyricAnimationDuration, forKey: .lyricAnimationDuration)
        try container.encode(lyricAnimation, forKey: .lyricAnimation)
        try container.encode(lyricAlignment, forKey: .lyricAlignment)
        try container.encode(fontPostScriptName, forKey: .fontPostScriptName)
    }
}

struct AudioFrameFeatures: Sendable {
    let amplitude: Float
    let loudness: Float
    let bass: Float
    let mid: Float
    let high: Float
    let beat: Float
    let spectrum: [Float]
    let waveform: [Float]
    let energy: Float
    let transient: Float
    let buildup: Float
    let climax: Float
    let quiet: Float
    let warmth: Float
    let sectionProgress: Float

    init(
        amplitude: Float,
        loudness: Float,
        bass: Float,
        mid: Float,
        high: Float,
        beat: Float,
        spectrum: [Float],
        waveform: [Float],
        energy: Float = 0,
        transient: Float = 0,
        buildup: Float = 0,
        climax: Float = 0,
        quiet: Float = 1,
        warmth: Float = 0.5,
        sectionProgress: Float = 0
    ) {
        self.amplitude = amplitude
        self.loudness = loudness
        self.bass = bass
        self.mid = mid
        self.high = high
        self.beat = beat
        self.spectrum = spectrum
        self.waveform = waveform
        self.energy = energy
        self.transient = transient
        self.buildup = buildup
        self.climax = climax
        self.quiet = quiet
        self.warmth = warmth
        self.sectionProgress = sectionProgress
    }

    func directed(amount: Float) -> AudioFrameFeatures {
        let awareness = max(0, min(1, amount))
        let livingEnergy = loudness * (1 - awareness * 0.48) + energy * awareness * 0.48
        let directedBeat = max(beat, transient * (0.72 + climax * 0.28))
        return AudioFrameFeatures(
            amplitude: amplitude * (1 - awareness * 0.18) + livingEnergy * awareness * 0.18,
            loudness: livingEnergy,
            bass: min(1, bass * (1 + awareness * climax * 0.18)),
            mid: min(1, mid * (1 + awareness * buildup * 0.14)),
            high: min(1, high * (1 + awareness * (buildup + transient) * 0.12)),
            beat: beat * (1 - awareness * 0.42) + directedBeat * awareness * 0.42,
            spectrum: spectrum,
            waveform: waveform,
            energy: energy,
            transient: transient,
            buildup: buildup,
            climax: climax,
            quiet: quiet,
            warmth: warmth,
            sectionProgress: sectionProgress
        )
    }

    static let silent = AudioFrameFeatures(
        amplitude: 0, loudness: 0, bass: 0, mid: 0, high: 0, beat: 0,
        spectrum: Array(repeating: 0, count: 96),
        waveform: Array(repeating: 0, count: 128),
        energy: 0, transient: 0, buildup: 0, climax: 0, quiet: 1, warmth: 0.5, sectionProgress: 0
    )
}

struct AudioAnalysis: Codable, Sendable {
    static let cacheVersion = 3

    let version: Int
    let duration: Double
    let sampleRate: Double
    let frameRate: Double
    let amplitudes: [Float]
    let loudness: [Float]
    let bass: [Float]
    let mid: [Float]
    let high: [Float]
    let beats: [Float]
    let spectrum: [[Float]]
    let waveform: [[Float]]
    let energy: [Float]
    let transients: [Float]
    let buildups: [Float]
    let climaxes: [Float]
    let quietness: [Float]
    let warmth: [Float]
    let sectionProgress: [Float]

    init(
        version: Int = AudioAnalysis.cacheVersion,
        duration: Double,
        sampleRate: Double,
        frameRate: Double = 30,
        amplitudes: [Float],
        loudness: [Float]? = nil,
        bass: [Float]? = nil,
        mid: [Float]? = nil,
        high: [Float]? = nil,
        beats: [Float]? = nil,
        spectrum: [[Float]],
        waveform: [[Float]]? = nil,
        energy: [Float]? = nil,
        transients: [Float]? = nil,
        buildups: [Float]? = nil,
        climaxes: [Float]? = nil,
        quietness: [Float]? = nil,
        warmth: [Float]? = nil,
        sectionProgress: [Float]? = nil
    ) {
        self.version = version
        self.duration = duration
        self.sampleRate = sampleRate
        self.frameRate = frameRate
        self.amplitudes = amplitudes
        self.loudness = loudness ?? amplitudes
        self.bass = bass ?? Array(repeating: 0, count: amplitudes.count)
        self.mid = mid ?? Array(repeating: 0, count: amplitudes.count)
        self.high = high ?? Array(repeating: 0, count: amplitudes.count)
        self.beats = beats ?? Array(repeating: 0, count: amplitudes.count)
        self.spectrum = spectrum
        self.waveform = waveform ?? Array(repeating: Array(repeating: 0, count: 128), count: amplitudes.count)
        self.energy = energy ?? self.loudness
        self.transients = transients ?? self.beats
        self.buildups = buildups ?? Array(repeating: 0, count: amplitudes.count)
        self.climaxes = climaxes ?? Array(repeating: 0, count: amplitudes.count)
        self.quietness = quietness ?? self.loudness.map { 1 - $0 }
        self.warmth = warmth ?? Array(repeating: 0.5, count: amplitudes.count)
        self.sectionProgress = sectionProgress ?? Array(repeating: 0, count: amplitudes.count)
    }

    func frame(at time: Double) -> AudioFrameFeatures {
        guard duration > 0 else { return .silent }
        let count = max(amplitudes.count, spectrum.count)
        guard count > 0 else { return .silent }
        let index = min(count - 1, max(0, Int(time * frameRate)))
        return AudioFrameFeatures(
            amplitude: value(amplitudes, index),
            loudness: value(loudness, index),
            bass: value(bass, index),
            mid: value(mid, index),
            high: value(high, index),
            beat: value(beats, index),
            spectrum: array(spectrum, index, 96),
            waveform: array(waveform, index, 128),
            energy: value(energy, index),
            transient: value(transients, index),
            buildup: value(buildups, index),
            climax: value(climaxes, index),
            quiet: value(quietness, index),
            warmth: value(warmth, index),
            sectionProgress: value(sectionProgress, index)
        )
    }

    func amplitude(at time: Double) -> Float { frame(at: time).amplitude }
    func spectrum(at time: Double) -> [Float] { frame(at: time).spectrum }

    private func value(_ values: [Float], _ index: Int) -> Float {
        values.isEmpty ? 0 : values[min(index, values.count - 1)]
    }

    private func array(_ values: [[Float]], _ index: Int, _ fallbackCount: Int) -> [Float] {
        values.isEmpty ? Array(repeating: 0, count: fallbackCount) : values[min(index, values.count - 1)]
    }
}

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
}

enum MediaKind: Sendable { case image, video }

struct BackgroundMedia: Sendable {
    let url: URL
    let kind: MediaKind
    let duration: Double

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
    static func state(at time: Double, duration: Double, itemCount: Int, transition: BackgroundTransition, transitionDuration: Double) -> BackgroundTimelineState? {
        guard itemCount > 0 else { return nil }
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

    var id: String { rawValue }
    var title: String {
        switch self {
        case .wave: return "流光波形"
        case .spectrum: return "动态频谱"
        case .mirror: return "镜像频谱"
        case .circle: return "能量圆环"
        case .ripple: return "音频水波"
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
        case .zen: return "禅意水波 · 节拍光晕"
        case .ethereal: return "流场光带 · 空灵粒子"
        case .minimal: return "真实波形 · 克制留白"
        case .cinema: return "电影构图 · 柔光氛围"
        case .electronic: return "峰值频谱 · 强节奏响应"
        }
    }
    var defaultVisualizer: VisualizerKind {
        switch self {
        case .zen, .cinema: return .ripple
        case .ethereal: return .circle
        case .minimal: return .wave
        case .electronic: return .spectrum
        }
    }
    var accent: CGColor {
        switch self {
        case .zen: return CGColor(red: 0.67, green: 0.94, blue: 0.83, alpha: 1)
        case .ethereal: return CGColor(red: 0.66, green: 0.58, blue: 1, alpha: 1)
        case .minimal: return CGColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1)
        case .cinema: return CGColor(red: 1, green: 0.69, blue: 0.40, alpha: 1)
        case .electronic: return CGColor(red: 0.08, green: 0.91, blue: 1, alpha: 1)
        }
    }
}

enum LyricAnimation: String, CaseIterable, Identifiable, Codable, Sendable {
    case scroll = "向上滚动"
    case fade = "柔和淡入"
    case scale = "呼吸缩放"
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
    var visualizer: VisualizerKind = .circle
    var blur: Double = 18
    var darkness: Double = 0.32
    var saturation: Double = 1
    var backgroundTransition: BackgroundTransition = .crossfade
    var backgroundTransitionDuration: Double = 0.8

    var visualizerStrength: Double = 0.82
    var visualizerPositionY: Double = 0.30
    var visualizerScale: Double = 1
    var visualizerGlow: Double = 0.72
    var visualizerSmoothing: Double = 0.68
    var visualizerDensity: Double = 0.70

    var lyricSize: Double = 42
    var lyricPositionY: Double = 0.55
    var lyricWidth: Double = 0.82
    var lyricLineSpacing: Double = 1.85
    var lyricInactiveOpacity: Double = 0.30
    var lyricGlow: Double = 0.45
    var lyricAnimationDuration: Double = 0.42
    var lyricAnimation: LyricAnimation = .scroll
    var lyricAlignment: LyricAlignment = .center
    var fontPostScriptName: String = "PingFangSC-Regular"
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

    static let silent = AudioFrameFeatures(
        amplitude: 0, loudness: 0, bass: 0, mid: 0, high: 0, beat: 0,
        spectrum: Array(repeating: 0, count: 96),
        waveform: Array(repeating: 0, count: 128)
    )
}

struct AudioAnalysis: Codable, Sendable {
    static let cacheVersion = 2

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
        waveform: [[Float]]? = nil
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
            waveform: array(waveform, index, 128)
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

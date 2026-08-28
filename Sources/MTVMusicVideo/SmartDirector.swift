import CoreGraphics
import Foundation

struct SceneColorProfile: Sendable, Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let luminance: CGFloat
    let saturation: CGFloat
    let warmth: CGFloat
    let complexity: CGFloat
}

struct SmartSongProfile: Sendable, Equatable {
    let energy: Float
    let beat: Float
    let high: Float
    let warmth: Float
    let quiet: Float
    let dynamics: Float

    static let silent = SmartSongProfile(energy: 0, beat: 0, high: 0, warmth: 0.5, quiet: 1, dynamics: 0)
}

struct SmartDirection: Sendable {
    let settings: RenderSettings
    let palette: VisualPalette
}

enum SmartDirector {
    static func analyzeSong(_ analysis: AudioAnalysis?) -> SmartSongProfile {
        guard let analysis, !analysis.amplitudes.isEmpty else { return .silent }
        let count = analysis.amplitudes.count
        let stride = max(1, count / 360)
        let indices = Swift.stride(from: 0, to: count, by: stride)

        var energies: [Float] = []
        energies.reserveCapacity(min(count, 360))
        var beat: Float = 0
        var high: Float = 0
        var warmth: Float = 0
        var quiet: Float = 0
        var samples: Float = 0
        for index in indices {
            let frame = analysis.frame(at: Double(index) / max(1, analysis.frameRate))
            energies.append(frame.energy)
            beat += frame.beat
            high += frame.high
            warmth += frame.warmth
            quiet += frame.quiet
            samples += 1
        }
        guard samples > 0 else { return .silent }
        energies.sort()
        let low = energies[Int(Float(max(0, energies.count - 1)) * 0.15)]
        let highEnergy = energies[Int(Float(max(0, energies.count - 1)) * 0.85)]
        return SmartSongProfile(
            energy: energies.reduce(0, +) / samples,
            beat: beat / samples,
            high: high / samples,
            warmth: warmth / samples,
            quiet: quiet / samples,
            dynamics: max(0, highEnergy - low)
        )
    }

    static func analyzeScene(_ image: CGImage?) -> SceneColorProfile? {
        guard let image else { return nil }
        let width = 48
        let height = 48
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var saturation: CGFloat = 0
        var complexity: CGFloat = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = CGFloat(pixels[offset]) / 255
                let g = CGFloat(pixels[offset + 1]) / 255
                let b = CGFloat(pixels[offset + 2]) / 255
                red += r
                green += g
                blue += b
                saturation += max(r, g, b) - min(r, g, b)
                if x > 0 {
                    let previous = offset - 4
                    complexity += abs(r - CGFloat(pixels[previous]) / 255)
                        + abs(g - CGFloat(pixels[previous + 1]) / 255)
                        + abs(b - CGFloat(pixels[previous + 2]) / 255)
                }
                if y > 0 {
                    let previous = offset - width * 4
                    complexity += abs(r - CGFloat(pixels[previous]) / 255)
                        + abs(g - CGFloat(pixels[previous + 1]) / 255)
                        + abs(b - CGFloat(pixels[previous + 2]) / 255)
                }
            }
        }
        let count = CGFloat(width * height)
        red /= count
        green /= count
        blue /= count
        saturation /= count
        complexity = min(1, complexity / (count * 1.8))
        return SceneColorProfile(
            red: red,
            green: green,
            blue: blue,
            luminance: red * 0.2126 + green * 0.7152 + blue * 0.0722,
            saturation: saturation,
            warmth: min(1, max(0, 0.5 + (red - blue) * 0.75)),
            complexity: complexity
        )
    }

    static func direct(
        base: RenderSettings,
        song: SmartSongProfile,
        scene: SceneColorProfile?
    ) -> SmartDirection {
        guard base.smartDirectorEnabled else {
            return SmartDirection(settings: base, palette: base.template.palette)
        }

        var result = base
        let intensity = clamp(base.smartOverallIntensity)
        let pace = clamp(base.smartMotionPace)
        let template = selectedTemplate(mood: base.smartVisualMood, song: song, scene: scene)
        result.template = template
        result.visualizer = template.defaultVisualizer

        let sceneLuminance = Double(scene?.luminance ?? 0.48)
        let sceneSaturation = Double(scene?.saturation ?? 0.28)
        let sceneComplexity = Double(scene?.complexity ?? 0.24)
        let musicalEnergy = Double(song.energy)
        let musicalBeat = Double(song.beat)

        result.blur = clamp(5 + sceneComplexity * 13 + sceneLuminance * 3, 4, 20)
        result.smartBlurEnabled = true
        result.darkness = clamp(0.10 + max(0, sceneLuminance - 0.42) * 0.34 + sceneComplexity * 0.09, 0.08, 0.34)
        result.saturation = clamp(1.03 - max(0, sceneSaturation - 0.36) * 0.28, 0.88, 1.06)
        result.backgroundMotionStyle = pace > 0.72 && song.energy > 0.60 ? .liquid : .natural
        result.backgroundLife = clamp(0.24 + pace * 0.29 + musicalEnergy * 0.12, 0.22, 0.70)
        result.backgroundCameraMotion = clamp(0.18 + pace * 0.30, 0.16, 0.58)
        result.backgroundAudioWarp = clamp(0.05 + pace * musicalEnergy * 0.20, 0.04, 0.30)
        result.backgroundParallax = clamp(0.14 + pace * 0.20, 0.12, 0.40)
        result.backgroundLightFlow = clamp(0.08 + intensity * Double(song.high) * 0.22, 0.06, 0.34)
        result.backgroundSubjectProtection = 0.88
        result.subjectEdgeLight = clamp(0.22 + intensity * 0.24, 0.20, 0.54)

        result.visualizerStrength = clamp(0.68 + intensity * 0.30 + musicalEnergy * 0.08, 0.66, 1.08)
        result.visualizerGlow = clamp(0.70 + intensity * 0.34, 0.68, 1.08)
        result.visualizerSmoothing = clamp(0.82 - pace * 0.22, 0.54, 0.82)
        result.visualizerDensity = clamp(0.70 + intensity * 0.26, 0.68, 0.98)
        result.visualizerBrilliance = clamp(0.52 + intensity * 0.34, 0.50, 0.92)
        result.visualizerIntegration = clamp(0.68 + sceneComplexity * 0.12, 0.66, 0.84)
        result.visualizerTrail = clamp(0.16 + (1 - pace) * 0.22 + Double(song.dynamics) * 0.16, 0.14, 0.46)
        result.visualizerColorRichness = clamp(0.56 + intensity * 0.30 - max(0, sceneSaturation - 0.45) * 0.25, 0.48, 0.88)
        result.visualizerDepth = clamp(0.46 + intensity * 0.25, 0.44, 0.76)
        result.visualizerBeatImpact = clamp(0.34 + pace * 0.24 + musicalBeat * 0.28, 0.32, 0.82)
        result.musicAwareness = clamp(0.90 + intensity * 0.08, 0.90, 0.98)
        result.lyricGlow = clamp(0.68 + intensity * 0.24, 0.66, 0.96)
        result.introAnimationStyle = template == .cinema ? .cinematic : .luminousRise

        let harmonyStrength = scene == nil ? 0 : CGFloat(0.38 + intensity * 0.30)
        return SmartDirection(
            settings: result,
            palette: template.palette.adapted(to: scene, strength: harmonyStrength)
        )
    }

    static func selectedTemplate(mood: SmartVisualMood, song: SmartSongProfile, scene: SceneColorProfile?) -> VisualTemplate {
        switch mood {
        case .natural: return .zen
        case .ethereal: return .ethereal
        case .cinema: return .cinema
        case .vivid: return .electronic
        case .automatic:
            if song.energy > 0.62 && song.beat > 0.54 { return .electronic }
            if song.quiet > 0.62 || song.energy < 0.28 { return .zen }
            if song.warmth > 0.60 && (song.dynamics > 0.20 || (scene?.warmth ?? 0.5) > 0.62) { return .cinema }
            if song.high > 0.48 || song.dynamics > 0.24 { return .ethereal }
            return .minimal
        }
    }

    private static func clamp(_ value: Double, _ lower: Double = 0, _ upper: Double = 1) -> Double {
        min(upper, max(lower, value))
    }
}

extension VisualPalette {
    func adapted(to scene: SceneColorProfile?, strength: CGFloat) -> VisualPalette {
        guard let scene else { return self }
        let amount = min(0.78, max(0, strength)) * min(1, 0.30 + scene.saturation * 1.7)
        let base = CGColor(red: scene.red, green: scene.green, blue: scene.blue, alpha: 1)
        let light = VisualPalette.mix(base, CGColor(gray: 1, alpha: 1), 0.52)
        let opposite = CGColor(
            red: min(1, scene.blue * 0.72 + 0.28),
            green: min(1, scene.red * 0.58 + scene.green * 0.42),
            blue: min(1, scene.green * 0.62 + 0.25),
            alpha: 1
        )
        return VisualPalette(
            accent: Self.mix(accent, light, amount),
            secondary: Self.mix(secondary, opposite, amount * 0.72),
            highlight: Self.mix(highlight, light, amount * 0.42),
            lyric: Self.mix(lyric, CGColor(gray: 1, alpha: 1), amount * 0.34),
            warm: Self.mix(warm, base, amount * 0.78),
            cool: Self.mix(cool, opposite, amount * 0.62)
        )
    }
}

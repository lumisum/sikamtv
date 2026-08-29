import AppKit
import CoreGraphics
import CoreImage
import CoreVideo
import simd
import XCTest
@testable import MTVMusicVideo

final class RenderEngineTests: XCTestCase {
    func testDefaultSceneStartsWithTheCompleteEtherealLook() {
        let settings = RenderSettings()
        XCTAssertEqual(settings.template, .ethereal)
        XCTAssertEqual(settings.visualizer, .aurora)
        XCTAssertEqual(settings.saturation, 1.0)
        XCTAssertEqual(settings.backgroundOverlayOpacity, 0)
        XCTAssertGreaterThanOrEqual(settings.visualizerGlow, 0.90)
        XCTAssertGreaterThanOrEqual(settings.visualizerDensity, 0.80)
        XCTAssertGreaterThanOrEqual(settings.visualizerBrilliance, 0.70)
        XCTAssertGreaterThanOrEqual(settings.visualizerIntegration, 0.60)
        XCTAssertGreaterThanOrEqual(settings.visualizerColorRichness, 0.70)
        XCTAssertEqual(settings.backgroundMotionStyle, .natural)
        XCTAssertLessThanOrEqual(settings.backgroundLife, 0.45)
        XCTAssertLessThanOrEqual(settings.backgroundAudioWarp, 0.15)
        XCTAssertLessThanOrEqual(settings.backgroundLightFlow, 0.15)
        XCTAssertGreaterThanOrEqual(settings.lyricGlow, 0.80)
        XCTAssertEqual(settings.lyricAnimation, .scroll)
        XCTAssertGreaterThanOrEqual(settings.backgroundTransitionDuration, 1.0)
        XCTAssertEqual(settings.introDuration, 12)
        XCTAssertEqual(settings.introTitleSize, 72)
        XCTAssertLessThanOrEqual(settings.subjectEdgeLight, 0.15)
    }

    func testTemplatesDoNotTintTheBackgroundUnlessOverlayIsEnabled() throws {
        let background = try XCTUnwrap(makeSolidBackground(gray: 0.38, width: 480, height: 270))
        let engine = RenderEngine()
        var settings = RenderSettings()
        settings.aspectRatio = .landscape
        settings.blur = 0
        settings.darkness = 0
        settings.saturation = 1
        settings.backgroundMotionStyle = .off
        settings.visualizerStrength = 0
        settings.visualizerGlow = 0
        settings.visualizerBrilliance = 0
        settings.visualizerIntegration = 0
        settings.visualizerColorRichness = 0
        settings.songTitle = ""
        settings.backgroundOverlayOpacity = 0
        let size = CGSize(width: 320, height: 180)

        settings.template = .zen
        let zen = try XCTUnwrap(engine.render(size: size, time: 1, settings: settings, background: background, backgroundDuration: 0, backgroundIdentifier: "neutral-overlay", lyrics: [], analysis: nil, fontName: "PingFangSC-Regular"))
        settings.template = .ethereal
        let ethereal = try XCTUnwrap(engine.render(size: size, time: 1, settings: settings, background: background, backgroundDuration: 0, backgroundIdentifier: "neutral-overlay", lyrics: [], analysis: nil, fontName: "PingFangSC-Regular"))
        XCTAssertLessThan(sparseAverageColorDifference(zen, ethereal), 0.001, "Changing templates must not add a hidden color cast")

        settings.backgroundOverlayRed = 0.12
        settings.backgroundOverlayGreen = 0.32
        settings.backgroundOverlayBlue = 0.88
        settings.backgroundOverlayOpacity = 0.25
        let tinted = try XCTUnwrap(engine.render(size: size, time: 1, settings: settings, background: background, backgroundDuration: 0, backgroundIdentifier: "neutral-overlay", lyrics: [], analysis: nil, fontName: "PingFangSC-Regular"))
        XCTAssertGreaterThan(sparseAverageColorDifference(ethereal, tinted), 0.025, "The manual overlay should visibly respond when enabled")
    }

    func testBrightBackgroundHighlightProtectionAvoidsClipping() throws {
        let background = try XCTUnwrap(makeSolidBackground(gray: 0.98, width: 480, height: 270))
        let engine = RenderEngine()
        var settings = RenderSettings()
        settings.aspectRatio = .landscape
        settings.blur = 0
        settings.darkness = 0
        settings.saturation = 1
        settings.backgroundMotionStyle = .off
        settings.visualizerStrength = 0
        settings.visualizerGlow = 0
        settings.visualizerBrilliance = 1
        settings.visualizerIntegration = 0
        settings.songTitle = ""
        let image = try XCTUnwrap(engine.render(size: CGSize(width: 320, height: 180), time: 1, settings: settings, background: background, backgroundDuration: 0, backgroundIdentifier: "sunlight-protection", lyrics: [], analysis: nil, fontName: "PingFangSC-Regular"))
        let center = sample(image, xRatio: 0.5, yRatio: 0.5)
        XCTAssertLessThan(max(center.red, center.green, center.blue), 0.97, "Bright highlights should retain headroom instead of clipping")
        XCTAssertGreaterThan(min(center.red, center.green, center.blue), 0.72, "Highlight protection should remain natural, not muddy")
    }

    func testStaticBackgroundKeepsMovingWithoutAudio() throws {
        let background = try XCTUnwrap(makeBandedBackground(width: 640, height: 360))
        let engine = RenderEngine()
        var settings = RenderSettings()
        settings.aspectRatio = .landscape
        settings.blur = 0
        settings.darkness = 0.24
        let first = try XCTUnwrap(engine.render(
            size: CGSize(width: 320, height: 180),
            time: 0,
            settings: settings,
            background: background,
            backgroundDuration: 0,
            backgroundIdentifier: "ambient-motion",
            lyrics: [],
            analysis: nil,
            fontName: "PingFangSC-Regular"
        ))
        let later = try XCTUnwrap(engine.render(
            size: CGSize(width: 320, height: 180),
            time: 12,
            settings: settings,
            background: background,
            backgroundDuration: 0,
            backgroundIdentifier: "ambient-motion",
            lyrics: [],
            analysis: nil,
            fontName: "PingFangSC-Regular"
        ))
        let difference = maximumColorDifference(first, later, yStartRatio: 0.02, yEndRatio: 0.98)
        XCTAssertGreaterThan(difference, 0.025, "A still photo should receive visible slow motion and breathing light")
    }

    func testStaticBackgroundLifeMakesThePhotoReactToMusic() throws {
        let background = try XCTUnwrap(makeBandedBackground(width: 640, height: 360))
        let frameCount = 90
        let analysis = AudioAnalysis(
            duration: 3,
            sampleRate: 44_100,
            amplitudes: Array(repeating: 0.7, count: frameCount),
            loudness: Array(repeating: 0.72, count: frameCount),
            bass: Array(repeating: 0.84, count: frameCount),
            mid: Array(repeating: 0.62, count: frameCount),
            high: Array(repeating: 0.48, count: frameCount),
            beats: Array(repeating: 0.9, count: frameCount),
            spectrum: Array(repeating: Array(repeating: Float(0.6), count: 96), count: frameCount),
            energy: Array(repeating: 0.9, count: frameCount),
            transients: Array(repeating: 0.95, count: frameCount),
            buildups: Array(repeating: 0.7, count: frameCount),
            climaxes: Array(repeating: 0.86, count: frameCount),
            quietness: Array(repeating: 0.02, count: frameCount),
            warmth: Array(repeating: 0.7, count: frameCount),
            sectionProgress: Array(repeating: 0.55, count: frameCount)
        )
        let engine = RenderEngine()
        var still = RenderSettings()
        still.aspectRatio = .landscape
        still.blur = 0
        still.darkness = 0
        still.saturation = 1
        still.visualizerStrength = 0
        still.visualizerGlow = 0
        still.backgroundMotionStyle = .off
        var alive = still
        alive.backgroundMotionStyle = .liquid
        alive.backgroundLife = 1
        alive.backgroundAudioWarp = 1
        alive.backgroundParallax = 1
        alive.backgroundLightFlow = 1
        alive.backgroundSubjectProtection = 0.5
        let size = CGSize(width: 320, height: 180)

        let baseline = try XCTUnwrap(engine.render(size: size, time: 1.1, settings: still, background: background, backgroundDuration: 0, backgroundIdentifier: "life-photo", lyrics: [], analysis: analysis, fontName: "PingFangSC-Regular"))
        let reactive = try XCTUnwrap(engine.render(size: size, time: 1.1, settings: alive, background: background, backgroundDuration: 0, backgroundIdentifier: "life-photo", lyrics: [], analysis: analysis, fontName: "PingFangSC-Regular"))
        XCTAssertGreaterThan(sparseAverageColorDifference(baseline, reactive), 0.006, "Music should visibly animate a static background")
    }

    func testEveryVisualizerRendersAtTheRequestedAspectRatio() {
        let analysis = AudioAnalysis(
            duration: 4,
            sampleRate: 44_100,
            amplitudes: Array(repeating: 0.35, count: 120),
            loudness: Array(repeating: 0.44, count: 120),
            bass: Array(repeating: 0.62, count: 120),
            mid: Array(repeating: 0.45, count: 120),
            high: Array(repeating: 0.32, count: 120),
            beats: Array(repeating: 0.7, count: 120),
            spectrum: Array(repeating: Array(repeating: Float(0.42), count: 96), count: 120),
            waveform: Array(repeating: (0..<128).map { sin(Float($0) * 0.2) * 0.7 }, count: 120)
        )
        let engine = RenderEngine()
        var settings = RenderSettings()
        let requestedSize = CGSize(width: 270, height: 480)

        var rendered: [(VisualizerKind, CGImage)] = []
        for visualizer in VisualizerKind.allCases {
            settings.visualizer = visualizer
            let image = engine.render(size: requestedSize, time: 1.25, settings: settings, background: nil, backgroundDuration: 0, lyrics: [], analysis: analysis, fontName: "PingFangSC-Regular")
            XCTAssertEqual(image?.width, 270, "Unexpected width for \(visualizer.rawValue)")
            XCTAssertEqual(image?.height, 480, "Unexpected height for \(visualizer.rawValue)")
            if let image { rendered.append((visualizer, image)) }
        }
        for first in 0..<rendered.count {
            for second in (first + 1)..<rendered.count {
                let difference = sparseAverageColorDifference(rendered[first].1, rendered[second].1)
                XCTAssertGreaterThan(difference, 0.002, "\(rendered[first].0.rawValue) and \(rendered[second].0.rawValue) must remain visually distinct")
            }
        }
    }

    func testBorderVisualizerBuildsALayeredEnergyFieldInsteadOfASingleStroke() {
        let features = AudioFrameFeatures(
            amplitude: 0.62,
            loudness: 0.68,
            bass: 0.78,
            mid: 0.59,
            high: 0.51,
            beat: 0.82,
            spectrum: (0..<96).map { 0.18 + sin(Float($0) * 0.19) * 0.14 + Float($0 % 11) * 0.035 },
            waveform: (0..<128).map { sin(Float($0) * 0.18) * 0.76 },
            energy: 0.72,
            transient: 0.66,
            buildup: 0.58,
            climax: 0.42,
            quiet: 0.04,
            warmth: 0.52,
            sectionProgress: 0.38
        )
        var settings = RenderSettings()
        settings.aspectRatio = .landscape
        settings.visualizer = .border
        let mesh = VisualizerEngine().mesh(
            kind: .border,
            size: CGSize(width: 960, height: 540),
            features: features,
            settings: settings,
            time: 1.4,
            palette: settings.template.palette,
            staticBackground: true
        )
        XCTAssertGreaterThan(mesh.soft.count, 2_000, "Border mode needs a translucent frequency membrane")
        XCTAssertGreaterThan(mesh.radials.count, 500, "Border mode needs moving glow clouds and light particles")
        XCTAssertGreaterThan(mesh.additive.count, 4_500, "Border mode needs filaments and independent light trails")
    }

    func testSevenColorFlowMapsDifferentScaleDegreesAcrossEveryVisualizer() {
        func features(pitchClass: Int) -> AudioFrameFeatures {
            var chroma = [Float](repeating: 0.04, count: 12)
            chroma[pitchClass] = 1
            return AudioFrameFeatures(
                amplitude: 0.62,
                loudness: 0.68,
                bass: 0.72,
                mid: 0.58,
                high: 0.46,
                beat: 0.52,
                spectrum: Array(repeating: 0.48, count: 96),
                waveform: (0..<128).map { sin(Float($0) * 0.16) * 0.58 },
                energy: 0.64,
                transient: 0.38,
                buildup: 0.42,
                climax: 0.36,
                quiet: 0.08,
                warmth: 0.56,
                sectionProgress: 0.34,
                chroma: chroma,
                tonalConfidence: 0.92,
                tonalRoot: 0,
                tonalMode: 1
            )
        }

        func averageColor(_ mesh: VisualizerMesh) -> SIMD3<Float> {
            let vertices = mesh.soft + mesh.additive + mesh.radials
            var total = SIMD3<Float>.zero
            var weight: Float = 0
            for vertex in vertices where vertex.color.w > 0.001 {
                let alpha = vertex.color.w
                total += SIMD3(vertex.color.x, vertex.color.y, vertex.color.z) / alpha * alpha
                weight += alpha
            }
            return total / max(0.001, weight)
        }

        var settings = RenderSettings()
        settings.aspectRatio = .landscape
        settings.sevenColorFlowIntensity = 1
        let engine = VisualizerEngine()
        let size = CGSize(width: 960, height: 540)
        for kind in VisualizerKind.allCases {
            settings.visualizer = kind
            settings.sevenColorFlowEnabled = true
            let doMesh = engine.mesh(kind: kind, size: size, features: features(pitchClass: 0), settings: settings, time: 1, palette: settings.template.palette, staticBackground: true)
            let laMesh = engine.mesh(kind: kind, size: size, features: features(pitchClass: 9), settings: settings, time: 1, palette: settings.template.palette, staticBackground: true)
            let enabledDifference = simd_length(averageColor(doMesh) - averageColor(laMesh))

            settings.sevenColorFlowEnabled = false
            let disabledDo = engine.mesh(kind: kind, size: size, features: features(pitchClass: 0), settings: settings, time: 1, palette: settings.template.palette, staticBackground: true)
            let disabledLa = engine.mesh(kind: kind, size: size, features: features(pitchClass: 9), settings: settings, time: 1, palette: settings.template.palette, staticBackground: true)
            let disabledDifference = simd_length(averageColor(disabledDo) - averageColor(disabledLa))

            XCTAssertGreaterThan(enabledDifference, disabledDifference + 0.06, "\(kind.title) should respond visibly to the sounding scale degree")
        }
    }

    func testUnifiedPostProcessingProducesAVisibleButStableUpgrade() throws {
        let background = try XCTUnwrap(makeBandedBackground(width: 640, height: 360))
        let analysis = AudioAnalysis(
            duration: 2,
            sampleRate: 44_100,
            amplitudes: Array(repeating: 0.58, count: 60),
            loudness: Array(repeating: 0.64, count: 60),
            bass: Array(repeating: 0.78, count: 60),
            mid: Array(repeating: 0.56, count: 60),
            high: Array(repeating: 0.48, count: 60),
            beats: Array(repeating: 0.9, count: 60),
            spectrum: Array(repeating: Array(repeating: Float(0.62), count: 96), count: 60),
            waveform: Array(repeating: (0..<128).map { sin(Float($0) * 0.18) * 0.76 }, count: 60)
        )
        let engine = RenderEngine()
        var plain = RenderSettings()
        plain.aspectRatio = .landscape
        plain.blur = 0
        plain.visualizerBrilliance = 0
        plain.visualizerIntegration = 0
        plain.visualizerTrail = 0
        plain.visualizerColorRichness = 0
        plain.visualizerDepth = 0
        plain.visualizerBeatImpact = 0

        var enhanced = plain
        enhanced.visualizerBrilliance = 1
        enhanced.visualizerIntegration = 1
        enhanced.visualizerTrail = 0.8
        enhanced.visualizerColorRichness = 1
        enhanced.visualizerDepth = 1
        enhanced.visualizerBeatImpact = 1

        let size = CGSize(width: 320, height: 180)
        let baseline = try XCTUnwrap(engine.render(size: size, time: 0.8, settings: plain, background: background, backgroundDuration: 2, lyrics: [], analysis: analysis, fontName: "PingFangSC-Regular"))
        let first = try XCTUnwrap(engine.render(size: size, time: 0.8, settings: enhanced, background: background, backgroundDuration: 2, lyrics: [], analysis: analysis, fontName: "PingFangSC-Regular"))
        let repeated = try XCTUnwrap(engine.render(size: size, time: 0.8, settings: enhanced, background: background, backgroundDuration: 2, lyrics: [], analysis: analysis, fontName: "PingFangSC-Regular"))

        XCTAssertGreaterThan(sparseAverageColorDifference(baseline, first), 0.008, "Unified post controls should visibly change the scene")
        XCTAssertLessThan(sparseAverageColorDifference(first, repeated), 0.001, "Paused or repeated frames must not accumulate trails")
    }

    func testMusicAwarenessDirectsTheWholeSceneFromSongStructure() throws {
        let background = try XCTUnwrap(makeBandedBackground(width: 640, height: 360))
        let frameCount = 90
        let analysis = AudioAnalysis(
            duration: 3,
            sampleRate: 44_100,
            amplitudes: Array(repeating: 0.38, count: frameCount),
            loudness: Array(repeating: 0.38, count: frameCount),
            bass: Array(repeating: 0.48, count: frameCount),
            mid: Array(repeating: 0.42, count: frameCount),
            high: Array(repeating: 0.36, count: frameCount),
            beats: Array(repeating: 0.2, count: frameCount),
            spectrum: Array(repeating: Array(repeating: Float(0.42), count: 96), count: frameCount),
            energy: Array(repeating: 0.92, count: frameCount),
            transients: Array(repeating: 0.86, count: frameCount),
            buildups: Array(repeating: 0.78, count: frameCount),
            climaxes: Array(repeating: 0.94, count: frameCount),
            quietness: Array(repeating: 0.02, count: frameCount),
            warmth: Array(repeating: 0.88, count: frameCount),
            sectionProgress: Array(repeating: 0.65, count: frameCount)
        )
        let engine = RenderEngine()
        var unaware = RenderSettings()
        unaware.aspectRatio = .landscape
        unaware.musicAwareness = 0
        var aware = unaware
        aware.musicAwareness = 1
        let size = CGSize(width: 320, height: 180)

        let plain = try XCTUnwrap(engine.render(size: size, time: 1, settings: unaware, background: background, backgroundDuration: 3, lyrics: [], analysis: analysis, fontName: "PingFangSC-Regular"))
        let directed = try XCTUnwrap(engine.render(size: size, time: 1, settings: aware, background: background, backgroundDuration: 3, lyrics: [], analysis: analysis, fontName: "PingFangSC-Regular"))
        XCTAssertGreaterThan(sparseAverageColorDifference(plain, directed), 0.004, "Song structure should visibly direct motion, light, and color")
    }

    func testEveryLyricAnimationRendersWithParameterizedLayout() {
        let engine = RenderEngine()
        let lyrics = [
            LRCLine(time: 0, text: "上一句歌词"),
            LRCLine(time: 1, text: "当前歌词用于测试动画和位置"),
            LRCLine(time: 3, text: "下一句歌词")
        ]
        var settings = RenderSettings()
        settings.lyricPositionY = 0.68
        settings.lyricWidth = 0.65
        settings.lyricAlignment = .leading
        for animation in LyricAnimation.allCases {
            settings.lyricAnimation = animation
            let image = engine.render(size: CGSize(width: 540, height: 960), time: 1.2, settings: settings, background: nil, backgroundDuration: 0, lyrics: lyrics, analysis: nil, fontName: "PingFangSC-Regular")
            XCTAssertEqual(image?.width, 540, "Lyric animation failed: \(animation.rawValue)")
            XCTAssertEqual(image?.height, 960)
        }
    }

    func testOpeningCreditsFadeAndUseAspectAwarePlacement() throws {
        let background = try XCTUnwrap(makeSolidBackground(gray: 0.18, width: 640, height: 640))
        let engine = RenderEngine()
        var settings = RenderSettings()
        settings.blur = 0
        settings.darkness = 0
        settings.saturation = 1
        settings.visualizerStrength = 0
        settings.visualizerGlow = 0
        settings.backgroundMotionStyle = .off
        settings.songTitle = "心无挂碍"
        settings.authorName = "鹿鸣松(Lumisum)"
        settings.introShowsDate = true
        settings.introDuration = 6
        settings.introAnimationDuration = 1

        settings.aspectRatio = .portrait
        let portraitSize = CGSize(width: 270, height: 480)
        var portraitBaselineSettings = settings
        portraitBaselineSettings.introEnabled = false
        let portraitBaseline = try XCTUnwrap(engine.render(size: portraitSize, time: 1.5, settings: portraitBaselineSettings, background: background, backgroundDuration: 0, backgroundIdentifier: "intro-portrait", lyrics: [], analysis: nil, fontName: "PingFangSC-Regular"))
        let portrait = try XCTUnwrap(engine.render(size: portraitSize, time: 1.5, settings: settings, background: background, backgroundDuration: 0, backgroundIdentifier: "intro-portrait", lyrics: [], analysis: nil, fontName: "PingFangSC-Regular"))
        let portraitTopCenter = maximumColorDifference(in: portrait, comparedWith: portraitBaseline, xStartRatio: 0.15, xEndRatio: 0.85, yStartRatio: 0.02, yEndRatio: 0.30)
        let portraitBottom = maximumColorDifference(in: portrait, comparedWith: portraitBaseline, xStartRatio: 0.05, xEndRatio: 0.95, yStartRatio: 0.55, yEndRatio: 0.95)
        XCTAssertGreaterThan(portraitTopCenter, 0.12, "Portrait credits should be centered near the top")
        XCTAssertLessThan(portraitBottom, 0.02, "Portrait credits must not spill into the lower workspace")

        settings.aspectRatio = .landscape
        let landscapeSize = CGSize(width: 480, height: 270)
        var landscapeBaselineSettings = settings
        landscapeBaselineSettings.introEnabled = false
        let landscapeBaseline = try XCTUnwrap(engine.render(size: landscapeSize, time: 1.5, settings: landscapeBaselineSettings, background: background, backgroundDuration: 0, backgroundIdentifier: "intro-landscape", lyrics: [], analysis: nil, fontName: "PingFangSC-Regular"))
        let landscape = try XCTUnwrap(engine.render(size: landscapeSize, time: 1.5, settings: settings, background: background, backgroundDuration: 0, backgroundIdentifier: "intro-landscape", lyrics: [], analysis: nil, fontName: "PingFangSC-Regular"))
        let landscapeTopLeft = maximumColorDifference(in: landscape, comparedWith: landscapeBaseline, xStartRatio: 0.02, xEndRatio: 0.62, yStartRatio: 0.02, yEndRatio: 0.34)
        let landscapeBottomRight = maximumColorDifference(in: landscape, comparedWith: landscapeBaseline, xStartRatio: 0.65, xEndRatio: 0.98, yStartRatio: 0.55, yEndRatio: 0.96)
        XCTAssertGreaterThan(landscapeTopLeft, 0.12, "Landscape credits should appear in the top-left")
        XCTAssertLessThan(landscapeBottomRight, 0.02, "Landscape credits must stay out of the lower-right image")

        let fadeStartBaseline = try XCTUnwrap(engine.render(size: landscapeSize, time: 0, settings: landscapeBaselineSettings, background: background, backgroundDuration: 0, backgroundIdentifier: "intro-fade", lyrics: [], analysis: nil, fontName: "PingFangSC-Regular"))
        let fadeStart = try XCTUnwrap(engine.render(size: landscapeSize, time: 0, settings: settings, background: background, backgroundDuration: 0, backgroundIdentifier: "intro-fade", lyrics: [], analysis: nil, fontName: "PingFangSC-Regular"))
        XCTAssertLessThan(sparseAverageColorDifference(fadeStartBaseline, fadeStart), 0.001, "Opening credits should begin fully transparent")

        let finishedBaseline = try XCTUnwrap(engine.render(size: landscapeSize, time: 6.2, settings: landscapeBaselineSettings, background: background, backgroundDuration: 0, backgroundIdentifier: "intro-finished", lyrics: [], analysis: nil, fontName: "PingFangSC-Regular"))
        let finished = try XCTUnwrap(engine.render(size: landscapeSize, time: 6.2, settings: settings, background: background, backgroundDuration: 0, backgroundIdentifier: "intro-finished", lyrics: [], analysis: nil, fontName: "PingFangSC-Regular"))
        XCTAssertLessThan(sparseAverageColorDifference(finishedBaseline, finished), 0.001, "Opening credits should be gone after their display duration")
    }

    func testBrightBackgroundAutomaticallyGetsStrongerLyricProtection() throws {
        let brightBackground = try XCTUnwrap(makeSolidBackground(gray: 0.96, width: 360, height: 640))
        let darkBackground = try XCTUnwrap(makeSolidBackground(gray: 0.04, width: 360, height: 640))
        let lyrics = [LRCLine(time: 0, text: "明亮背景也要清晰可读")]
        let engine = RenderEngine()
        var settings = RenderSettings()
        settings.aspectRatio = .portrait
        settings.template = .minimal
        settings.blur = 0
        settings.darkness = 0
        settings.saturation = 1
        settings.visualizerStrength = 0
        settings.visualizerGlow = 0
        settings.lyricGlow = 0
        settings.lyricAnimation = .none
        settings.lyricSize = 52

        let brightBaseline = try XCTUnwrap(engine.render(size: CGSize(width: 360, height: 640), time: 0.2, settings: settings, background: brightBackground, backgroundDuration: 0, backgroundIdentifier: "contrast-bright", lyrics: [], analysis: nil, fontName: "PingFangSC-Regular"))
        let brightLyrics = try XCTUnwrap(engine.render(size: CGSize(width: 360, height: 640), time: 0.2, settings: settings, background: brightBackground, backgroundDuration: 0, backgroundIdentifier: "contrast-bright", lyrics: lyrics, analysis: nil, fontName: "PingFangSC-Regular"))
        let darkBaseline = try XCTUnwrap(engine.render(size: CGSize(width: 360, height: 640), time: 0.2, settings: settings, background: darkBackground, backgroundDuration: 0, backgroundIdentifier: "contrast-dark", lyrics: [], analysis: nil, fontName: "PingFangSC-Regular"))
        let darkLyrics = try XCTUnwrap(engine.render(size: CGSize(width: 360, height: 640), time: 0.2, settings: settings, background: darkBackground, backgroundDuration: 0, backgroundIdentifier: "contrast-dark", lyrics: lyrics, analysis: nil, fontName: "PingFangSC-Regular"))

        let brightProtection = averageDarkening(brightLyrics, comparedWith: brightBaseline)
        let darkProtection = averageDarkening(darkLyrics, comparedWith: darkBaseline)
        XCTAssertGreaterThan(brightProtection, 0.012, "Bright backgrounds need a visible adaptive contour and feathered scrim")
        XCTAssertGreaterThan(brightProtection, darkProtection * 2.5, "Protection should become stronger only when the background needs it")
    }

    func testTemplatePalettesKeepDistinctAccentAndSecondaryColors() {
        let accents = Set(VisualTemplate.allCases.map { VisualPalette.rgba($0.palette.accent) }.map { "\($0.0)-\($0.1)-\($0.2)" })
        XCTAssertEqual(accents.count, VisualTemplate.allCases.count)
        for template in VisualTemplate.allCases {
            let accent = VisualPalette.rgba(template.palette.accent)
            let secondary = VisualPalette.rgba(template.palette.secondary)
            let distance = abs(accent.0 - secondary.0) + abs(accent.1 - secondary.1) + abs(accent.2 - secondary.2)
            XCTAssertGreaterThan(distance, 0.18, "\(template.rawValue) accent and secondary are too similar")
        }
    }

    func testRealtimePreviewStaysWithinThirtyFPSFrameBudgetWith4KBackgroundAndAtmosphere() throws {
        let backgroundContext = CGContext(data: nil, width: 3840, height: 2160, bitsPerComponent: 8, bytesPerRow: 3840 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        backgroundContext.setFillColor(CGColor(red: 0.14, green: 0.32, blue: 0.62, alpha: 1))
        backgroundContext.fill(CGRect(x: 0, y: 0, width: 3840, height: 2160))
        let background = try XCTUnwrap(backgroundContext.makeImage())
        let engine = RenderEngine()
        var settings = RenderSettings()
        settings.blur = 22
        settings.atmospherePreset = .rainyNight
        settings.atmosphereIntensity = 0.78
        settings.atmosphereForegroundDensity = 0.72
        let size = AspectRatio.portrait.realtimePreviewSize
        let lyrics = [LRCLine(time: 0, text: "性能优先，实时清晰")]

        _ = engine.render(size: size, time: 0, settings: settings, background: background, backgroundDuration: 0, backgroundIdentifier: "performance-static", lyrics: lyrics, analysis: nil, fontName: "PingFangSC-Regular")
        let frameCount = 12
        let start = CFAbsoluteTimeGetCurrent()
        for frame in 0..<frameCount {
            XCTAssertNotNil(engine.render(size: size, time: Double(frame) / 30, settings: settings, background: background, backgroundDuration: 0, backgroundIdentifier: "performance-static", lyrics: lyrics, analysis: nil, fontName: "PingFangSC-Regular"))
        }
        let averageMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1_000 / Double(frameCount)
        XCTAssertLessThan(averageMilliseconds, 33.3, "Realtime preview averaged \(averageMilliseconds) ms per frame")
    }

    func testBackgroundPhotoKeepsItsColorInsteadOfWashingOut() throws {
        let background = try XCTUnwrap(makeBandedBackground(width: 640, height: 360))
        let engine = RenderEngine()
        var settings = RenderSettings()
        settings.blur = 0
        settings.darkness = 0
        settings.saturation = 1
        settings.visualizerGlow = 0
        settings.visualizerStrength = 0
        settings.smartCompositionEnabled = false
        settings.template = .minimal

        let image = try XCTUnwrap(engine.render(
            size: CGSize(width: 320, height: 180),
            time: 0,
            settings: settings,
            background: background,
            backgroundDuration: 0,
            backgroundIdentifier: "banded-color",
            lyrics: [],
            analysis: nil,
            fontName: "PingFangSC-Regular"
        ))
        let top = sample(image, xRatio: 0.5, yRatio: 0.18)
        let bottom = sample(image, xRatio: 0.5, yRatio: 0.82)

        XCTAssertGreaterThan(top.red, 0.55, "Top of the frame should stay red, got \(top)")
        XCTAssertGreaterThan(top.red - top.blue, 0.35, "Background was washed out or missing at the top: \(top)")
        XCTAssertGreaterThan(bottom.blue, 0.55, "Bottom of the frame should stay blue, got \(bottom)")
        XCTAssertGreaterThan(bottom.blue - bottom.red, 0.35, "Background was washed out or missing at the bottom: \(bottom)")
    }

    func testDarknessCreatesCornerVignetteInsteadOfDimmingTheWholeImage() throws {
        let background = try XCTUnwrap(makeSolidBackground(gray: 0.62, width: 480, height: 270))
        let engine = RenderEngine()
        var settings = RenderSettings()
        settings.aspectRatio = .landscape
        settings.blur = 0
        settings.darkness = 0
        settings.saturation = 1
        settings.backgroundMotionStyle = .off
        settings.visualizerStrength = 0
        settings.visualizerGlow = 0
        settings.visualizerBrilliance = 0
        settings.visualizerIntegration = 0
        settings.songTitle = ""
        let size = CGSize(width: 320, height: 180)
        let baseline = try XCTUnwrap(engine.render(size: size, time: 1, settings: settings, background: background, backgroundDuration: 0, backgroundIdentifier: "vignette-test", lyrics: [], analysis: nil, fontName: "PingFangSC-Regular"))
        settings.darkness = 0.70
        let vignette = try XCTUnwrap(engine.render(size: size, time: 1, settings: settings, background: background, backgroundDuration: 0, backgroundIdentifier: "vignette-test", lyrics: [], analysis: nil, fontName: "PingFangSC-Regular"))
        let baselineCenter = sample(baseline, xRatio: 0.5, yRatio: 0.5)
        let vignetteCenter = sample(vignette, xRatio: 0.5, yRatio: 0.5)
        let baselineCorner = sample(baseline, xRatio: 0.03, yRatio: 0.03)
        let vignetteCorner = sample(vignette, xRatio: 0.03, yRatio: 0.03)
        XCTAssertLessThan(abs(baselineCenter.red - vignetteCenter.red), 0.035, "The center should remain open and luminous")
        XCTAssertGreaterThan(baselineCorner.red - vignetteCorner.red, 0.22, "Darkness should concentrate at the corners")
    }

    func testVisionMaskKeepsTheSubjectSharpWhileTheEnvironmentStaysBlurred() throws {
        let source = try XCTUnwrap(makeSplitBackground(width: 256, height: 256))
        let mask = try XCTUnwrap(makeCenterProtectionMask(width: 256, height: 256))
        let sharp = CIImage(cgImage: source)
        let blurred = sharp
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 18])
            .cropped(to: sharp.extent)
        let composite = RenderEngine.smartBlurComposite(sharp: sharp, blurred: blurred, mask: mask)
        let context = CIContext(options: [.cacheIntermediates: false])
        let output = try XCTUnwrap(context.createCGImage(composite, from: sharp.extent))
        let center = sample(output, xRatio: 0.49, yRatio: 0.50)
        let environment = sample(output, xRatio: 0.49, yRatio: 0.10)
        XCTAssertLessThan(center.red, 0.12, "The protected central subject should retain its sharp edge")
        XCTAssertGreaterThan(environment.red, center.red + 0.18, "The same edge outside the subject mask should remain softly blurred")
    }

    func testLargeVisualizerCanBeIntentionallyMovedPartlyBeyondTheSafeArea() throws {
        let analysis = AudioAnalysis(
            duration: 2,
            sampleRate: 44_100,
            amplitudes: Array(repeating: 0.52, count: 60),
            bass: Array(repeating: 0.72, count: 60),
            mid: Array(repeating: 0.48, count: 60),
            high: Array(repeating: 0.36, count: 60),
            beats: Array(repeating: 0.62, count: 60),
            spectrum: Array(repeating: Array(repeating: 0.55, count: 96), count: 60)
        )
        let engine = RenderEngine()
        var lower = RenderSettings()
        lower.visualizer = .circle
        lower.visualizerPositionY = 0.13
        var upper = lower
        upper.visualizerPositionY = 0.62
        let size = CGSize(width: 320, height: 568)
        let lowImage = try XCTUnwrap(engine.render(size: size, time: 1, settings: lower, background: nil, backgroundDuration: 0, lyrics: [], analysis: analysis, fontName: "PingFangSC-Regular"))
        let highImage = try XCTUnwrap(engine.render(size: size, time: 1, settings: upper, background: nil, backgroundDuration: 0, lyrics: [], analysis: analysis, fontName: "PingFangSC-Regular"))
        XCTAssertGreaterThan(sparseAverageColorDifference(lowImage, highImage), 0.008)
    }

    func testEnergyRingPullsHighEnergyFartherTowardTheCenter() {
        func frame(spectrumValue: Float) -> AudioFrameFeatures {
            AudioFrameFeatures(
                amplitude: 0.65,
                loudness: 0.68,
                bass: 0.62,
                mid: 0.58,
                high: 0.44,
                beat: 0.52,
                spectrum: Array(repeating: spectrumValue, count: 96),
                waveform: Array(repeating: 0, count: 128),
                energy: 0.66
            )
        }

        func closestVertexRadius(_ mesh: VisualizerMesh, center: SIMD2<Float>) -> Float {
            mesh.additive.map { simd_length($0.position - center) }.min() ?? .greatestFiniteMagnitude
        }

        var settings = RenderSettings()
        settings.visualizer = .circle
        settings.visualizerIntegration = 0
        settings.visualizerScale = 1
        settings.visualizerStrength = 1
        let size = CGSize(width: 960, height: 540)
        let center = SIMD2<Float>(Float(size.width * 0.5), Float(size.height * settings.visualizerPositionY))
        let engine = VisualizerEngine()
        let quiet = engine.mesh(kind: .circle, size: size, features: frame(spectrumValue: 0.08), settings: settings, time: 1, palette: settings.template.palette, staticBackground: true)
        let energetic = engine.mesh(kind: .circle, size: size, features: frame(spectrumValue: 0.92), settings: settings, time: 1, palette: settings.template.palette, staticBackground: true)

        XCTAssertLessThan(
            closestVertexRadius(energetic, center: center),
            closestVertexRadius(quiet, center: center) - 14,
            "A strong spectrum should create a visibly deeper inward amplitude"
        )
    }

    func testWaterAtmosphereConcentratesItsRefractionBelowTheWaterline() throws {
        func regionDifference(_ first: CGImage, _ second: CGImage, yRange: Range<Int>) -> CGFloat {
            let a = NSBitmapImageRep(cgImage: first)
            let b = NSBitmapImageRep(cgImage: second)
            var total: CGFloat = 0
            var count: CGFloat = 0
            for y in stride(from: yRange.lowerBound, to: min(yRange.upperBound, a.pixelsHigh), by: 3) {
                for x in stride(from: 0, to: a.pixelsWide, by: 4) {
                    guard let left = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          let right = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    total += abs(left.redComponent - right.redComponent)
                        + abs(left.greenComponent - right.greenComponent)
                        + abs(left.blueComponent - right.blueComponent)
                    count += 1
                }
            }
            return total / max(1, count)
        }

        let background = try XCTUnwrap(makeBandedBackground(width: 640, height: 360))
        let frames = 60
        let analysis = AudioAnalysis(
            duration: 2,
            sampleRate: 44_100,
            amplitudes: Array(repeating: 0.68, count: frames),
            loudness: Array(repeating: 0.72, count: frames),
            bass: Array(repeating: 0.82, count: frames),
            mid: Array(repeating: 0.66, count: frames),
            high: Array(repeating: 0.48, count: frames),
            beats: Array(repeating: 0.72, count: frames),
            spectrum: Array(repeating: Array(repeating: 0.58, count: 96), count: frames)
        )
        var settings = RenderSettings()
        settings.aspectRatio = .landscape
        settings.visualizerStrength = 0
        settings.visualizerGlow = 0
        settings.visualizerBrilliance = 0
        settings.visualizerIntegration = 0
        settings.backgroundMotionStyle = .off
        settings.blur = 0
        settings.darkness = 0
        settings.introEnabled = false
        settings.smartCompositionEnabled = false
        settings.atmospherePreset = .off
        let size = CGSize(width: 320, height: 180)
        let baseline = try XCTUnwrap(RenderEngine().render(size: size, time: 1, settings: settings, background: background, backgroundDuration: 0, backgroundIdentifier: "water-locality", lyrics: [], analysis: analysis, fontName: "PingFangSC-Regular"))

        settings.atmospherePreset = .lakesideHealing
        settings.atmosphereIntensity = 0.82
        settings.atmosphereWaterline = 0.66
        let water = try XCTUnwrap(RenderEngine().render(size: size, time: 1, settings: settings, background: background, backgroundDuration: 0, backgroundIdentifier: "water-locality", lyrics: [], analysis: analysis, fontName: "PingFangSC-Regular"))
        let upper = regionDifference(baseline, water, yRange: 0..<55)
        let lower = regionDifference(baseline, water, yRange: 120..<180)
        XCTAssertGreaterThan(lower, upper + 0.004, "Water movement should stay concentrated below the selected waterline")
    }

    func testLyricAnimationsCrossfadeOutgoingAndIncomingLinesContinuously() {
        let inactive: CGFloat = 0.24
        for animation in LyricAnimation.allCases where animation != .none {
            let startCurrent = RenderEngine.lyricTransitionOpacity(relation: 0, progress: 0, inactive: inactive, animation: animation)
            let startPrevious = RenderEngine.lyricTransitionOpacity(relation: -1, progress: 0, inactive: inactive, animation: animation)
            let middleCurrent = RenderEngine.lyricTransitionOpacity(relation: 0, progress: 0.5, inactive: inactive, animation: animation)
            let middlePrevious = RenderEngine.lyricTransitionOpacity(relation: -1, progress: 0.5, inactive: inactive, animation: animation)
            let endCurrent = RenderEngine.lyricTransitionOpacity(relation: 0, progress: 1, inactive: inactive, animation: animation)
            let endPrevious = RenderEngine.lyricTransitionOpacity(relation: -1, progress: 1, inactive: inactive, animation: animation)
            let startCurrentEmphasis = RenderEngine.lyricTransitionEmphasis(relation: 0, progress: 0, animation: animation)
            let startPreviousEmphasis = RenderEngine.lyricTransitionEmphasis(relation: -1, progress: 0, animation: animation)
            let middleCurrentEmphasis = RenderEngine.lyricTransitionEmphasis(relation: 0, progress: 0.5, animation: animation)
            let middlePreviousEmphasis = RenderEngine.lyricTransitionEmphasis(relation: -1, progress: 0.5, animation: animation)
            XCTAssertEqual(startCurrent, inactive, accuracy: 0.001)
            XCTAssertEqual(startPrevious, 1, accuracy: 0.001)
            XCTAssertEqual(middleCurrent, middlePrevious, accuracy: 0.001)
            XCTAssertEqual(endCurrent, 1, accuracy: 0.001)
            XCTAssertEqual(endPrevious, inactive, accuracy: 0.001)
            XCTAssertEqual(startCurrentEmphasis, 0, accuracy: 0.001)
            XCTAssertEqual(startPreviousEmphasis, 1, accuracy: 0.001)
            XCTAssertEqual(middleCurrentEmphasis + middlePreviousEmphasis, 1, accuracy: 0.001)
        }
    }

    func testSubjectLayeringPlacesTheVisualizerBehindTheForeground() throws {
        let renderer = try XCTUnwrap(MetalRenderer())
        let size = CGSize(width: 120, height: 120)
        let background = try XCTUnwrap(makeSolidColorBackground(red: 0.05, green: 0.16, blue: 0.92, width: 120, height: 120))
        let mask = try XCTUnwrap(makeCenterProtectionMask(width: 120, height: 120))
        let backgroundTexture = try XCTUnwrap(renderer.makeTexture(width: 120, height: 120))
        let maskTexture = try XCTUnwrap(renderer.makeTexture(width: 120, height: 120))
        renderer.renderCIImage(CIImage(cgImage: background), to: backgroundTexture)
        renderer.renderCIImage(CIImage(cgImage: mask), to: maskTexture)
        let layer = MetalRenderer.TextureLayer(
            texture: backgroundTexture,
            rect: CGRect(origin: .zero, size: size),
            alpha: 1,
            backgroundReactivity: 0,
            subjectMask: maskTexture
        )
        let red = SIMD4<Float>(0.82, 0.02, 0.02, 0.84)
        let mesh = VisualizerMesh(soft: [
            GPUVertex(position: SIMD2(0, 0), uv: .zero, color: red),
            GPUVertex(position: SIMD2(120, 0), uv: .zero, color: red),
            GPUVertex(position: SIMD2(120, 120), uv: .zero, color: red),
            GPUVertex(position: SIMD2(0, 0), uv: .zero, color: red),
            GPUVertex(position: SIMD2(120, 120), uv: .zero, color: red),
            GPUVertex(position: SIMD2(0, 120), uv: .zero, color: red)
        ])
        let post = PostProcessSettings(
            time: 1, center: SIMD2(0.5, 0.5), bass: 0, mid: 0, high: 0, beat: 0,
            integration: 0, brilliance: 0, trail: 0, colorRichness: 1, depth: 0, beatImpact: 0,
            energy: 0, transient: 0, buildup: 0, climax: 0, quiet: 1, warmth: 0.5,
            sectionProgress: 0, musicAwareness: 0
        )
        func motion(enabled: Bool) -> BackgroundMotionSettings {
            BackgroundMotionSettings(
                time: 1, center: SIMD2(0.5, 0.5), features: .silent, style: .off,
                life: 0, camera: 0, warp: 0, parallax: 0, lightFlow: 0,
                subjectProtection: 1, awareness: 0, smartCompositionEnabled: enabled, edgeLight: 0
            )
        }
        let plainBuffer = try XCTUnwrap(makePixelBuffer(width: 120, height: 120))
        XCTAssertTrue(renderer.renderToPixelBuffer(plainBuffer, size: size, backgrounds: [layer], placeholder: [], darkness: 0, vignetteAlpha: 0, accentWash: .zero, mesh: mesh, title: nil, lyrics: nil, backgroundMotion: motion(enabled: false), postProcess: post))
        let plain = try XCTUnwrap(cgImage(from: plainBuffer))
        let layeredBuffer = try XCTUnwrap(makePixelBuffer(width: 120, height: 120))
        XCTAssertTrue(renderer.renderToPixelBuffer(layeredBuffer, size: size, backgrounds: [layer], placeholder: [], darkness: 0, vignetteAlpha: 0, accentWash: .zero, mesh: mesh, title: nil, lyrics: nil, backgroundMotion: motion(enabled: true), postProcess: post))
        let layered = try XCTUnwrap(cgImage(from: layeredBuffer))
        let plainCenter = sample(plain, xRatio: 0.5, yRatio: 0.5)
        let layeredCenter = sample(layered, xRatio: 0.5, yRatio: 0.5)
        let plainCorner = sample(plain, xRatio: 0.08, yRatio: 0.08)
        let layeredCorner = sample(layered, xRatio: 0.08, yRatio: 0.08)
        XCTAssertGreaterThan(layeredCenter.blue, plainCenter.blue + 0.22, "The subject should cover the visualizer in the protected region")
        XCTAssertLessThan(layeredCenter.red, plainCenter.red - 0.20)
        let cornerDifference = abs(plainCorner.red - layeredCorner.red) + abs(plainCorner.green - layeredCorner.green) + abs(plainCorner.blue - layeredCorner.blue)
        XCTAssertLessThan(cornerDifference, 0.04, "The depth reorder should leave the unmasked environment unchanged")
    }

    func testPreviewAndExportKeepBackgroundAndLyricsUpright() throws {
        let background = try XCTUnwrap(makeBandedBackground(width: 640, height: 360))
        let engine = RenderEngine()
        var settings = RenderSettings()
        settings.blur = 0
        settings.darkness = 0.08
        settings.saturation = 1
        settings.visualizerGlow = 0
        settings.visualizerStrength = 0
        settings.smartCompositionEnabled = false
        settings.template = .minimal
        settings.lyricPositionY = 0.82
        settings.lyricGlow = 0
        settings.lyricAnimation = .none
        settings.lyricSize = 64
        let lyrics = [LRCLine(time: 0, text: "正向歌词TEST")]

        let previewWithoutLyrics = try XCTUnwrap(engine.render(
            size: CGSize(width: 320, height: 180),
            time: 0.2,
            settings: settings,
            background: background,
            backgroundDuration: 0,
            backgroundIdentifier: "banded-upright",
            lyrics: [],
            analysis: nil,
            fontName: "PingFangSC-Regular"
        ))
        let preview = try XCTUnwrap(engine.render(
            size: CGSize(width: 320, height: 180),
            time: 0.2,
            settings: settings,
            background: background,
            backgroundDuration: 0,
            backgroundIdentifier: "banded-upright",
            lyrics: lyrics,
            analysis: nil,
            fontName: "PingFangSC-Regular"
        ))
        assertUprightBackground(preview, label: "preview")
        assertLyricsLiveInUpperHalf(preview, comparedWith: previewWithoutLyrics)

        let size = CGSize(width: 320, height: 180)
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer),
            kCVReturnSuccess
        )
        let buffer = try XCTUnwrap(pixelBuffer)
        XCTAssertTrue(engine.render(
            into: buffer,
            size: size,
            time: 0.2,
            settings: settings,
            background: background,
            backgroundDuration: 0,
            backgroundIdentifier: "banded-export",
            lyrics: [],
            analysis: nil,
            fontName: "PingFangSC-Regular"
        ))
        let exportedWithoutLyrics = try XCTUnwrap(cgImage(from: buffer))
        XCTAssertTrue(engine.render(
            into: buffer,
            size: size,
            time: 0.2,
            settings: settings,
            background: background,
            backgroundDuration: 0,
            backgroundIdentifier: "banded-export",
            lyrics: lyrics,
            analysis: nil,
            fontName: "PingFangSC-Regular"
        ))
        let exported = try XCTUnwrap(cgImage(from: buffer))
        assertUprightBackground(exported, label: "export")
        assertLyricsLiveInUpperHalf(exported, comparedWith: exportedWithoutLyrics)
    }

    private func makeBandedBackground(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.05, green: 0.12, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(CGColor(red: 0.95, green: 0.08, blue: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        return context.makeImage()
    }

    private func makeSolidBackground(gray: CGFloat, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func makeSplitBackground(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return context.makeImage()
    }

    private func makeSolidColorBackground(red: CGFloat, green: CGFloat, blue: CGFloat, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess else { return nil }
        return buffer
    }

    private func makeCenterProtectionMask(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return context.makeImage()
    }

    private func assertUprightBackground(_ image: CGImage, label: String) {
        let top = sample(image, xRatio: 0.5, yRatio: 0.16)
        let bottom = sample(image, xRatio: 0.5, yRatio: 0.84)
        XCTAssertGreaterThan(top.red, top.blue + 0.20, "\(label) top should be red, got \(top)")
        XCTAssertGreaterThan(bottom.blue, bottom.red + 0.20, "\(label) bottom should be blue, got \(bottom)")
    }

    private func assertLyricsLiveInUpperHalf(_ image: CGImage, comparedWith baseline: CGImage) {
        let upper = maximumColorDifference(image, baseline, yStartRatio: 0.04, yEndRatio: 0.46)
        let lower = maximumColorDifference(image, baseline, yStartRatio: 0.54, yEndRatio: 0.96)
        XCTAssertGreaterThan(upper, 0.12, "Lyrics should visibly alter the upper half, difference was \(upper)")
        XCTAssertGreaterThan(upper, lower + 0.08, "Lyrics should sit in the upper half, upper difference \(upper) vs lower \(lower)")
    }

    private func sample(_ image: CGImage, xRatio: CGFloat, yRatio: CGFloat) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let x = min(bitmap.pixelsWide - 1, max(0, Int((CGFloat(bitmap.pixelsWide) * xRatio).rounded())))
        let y = min(bitmap.pixelsHigh - 1, max(0, Int((CGFloat(bitmap.pixelsHigh) * yRatio).rounded())))
        let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
        return (color?.redComponent ?? 0, color?.greenComponent ?? 0, color?.blueComponent ?? 0)
    }

    private func maximumColorDifference(_ image: CGImage, _ baseline: CGImage, yStartRatio: CGFloat, yEndRatio: CGFloat) -> CGFloat {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let baselineBitmap = NSBitmapImageRep(cgImage: baseline)
        let y0 = min(bitmap.pixelsHigh - 1, max(0, Int((CGFloat(bitmap.pixelsHigh) * yStartRatio).rounded())))
        let y1 = min(bitmap.pixelsHigh - 1, max(0, Int((CGFloat(bitmap.pixelsHigh) * yEndRatio).rounded())))
        var maximum: CGFloat = 0
        for y in y0...y1 {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let reference = baselineBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                maximum = max(
                    maximum,
                    abs(color.redComponent - reference.redComponent)
                        + abs(color.greenComponent - reference.greenComponent)
                        + abs(color.blueComponent - reference.blueComponent)
                )
            }
        }
        return maximum
    }

    private func maximumColorDifference(
        in image: CGImage,
        comparedWith baseline: CGImage,
        xStartRatio: CGFloat,
        xEndRatio: CGFloat,
        yStartRatio: CGFloat,
        yEndRatio: CGFloat
    ) -> CGFloat {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let baselineBitmap = NSBitmapImageRep(cgImage: baseline)
        let x0 = min(bitmap.pixelsWide - 1, max(0, Int((CGFloat(bitmap.pixelsWide) * xStartRatio).rounded())))
        let x1 = min(bitmap.pixelsWide - 1, max(0, Int((CGFloat(bitmap.pixelsWide) * xEndRatio).rounded())))
        let y0 = min(bitmap.pixelsHigh - 1, max(0, Int((CGFloat(bitmap.pixelsHigh) * yStartRatio).rounded())))
        let y1 = min(bitmap.pixelsHigh - 1, max(0, Int((CGFloat(bitmap.pixelsHigh) * yEndRatio).rounded())))
        var maximum: CGFloat = 0
        for y in y0...y1 {
            for x in x0...x1 {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let reference = baselineBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                maximum = max(
                    maximum,
                    abs(color.redComponent - reference.redComponent)
                        + abs(color.greenComponent - reference.greenComponent)
                        + abs(color.blueComponent - reference.blueComponent)
                )
            }
        }
        return maximum
    }

    private func averageDarkening(_ image: CGImage, comparedWith baseline: CGImage) -> CGFloat {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let baselineBitmap = NSBitmapImageRep(cgImage: baseline)
        var total: CGFloat = 0
        var count: CGFloat = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let reference = baselineBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let luminance = color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722
                let referenceLuminance = reference.redComponent * 0.2126 + reference.greenComponent * 0.7152 + reference.blueComponent * 0.0722
                total += max(0, referenceLuminance - luminance)
                count += 1
            }
        }
        return total / max(1, count)
    }

    private func sparseAverageColorDifference(_ first: CGImage, _ second: CGImage) -> CGFloat {
        let firstBitmap = NSBitmapImageRep(cgImage: first)
        let secondBitmap = NSBitmapImageRep(cgImage: second)
        var total: CGFloat = 0
        var count: CGFloat = 0
        for y in stride(from: 0, to: firstBitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: firstBitmap.pixelsWide, by: 8) {
                guard let a = firstBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = secondBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                total += abs(a.redComponent - b.redComponent)
                    + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent)
                count += 1
            }
        }
        return total / max(1, count)
    }

    private func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let data = Data(bytes: base, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

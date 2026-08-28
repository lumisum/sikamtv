import AppKit
import CoreGraphics
import CoreVideo
import XCTest
@testable import MTVMusicVideo

final class RenderEngineTests: XCTestCase {
    func testDefaultSceneStartsWithTheCompleteEtherealLook() {
        let settings = RenderSettings()
        XCTAssertEqual(settings.template, .ethereal)
        XCTAssertEqual(settings.visualizer, .aurora)
        XCTAssertGreaterThanOrEqual(settings.saturation, 1.10)
        XCTAssertGreaterThanOrEqual(settings.visualizerGlow, 0.90)
        XCTAssertGreaterThanOrEqual(settings.visualizerDensity, 0.80)
        XCTAssertGreaterThanOrEqual(settings.visualizerBrilliance, 0.80)
        XCTAssertGreaterThanOrEqual(settings.visualizerIntegration, 0.70)
        XCTAssertGreaterThanOrEqual(settings.visualizerColorRichness, 0.80)
        XCTAssertEqual(settings.backgroundMotionStyle, .immersive)
        XCTAssertGreaterThanOrEqual(settings.backgroundLife, 0.80)
        XCTAssertGreaterThanOrEqual(settings.lyricGlow, 0.80)
        XCTAssertEqual(settings.lyricAnimation, .bloom)
        XCTAssertGreaterThanOrEqual(settings.backgroundTransitionDuration, 1.0)
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

    func testRealtimePreviewStaysWithinThirtyFPSFrameBudgetWith4KBackground() throws {
        let backgroundContext = CGContext(data: nil, width: 3840, height: 2160, bitsPerComponent: 8, bytesPerRow: 3840 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        backgroundContext.setFillColor(CGColor(red: 0.14, green: 0.32, blue: 0.62, alpha: 1))
        backgroundContext.fill(CGRect(x: 0, y: 0, width: 3840, height: 2160))
        let background = try XCTUnwrap(backgroundContext.makeImage())
        let engine = RenderEngine()
        var settings = RenderSettings()
        settings.blur = 22
        let size = AspectRatio.portrait.realtimePreviewSize
        let lyrics = [LRCLine(time: 0, text: "性能优先，实时清晰")]

        _ = engine.render(size: size, time: 0, settings: settings, background: background, backgroundDuration: 10, lyrics: lyrics, analysis: nil, fontName: "PingFangSC-Regular")
        let frameCount = 12
        let start = CFAbsoluteTimeGetCurrent()
        for frame in 0..<frameCount {
            XCTAssertNotNil(engine.render(size: size, time: Double(frame) / 30, settings: settings, background: background, backgroundDuration: 10, lyrics: lyrics, analysis: nil, fontName: "PingFangSC-Regular"))
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

    func testPreviewAndExportKeepBackgroundAndLyricsUpright() throws {
        let background = try XCTUnwrap(makeBandedBackground(width: 640, height: 360))
        let engine = RenderEngine()
        var settings = RenderSettings()
        settings.blur = 0
        settings.darkness = 0.08
        settings.saturation = 1
        settings.visualizerGlow = 0
        settings.visualizerStrength = 0
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

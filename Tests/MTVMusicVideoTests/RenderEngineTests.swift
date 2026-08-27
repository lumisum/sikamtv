import CoreGraphics
import XCTest
@testable import MTVMusicVideo

final class RenderEngineTests: XCTestCase {
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

        for visualizer in VisualizerKind.allCases {
            settings.visualizer = visualizer
            let image = engine.render(size: requestedSize, time: 1.25, settings: settings, background: nil, backgroundDuration: 0, lyrics: [], analysis: analysis, fontName: "PingFangSC-Regular")
            XCTAssertEqual(image?.width, 270, "Unexpected width for \(visualizer.rawValue)")
            XCTAssertEqual(image?.height, 480, "Unexpected height for \(visualizer.rawValue)")
        }
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

    func testRealtimePreviewStaysWithinThirtyFPSFrameBudgetWith4KBackground() throws {
        let backgroundContext = CGContext(data: nil, width: 3840, height: 2160, bitsPerComponent: 8, bytesPerRow: 3840 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        backgroundContext.setFillColor(CGColor(red: 0.14, green: 0.32, blue: 0.62, alpha: 1))
        backgroundContext.fill(CGRect(x: 0, y: 0, width: 3840, height: 2160))
        let background = try XCTUnwrap(backgroundContext.makeImage())
        let engine = RenderEngine()
        var settings = RenderSettings()
        settings.blur = 22
        let size = AspectRatio.portrait.realtimePreviewSize

        _ = engine.render(size: size, time: 0, settings: settings, background: background, backgroundDuration: 10, lyrics: [], analysis: nil, fontName: "PingFangSC-Regular")
        let frameCount = 12
        let start = CFAbsoluteTimeGetCurrent()
        for frame in 0..<frameCount {
            XCTAssertNotNil(engine.render(size: size, time: Double(frame) / 30, settings: settings, background: background, backgroundDuration: 10, lyrics: [], analysis: nil, fontName: "PingFangSC-Regular"))
        }
        let averageMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1_000 / Double(frameCount)
        XCTAssertLessThan(averageMilliseconds, 33.3, "Realtime preview averaged \(averageMilliseconds) ms per frame")
    }
}

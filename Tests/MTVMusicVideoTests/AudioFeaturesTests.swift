import AVFoundation
import CoreGraphics
import XCTest
@testable import MTVMusicVideo

final class AudioFeaturesTests: XCTestCase {
    func testFrameReturnsExpandedMusicalFeatures() {
        let analysis = makeAnalysis(frameCount: 90)
        let frame = analysis.frame(at: 1)
        XCTAssertEqual(frame.spectrum.count, 96)
        XCTAssertEqual(frame.waveform.count, 128)
        XCTAssertEqual(frame.bass, 0.64, accuracy: 0.001)
        XCTAssertEqual(frame.beat, 0.82, accuracy: 0.001)
    }

    func testPreviewTargetsPreserveExportAspectRatio() {
        for ratio in AspectRatio.allCases {
            let preview = ratio.previewSize.width / ratio.previewSize.height
            let export = ratio.size1080.width / ratio.size1080.height
            XCTAssertEqual(preview, export, accuracy: 0.0001, "Aspect mismatch for \(ratio.rawValue)")
        }
    }

    func testSettingsRoundTripIncludesLyricAndVisualizerControls() throws {
        var settings = RenderSettings()
        settings.lyricAnimation = .scale
        settings.lyricAlignment = .leading
        settings.lyricPositionY = 0.71
        settings.visualizerGlow = 0.91
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(RenderSettings.self, from: data), settings)
    }

    func testAnalyzerStreamsAudioAndDetectsTransientFeatures() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sikamtv-analysis-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let sampleRate = 44_100.0
        let frameCount = Int(sampleRate * 3)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = buffer.floatChannelData![0]
        for index in 0..<frameCount {
            let time = Double(index) / sampleRate
            let beatPosition = time.truncatingRemainder(dividingBy: 0.5)
            let transient = beatPosition < 0.025 ? Float(exp(-beatPosition * 120)) * 0.8 : 0
            samples[index] = sin(Float(time * 2 * .pi * 70)) * 0.18
                + sin(Float(time * 2 * .pi * 440)) * 0.08
                + transient
        }
        try file.write(from: buffer)

        let result = try AudioAnalyzer().analyze(url: url)
        XCTAssertGreaterThan(result.amplitudes.count, 80)
        XCTAssertEqual(result.spectrum.first?.count, 96)
        XCTAssertEqual(result.waveform.first?.count, 128)
        XCTAssertGreaterThan(result.beats.max() ?? 0, 0.5)
        XCTAssertGreaterThan(result.bass.max() ?? 0, 0.1)
    }

    func testBackgroundAudioLoopUsesTheSameCrossfadeCadenceAsVideo() {
        let clips = BackgroundAudioMixer.singleVideoLoopClips(videoDuration: 12, projectDuration: 30, transitionDuration: 1)

        XCTAssertEqual(clips.map(\.destinationStart), [0, 11, 22])
        XCTAssertEqual(clips[0].fadeIn, 0)
        XCTAssertEqual(clips[0].fadeOut, 1)
        XCTAssertEqual(clips[1].fadeIn, 1)
        XCTAssertEqual(clips[1].fadeOut, 1)
    }

    func testBackgroundAudioMixerAddsVideoAudioOnlyWhenEnabled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sikamtv-mix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mainURL = root.appendingPathComponent("main.caf")
        let backgroundURL = root.appendingPathComponent("background.caf")
        try makeAudio(at: mainURL, duration: 1, frequency: 220)
        try makeAudio(at: backgroundURL, duration: 0.4, frequency: 440)
        let background = BackgroundMedia(url: backgroundURL, kind: .video, duration: 0.4, hasAudio: true)

        let disabled = try BackgroundAudioMixer.make(mainAudioURL: mainURL, backgrounds: [background], projectDuration: 1, backgroundAudioEnabled: false, backgroundVolume: 0.25, transitionDuration: 0.1)
        let enabled = try BackgroundAudioMixer.make(mainAudioURL: mainURL, backgrounds: [background], projectDuration: 1, backgroundAudioEnabled: true, backgroundVolume: 0.25, transitionDuration: 0.1)

        XCTAssertEqual(disabled.composition.tracks(withMediaType: .audio).count, 1)
        XCTAssertEqual(enabled.composition.tracks(withMediaType: .audio).count, 3)
        XCTAssertEqual(enabled.audioMix.inputParameters.count, 3)
    }

    private func makeAnalysis(frameCount: Int) -> AudioAnalysis {
        AudioAnalysis(
            duration: Double(frameCount) / 30,
            sampleRate: 44_100,
            amplitudes: Array(repeating: 0.5, count: frameCount),
            loudness: Array(repeating: 0.56, count: frameCount),
            bass: Array(repeating: 0.64, count: frameCount),
            mid: Array(repeating: 0.42, count: frameCount),
            high: Array(repeating: 0.31, count: frameCount),
            beats: Array(repeating: 0.82, count: frameCount),
            spectrum: Array(repeating: Array(repeating: 0.45, count: 96), count: frameCount),
            waveform: Array(repeating: (0..<128).map { sin(Float($0) * 0.18) * 0.7 }, count: frameCount)
        )
    }

    private func makeAudio(at url: URL, duration: Double, frequency: Double) throws {
        let sampleRate = 44_100.0
        let count = Int(sampleRate * duration)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for index in 0..<count {
                samples[index] = sin(Float(Double(index) / sampleRate * 2 * .pi * frequency)) * 0.2
            }
        }
        try file.write(from: buffer)
    }
}

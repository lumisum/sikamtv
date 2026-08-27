import AVFoundation
import AppKit
import CoreGraphics
import XCTest
@testable import MTVMusicVideo

final class VideoExporterTests: XCTestCase {
    func testExportsShortH264AACMovieWithSharedRenderer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sikamtv-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audioURL = root.appendingPathComponent("test.caf")
        let outputURL = root.appendingPathComponent("test.mp4")
        let backgroundURL = root.appendingPathComponent("background.png")
        let secondBackgroundURL = root.appendingPathComponent("background-2.png")
        try makeAudio(at: audioURL, duration: 0.5)
        let backgroundData = NSBitmapImageRep(cgImage: makeBackground()).representation(using: .png, properties: [:])!
        try backgroundData.write(to: backgroundURL)
        try backgroundData.write(to: secondBackgroundURL)

        let frameCount = 15
        let spectrumFrame = (0..<96).map { Float($0) / 120 }
        let waveformFrame = (0..<128).map { sin(Float($0) * 0.22) * 0.65 }
        let analysis = AudioAnalysis(
            duration: 0.5,
            sampleRate: 44_100,
            amplitudes: Array(repeating: 0.55, count: frameCount),
            loudness: Array(repeating: 0.62, count: frameCount),
            bass: Array(repeating: 0.72, count: frameCount),
            mid: Array(repeating: 0.48, count: frameCount),
            high: Array(repeating: 0.36, count: frameCount),
            beats: Array(repeating: 0.7, count: frameCount),
            spectrum: Array(repeating: spectrumFrame, count: frameCount),
            waveform: Array(repeating: waveformFrame, count: frameCount)
        )
        var settings = RenderSettings()
        settings.aspectRatio = .square
        settings.template = .electronic
        settings.visualizer = .spectrum
        settings.backgroundTransition = .crossfade
        settings.backgroundTransitionDuration = 0.1
        let lyrics = [LRCLine(time: 0, text: "SikaMTV 导出测试")]
        try VideoExporter().export(
            to: outputURL,
            backgrounds: [
                BackgroundMedia(url: backgroundURL, kind: .image, duration: 0),
                BackgroundMedia(url: secondBackgroundURL, kind: .image, duration: 0)
            ],
            audioURL: audioURL,
            lyrics: lyrics,
            analysis: analysis,
            settings: settings,
            fontName: "PingFangSC-Regular",
            progress: { _ in }
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.intValue ?? 0, 10_000)
        let asset = AVAsset(url: outputURL)
        XCTAssertFalse(asset.tracks(withMediaType: .video).isEmpty)
        XCTAssertFalse(asset.tracks(withMediaType: .audio).isEmpty)
    }

    private func makeAudio(at url: URL, duration: Double) throws {
        let sampleRate = 44_100.0
        let count = Int(sampleRate * duration)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for index in 0..<count {
                samples[index] = sin(Float(Double(index) / sampleRate * 2 * .pi * 220)) * 0.24
            }
        }
        try file.write(from: buffer)
    }

    private func makeBackground() -> CGImage {
        let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 512 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(red: 0.08, green: 0.12, blue: 0.30, alpha: 1), CGColor(red: 0.55, green: 0.10, blue: 0.42, alpha: 1)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 512, y: 512), options: [])
        return context.makeImage()!
    }
}

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
        let progressValues = LockedProgress()
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
            progress: { progressValues.append($0.fraction) }
        )
        XCTAssertGreaterThan(progressValues.first ?? 0, 0)
        XCTAssertEqual(progressValues.last ?? 0, 1, accuracy: 0.0001)
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.intValue ?? 0, 10_000)
        let asset = AVAsset(url: outputURL)
        XCTAssertFalse(asset.tracks(withMediaType: .video).isEmpty)
        XCTAssertFalse(asset.tracks(withMediaType: .audio).isEmpty)
    }

    func testEncodedMovieKeepsMetalBackgroundUpright() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sikamtv-orientation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audioURL = root.appendingPathComponent("test.caf")
        let backgroundURL = root.appendingPathComponent("banded.png")
        let outputURL = root.appendingPathComponent("upright.mp4")
        try makeAudio(at: audioURL, duration: 0.2)
        let backgroundData = try XCTUnwrap(NSBitmapImageRep(cgImage: makeBandedBackground()).representation(using: .png, properties: [:]))
        try backgroundData.write(to: backgroundURL)
        let frameCount = 6
        let analysis = AudioAnalysis(
            duration: 0.2,
            sampleRate: 44_100,
            amplitudes: Array(repeating: 0, count: frameCount),
            loudness: Array(repeating: 0, count: frameCount),
            bass: Array(repeating: 0, count: frameCount),
            mid: Array(repeating: 0, count: frameCount),
            high: Array(repeating: 0, count: frameCount),
            beats: Array(repeating: 0, count: frameCount),
            spectrum: Array(repeating: Array(repeating: 0, count: 96), count: frameCount),
            waveform: Array(repeating: Array(repeating: 0, count: 128), count: frameCount)
        )
        var settings = RenderSettings()
        settings.aspectRatio = .landscape
        settings.template = .minimal
        settings.blur = 0
        settings.darkness = 0
        settings.saturation = 1
        settings.visualizerStrength = 0
        settings.visualizerGlow = 0

        try VideoExporter().export(
            to: outputURL,
            backgrounds: [BackgroundMedia(url: backgroundURL, kind: .image, duration: 0)],
            audioURL: audioURL,
            lyrics: [],
            analysis: analysis,
            settings: settings,
            fontName: "PingFangSC-Regular",
            progress: { _ in }
        )

        let generator = AVAssetImageGenerator(asset: AVAsset(url: outputURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try generator.copyCGImage(at: CMTime(value: 1, timescale: 30), actualTime: nil)
        let bitmap = NSBitmapImageRep(cgImage: frame)
        let top = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 6)?.usingColorSpace(.deviceRGB))
        let bottom = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh * 5 / 6)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(top.redComponent, top.blueComponent + 0.20)
        XCTAssertGreaterThan(bottom.blueComponent, bottom.redComponent + 0.20)
    }

    func testExportCanBeCancelledBeforeTheFirstFrame() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sikamtv-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audioURL = root.appendingPathComponent("test.caf")
        let backgroundURL = root.appendingPathComponent("background.png")
        let outputURL = root.appendingPathComponent("cancelled.mp4")
        try makeAudio(at: audioURL, duration: 0.2)
        let backgroundData = NSBitmapImageRep(cgImage: makeBackground()).representation(using: .png, properties: [:])!
        try backgroundData.write(to: backgroundURL)
        let analysis = AudioAnalysis(duration: 0.2, sampleRate: 44_100, amplitudes: [0], loudness: [0], bass: [0], mid: [0], high: [0], beats: [0], spectrum: [Array(repeating: 0, count: 96)], waveform: [Array(repeating: 0, count: 128)])
        let token = ExportCancellationToken()
        token.cancel()

        XCTAssertThrowsError(try VideoExporter().export(
            to: outputURL,
            backgrounds: [BackgroundMedia(url: backgroundURL, kind: .image, duration: 0)],
            audioURL: audioURL,
            lyrics: [LRCLine(time: 0, text: "取消测试")],
            analysis: analysis,
            settings: RenderSettings(),
            fontName: "PingFangSC-Regular",
            cancellationToken: token,
            progress: { _ in }
        )) { error in
            guard case VideoExporter.ExportError.cancelled = error else {
                return XCTFail("Expected cancellation, got \(error)")
            }
        }
    }

    func testSequentialVideoDecoderSupportsPlaybackAndSeeking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sikamtv-decoder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let videoURL = root.appendingPathComponent("background.mp4")
        try makeVideo(at: videoURL, duration: 0.5)
        let pool = VideoFrameDecoderPool()

        XCTAssertNotNil(pool.image(for: videoURL, at: 0, role: 0))
        XCTAssertNotNil(pool.image(for: videoURL, at: 0.1, role: 0))
        XCTAssertNotNil(pool.image(for: videoURL, at: 0.2, role: 0))
        XCTAssertNotNil(pool.image(for: videoURL, at: 0.05, role: 0))
    }

    func testExportProgressContinuesBeyondTheWriterInterleaveWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sikamtv-interleave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let duration = 3.0
        let audioURL = root.appendingPathComponent("music.caf")
        let backgroundURL = root.appendingPathComponent("background.png")
        let outputURL = root.appendingPathComponent("long-export.mp4")
        try makeAudio(at: audioURL, duration: duration)
        let backgroundData = NSBitmapImageRep(cgImage: makeBackground()).representation(using: .png, properties: [:])!
        try backgroundData.write(to: backgroundURL)
        let frameCount = Int(duration * 30)
        let analysis = AudioAnalysis(
            duration: duration,
            sampleRate: 44_100,
            amplitudes: Array(repeating: 0.3, count: frameCount),
            loudness: Array(repeating: 0.35, count: frameCount),
            bass: Array(repeating: 0.4, count: frameCount),
            mid: Array(repeating: 0.3, count: frameCount),
            high: Array(repeating: 0.2, count: frameCount),
            beats: Array(repeating: 0.25, count: frameCount),
            spectrum: Array(repeating: Array(repeating: 0.2, count: 96), count: frameCount),
            waveform: Array(repeating: Array(repeating: 0.1, count: 128), count: frameCount)
        )
        var settings = RenderSettings()
        settings.aspectRatio = .landscape
        settings.blur = 0
        settings.visualizer = .wave
        let progressValues = LockedProgress()

        try VideoExporter().export(
            to: outputURL,
            backgrounds: [BackgroundMedia(url: backgroundURL, kind: .image, duration: 0)],
            audioURL: audioURL,
            lyrics: [LRCLine(time: 0, text: "持续导出测试")],
            analysis: analysis,
            settings: settings,
            fontName: "PingFangSC-Regular",
            progress: { progressValues.append($0.fraction) }
        )

        let midProgressCount = progressValues.snapshot.filter { $0 > 0.05 && $0 < 0.95 }.count
        XCTAssertGreaterThan(midProgressCount, 5, "Dual-queue export must keep publishing progress past the writer interleave window")
        XCTAssertTrue(progressValues.snapshot.contains(where: { $0 > 0.5 && $0 < 0.95 }))
        XCTAssertEqual(progressValues.last ?? 0, 1, accuracy: 0.0001)
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0, 10_000)
    }

    func testExportCanBeCancelledWhileDualQueuesAreRunning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sikamtv-cancel-running-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let duration = 2.0
        let audioURL = root.appendingPathComponent("music.caf")
        let backgroundURL = root.appendingPathComponent("background.png")
        let outputURL = root.appendingPathComponent("cancelled-running.mp4")
        try makeAudio(at: audioURL, duration: duration)
        let backgroundData = NSBitmapImageRep(cgImage: makeBackground()).representation(using: .png, properties: [:])!
        try backgroundData.write(to: backgroundURL)
        let frameCount = Int(duration * 30)
        let analysis = AudioAnalysis(
            duration: duration,
            sampleRate: 44_100,
            amplitudes: Array(repeating: 0.3, count: frameCount),
            loudness: Array(repeating: 0.35, count: frameCount),
            bass: Array(repeating: 0.4, count: frameCount),
            mid: Array(repeating: 0.3, count: frameCount),
            high: Array(repeating: 0.2, count: frameCount),
            beats: Array(repeating: 0.25, count: frameCount),
            spectrum: Array(repeating: Array(repeating: 0.2, count: 96), count: frameCount),
            waveform: Array(repeating: Array(repeating: 0.1, count: 128), count: frameCount)
        )
        var settings = RenderSettings()
        settings.aspectRatio = .landscape
        settings.blur = 0
        let token = ExportCancellationToken()
        let cancelledDuringEncoding = LockedFlag()

        XCTAssertThrowsError(try VideoExporter().export(
            to: outputURL,
            backgrounds: [BackgroundMedia(url: backgroundURL, kind: .image, duration: 0)],
            audioURL: audioURL,
            lyrics: [LRCLine(time: 0, text: "运行中取消")],
            analysis: analysis,
            settings: settings,
            fontName: "PingFangSC-Regular",
            cancellationToken: token,
            progress: { progress in
                if progress.fraction > 0.04 && progress.fraction < 0.95 {
                    cancelledDuringEncoding.value = true
                    token.cancel()
                }
            }
        )) { error in
            guard case VideoExporter.ExportError.cancelled = error else {
                return XCTFail("Expected cancellation, got \(error)")
            }
        }
        XCTAssertTrue(cancelledDuringEncoding.value)
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false

        var value: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                stored = newValue
                lock.unlock()
            }
        }
    }

    private final class LockedProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []

        var snapshot: [Double] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }

        var first: Double? { snapshot.first }
        var last: Double? { snapshot.last }

        func append(_ value: Double) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }
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

    private func makeBandedBackground() -> CGImage {
        let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.05, green: 0.12, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 180))
        context.setFillColor(CGColor(red: 0.95, green: 0.08, blue: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 180, width: 640, height: 180))
        return context.makeImage()!
    }

    private func makeVideo(at url: URL, duration: Double) throws {
        let size = CGSize(width: 320, height: 180)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frameCount = Int(duration * 30)
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool!, &buffer), kCVReturnSuccess)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer), let context = CGContext(data: base, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                context.setFillColor(CGColor(red: CGFloat(frame) / CGFloat(max(1, frameCount)), green: 0.3, blue: 0.7, alpha: 1))
                context.fill(CGRect(origin: .zero, size: size))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        XCTAssertEqual(writer.status, .completed)
    }
}

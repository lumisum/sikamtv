import AVFoundation
import AppKit
import CoreVideo
import Foundation

final class VideoExporter: @unchecked Sendable {
    struct ExportProgress {
        let fraction: Double
        let current: Double
        let duration: Double
    }

    enum ExportError: LocalizedError {
        case cannotCreateWriter
        case cannotCreatePixelBuffer
        case cannotReadAudio
        case failedToWrite

        var errorDescription: String? {
            switch self {
            case .cannotCreateWriter: return "无法创建 MP4 编码器"
            case .cannotCreatePixelBuffer: return "无法创建视频帧"
            case .cannotReadAudio: return "无法读取音频"
            case .failedToWrite: return "视频写入失败"
            }
        }
    }

    func export(to url: URL, backgrounds: [BackgroundMedia], audioURL: URL, lyrics: [LRCLine], analysis: AudioAnalysis, settings: RenderSettings, fontName: String, progress: @escaping (ExportProgress) -> Void) throws {
        let duration = analysis.duration
        let size = settings.aspectRatio.size1080
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { throw ExportError.cannotCreateWriter }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height), AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000, AVVideoExpectedSourceFrameRateKey: 30]])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        writer.add(videoInput)

        let asset = AVAsset(url: audioURL)
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else { throw ExportError.cannotReadAudio }
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 44_100, AVEncoderBitRateKey: 192_000])
        writer.add(audioInput)
        let reader = try AVAssetReader(asset: asset)
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: false, AVLinearPCMBitDepthKey: 16])
        audioOutput.alwaysCopiesSampleData = false
        reader.add(audioOutput)
        guard writer.startWriting() else { throw writer.error ?? ExportError.failedToWrite }
        writer.startSession(atSourceTime: .zero)

        let render = RenderEngine()
        var staticImages: [URL: CGImage] = [:]
        var videoGenerators: [URL: AVAssetImageGenerator] = [:]
        func image(for media: BackgroundMedia?, at localTime: Double) -> CGImage? {
            guard let media else { return nil }
            if media.kind == .image {
                if let cached = staticImages[media.url] { return cached }
                let loaded = NSImage(contentsOf: media.url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                if let loaded { staticImages[media.url] = loaded }
                return loaded
            }
            let generator: AVAssetImageGenerator
            if let cached = videoGenerators[media.url] { generator = cached }
            else {
                generator = AVAssetImageGenerator(asset: AVAsset(url: media.url))
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
                generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
                videoGenerators[media.url] = generator
            }
            let loopTime = media.playbackTime(for: localTime)
            return try? generator.copyCGImage(at: CMTime(seconds: loopTime, preferredTimescale: 600), actualTime: nil)
        }
        let fps = 30.0
        let frameCount = Int(ceil(duration * fps))
        for frame in 0..<frameCount {
            try autoreleasepool {
                while !videoInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
                let time = Double(frame) / fps
                let timeline = BackgroundTimeline.state(at: time, duration: duration, itemCount: backgrounds.count, transition: settings.backgroundTransition, transitionDuration: settings.backgroundTransitionDuration)
                let currentMedia = timeline.map { backgrounds[$0.currentIndex] }
                let nextMedia = timeline?.nextIndex.map { backgrounds[$0] }
                let frameImage = image(for: currentMedia, at: timeline?.currentLocalTime ?? time)
                let nextFrameImage = image(for: nextMedia, at: timeline?.nextLocalTime ?? 0)
                guard let image = render.render(
                    size: size,
                    time: time,
                    settings: settings,
                    background: frameImage,
                    backgroundDuration: currentMedia?.duration ?? 0,
                    backgroundIdentifier: currentMedia?.kind == .image ? currentMedia?.url.path : nil,
                    nextBackground: nextFrameImage,
                    nextBackgroundDuration: nextMedia?.duration ?? 0,
                    nextBackgroundIdentifier: nextMedia?.kind == .image ? nextMedia?.url.path : nil,
                    backgroundTimeline: timeline,
                    lyrics: lyrics,
                    analysis: analysis,
                    fontName: fontName
                ), let pixelBuffer = makePixelBuffer(image: image, size: size, pool: adaptor.pixelBufferPool) else { throw ExportError.cannotCreatePixelBuffer }
                let presentation = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
                guard adaptor.append(pixelBuffer, withPresentationTime: presentation) else { throw writer.error ?? ExportError.failedToWrite }
                if frame % 5 == 0 { progress(ExportProgress(fraction: Double(frame) / Double(max(frameCount, 1)), current: time, duration: duration)) }
            }
        }
        videoInput.markAsFinished()
        guard reader.startReading() else { throw reader.error ?? ExportError.cannotReadAudio }
        while let sample = audioOutput.copyNextSampleBuffer() {
            while !audioInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            if !audioInput.append(sample) { throw writer.error ?? ExportError.failedToWrite }
        }
        audioInput.markAsFinished()
        if reader.status == .reading { reader.cancelReading() }
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status == .completed else { throw writer.error ?? ExportError.failedToWrite }
        progress(ExportProgress(fraction: 1, current: duration, duration: duration))
    }

    private func makePixelBuffer(image: CGImage, size: CGSize, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        if let pool {
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess else { return nil }
        } else {
            let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
            guard CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attrs, &pixelBuffer) == kCVReturnSuccess else { return nil }
        }
        guard let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer), let context = CGContext(data: base, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return buffer
    }
}

import AVFoundation
import AppKit
import CoreVideo
import Foundation

final class ExportCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class VideoExporter: @unchecked Sendable {
    struct ExportProgress {
        let fraction: Double
        let current: Double
        let duration: Double
        let status: String
    }

    enum ExportError: LocalizedError {
        case cannotCreateWriter
        case cannotCreatePixelBuffer
        case cannotReadAudio
        case failedToWrite
        case cancelled

        var errorDescription: String? {
            switch self {
            case .cannotCreateWriter: return "无法创建 MP4 编码器"
            case .cannotCreatePixelBuffer: return "无法创建视频帧"
            case .cannotReadAudio: return "无法读取音频"
            case .failedToWrite: return "视频写入失败"
            case .cancelled: return "已停止生成"
            }
        }
    }

    func export(to url: URL, backgrounds: [BackgroundMedia], audioURL: URL, lyrics: [LRCLine], analysis: AudioAnalysis, settings: RenderSettings, fontName: String, backgroundAudioEnabled: Bool = false, backgroundAudioVolume: Double = 0.25, cancellationToken: ExportCancellationToken = ExportCancellationToken(), progress: @escaping (ExportProgress) -> Void) throws {
        let duration = analysis.duration
        let size = settings.aspectRatio.size1080
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { throw ExportError.cannotCreateWriter }
        var completed = false
        defer {
            if !completed {
                writer.cancelWriting()
            }
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height), AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000, AVVideoExpectedSourceFrameRateKey: 30]])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        writer.add(videoInput)

        let mixedAudio: BackgroundAudioMixResult
        do {
            mixedAudio = try BackgroundAudioMixer.make(
                mainAudioURL: audioURL,
                backgrounds: backgrounds,
                projectDuration: duration,
                backgroundAudioEnabled: backgroundAudioEnabled,
                backgroundVolume: backgroundAudioVolume,
                transitionDuration: settings.backgroundTransitionDuration
            )
        } catch {
            throw ExportError.cannotReadAudio
        }
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 44_100, AVEncoderBitRateKey: 192_000])
        writer.add(audioInput)
        let reader = try AVAssetReader(asset: mixedAudio.composition)
        let audioTracks = mixedAudio.composition.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw ExportError.cannotReadAudio }
        let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: false, AVLinearPCMBitDepthKey: 16])
        audioOutput.audioMix = mixedAudio.audioMix
        audioOutput.alwaysCopiesSampleData = false
        reader.add(audioOutput)
        guard writer.startWriting() else { throw writer.error ?? ExportError.failedToWrite }
        writer.startSession(atSourceTime: .zero)
        progress(ExportProgress(fraction: 0.005, current: 0, duration: duration, status: "正在准备编码"))

        let render = RenderEngine()
        var staticImages: [URL: CGImage] = [:]
        let videoDecoders = VideoFrameDecoderPool()
        func image(for media: BackgroundMedia?, at localTime: Double, role: Int) -> CGImage? {
            guard let media else { return nil }
            if media.kind == .image {
                if let cached = staticImages[media.url] { return cached }
                let loaded = NSImage(contentsOf: media.url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                if let loaded { staticImages[media.url] = loaded }
                return loaded
            }
            let loopTime = media.playbackTime(for: localTime)
            return videoDecoders.image(for: media.url, at: loopTime, role: role)
        }
        let fps = 30.0
        let frameCount = Int(ceil(duration * fps))
        for frame in 0..<frameCount {
            try autoreleasepool {
                try checkCancellation(cancellationToken)
                while !videoInput.isReadyForMoreMediaData {
                    try checkCancellation(cancellationToken)
                    Thread.sleep(forTimeInterval: 0.002)
                }
                let time = Double(frame) / fps
                let timeline = BackgroundTimeline.state(
                    at: time,
                    duration: duration,
                    itemCount: backgrounds.count,
                    transition: settings.backgroundTransition,
                    transitionDuration: settings.backgroundTransitionDuration,
                    singleVideoDuration: backgrounds.count == 1 && backgrounds[0].kind == .video ? backgrounds[0].duration : nil
                )
                let currentMedia = timeline.map { backgrounds[$0.currentIndex] }
                let nextMedia = timeline?.nextIndex.map { backgrounds[$0] }
                let frameImage = image(for: currentMedia, at: timeline?.currentLocalTime ?? time, role: 0)
                let nextFrameImage = image(for: nextMedia, at: timeline?.nextLocalTime ?? 0, role: 1)
                guard let pixelBuffer = makePixelBuffer(size: size, pool: adaptor.pixelBufferPool),
                      let context = bitmapContext(for: pixelBuffer, size: size) else { throw ExportError.cannotCreatePixelBuffer }
                render.render(
                    into: context,
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
                )
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                let presentation = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
                guard adaptor.append(pixelBuffer, withPresentationTime: presentation) else { throw writer.error ?? ExportError.failedToWrite }
                if frame % 3 == 0 {
                    let fraction = 0.01 + Double(frame + 1) / Double(max(frameCount, 1)) * 0.94
                    progress(ExportProgress(fraction: fraction, current: time, duration: duration, status: "正在渲染视频"))
                }
            }
        }
        videoInput.markAsFinished()
        try checkCancellation(cancellationToken)
        progress(ExportProgress(fraction: 0.955, current: duration, duration: duration, status: "正在混合音频"))
        guard reader.startReading() else { throw reader.error ?? ExportError.cannotReadAudio }
        while let sample = audioOutput.copyNextSampleBuffer() {
            try checkCancellation(cancellationToken)
            while !audioInput.isReadyForMoreMediaData {
                try checkCancellation(cancellationToken)
                Thread.sleep(forTimeInterval: 0.002)
            }
            if !audioInput.append(sample) { throw writer.error ?? ExportError.failedToWrite }
        }
        audioInput.markAsFinished()
        if reader.status == .reading { reader.cancelReading() }
        try checkCancellation(cancellationToken)
        progress(ExportProgress(fraction: 0.99, current: duration, duration: duration, status: "正在完成文件"))
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
            try checkCancellation(cancellationToken)
        }
        guard writer.status == .completed else { throw writer.error ?? ExportError.failedToWrite }
        completed = true
        progress(ExportProgress(fraction: 1, current: duration, duration: duration, status: "生成完成"))
    }

    private func checkCancellation(_ token: ExportCancellationToken) throws {
        if token.isCancelled || Task.isCancelled { throw ExportError.cancelled }
    }

    private func makePixelBuffer(size: CGSize, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        if let pool {
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess else { return nil }
        } else {
            let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
            guard CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attrs, &pixelBuffer) == kCVReturnSuccess else { return nil }
        }
        return pixelBuffer
    }

    private func bitmapContext(for buffer: CVPixelBuffer, size: CGSize) -> CGContext? {
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return nil
        }
        return context
    }
}
